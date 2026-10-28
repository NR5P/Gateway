// A client for the VARA TNC TCP interface: a command port (default 8300)
// carrying CR-terminated text lines, and a data port (command port + 1)
// carrying the ARQ payload. Works with VARA HF/FM and with xara.
//
// The command sequence follows Pat's VARA driver (github.com/n8jja/Pat-Vara, MIT).

package com.nr5p.winlink

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.ClosedReceiveChannelException
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong

enum class VARAMode(val raw: String) { HF("HF"), FM("FM") }

data class VARAConfig(
    val host: String = "127.0.0.1",
    val commandPort: Int = 8300,
    val dataPort: Int = commandPort + 1,
    val mycall: String,
    val mode: VARAMode = VARAMode.HF,
    /** "500", "2300" or "2750"; HF only. Null leaves the modem's setting alone. */
    val bandwidth: String? = "2300",
    /** How long to wait for a reply to a setup command, in seconds. */
    val commandTimeout: Double = 5.0,
    /** How long a CONNECT may take before we give up and abort, in seconds. */
    val connectTimeout: Double = 300.0,
)

sealed class VARALinkState {
    data object Closed : VARALinkState()
    data object Idle : VARALinkState()
    data class Connecting(val target: String) : VARALinkState()
    data class Connected(val caller: String, val answerer: String, val width: String) : VARALinkState()
    data object Disconnecting : VARALinkState()
}

sealed class VARAEvent {
    /** A command-port line; [outbound] is true for what we sent. */
    data class Line(val text: String, val outbound: Boolean) : VARAEvent()
    data class State(val state: VARALinkState) : VARAEvent()
    data class Ptt(val on: Boolean) : VARAEvent()
    data class Busy(val on: Boolean) : VARAEvent()
    data class Buffer(val bytes: Int) : VARAEvent()
    data class Bitrate(val text: String) : VARAEvent()
    data class Snr(val db: Double) : VARAEvent()
}

open class VARAException(message: String) : Exception(message) {
    class Rejected(cmd: String) : VARAException("modem rejected $cmd")
    class NotVARA(s: String) : VARAException("not a VARA modem (got $s)")
    class ConnectFailed(s: String) : VARAException("connect failed: $s")
    class BusyChannel : VARAException("channel busy")
    class ModemClosed : VARAException("modem connection closed")
    class NotIdle : VARAException("modem is not idle")
}

private fun secs(s: Double) = (s * 1000).toLong()

class VARAModem(val config: VARAConfig) {
    /** Called on an IO thread for every command-port line and state change. */
    @Volatile var onEvent: (VARAEvent) -> Unit = {}

    private class Waiter(val match: (String) -> Boolean, val result: CompletableDeferred<String>)

    private val lock = Any()
    private var scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    @Volatile private var cmd: TCPStream? = null
    @Volatile private var data: TCPStream? = null
    private val waiters = ConcurrentHashMap<Long, Waiter>()
    private val nextId = AtomicLong()
    private var _state: VARALinkState = VARALinkState.Closed
    @Volatile private var _buffer = 0
    @Volatile var busy = false; private set
    @Volatile var ptt = false; private set
    @Volatile var version = ""; private set
    @Volatile private var link: VARAConnection? = null
    private val commandGate = Mutex()

    val state: VARALinkState get() = synchronized(lock) { _state }
    val buffer: Int get() = _buffer

    // Lifecycle

    /** Connects both ports and sets the modem up for a Winlink session. */
    suspend fun open() {
        val c = TCPStream.connect(config.host, config.commandPort)
        val d = try {
            TCPStream.connect(config.host, config.dataPort)
        } catch (e: Exception) {
            c.close()
            throw e
        }
        cmd = c
        data = d
        scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        setState(VARALinkState.Idle)
        scope.launch { commandLoop(c) }
        scope.launch { dataLoop(d) }

        try {
            val v = command("VERSION", expect = { it.startsWith("VERSION") || it == "WRONG" })
            if (!v.startsWith("VERSION")) throw VARAException.NotVARA(v)
            version = v.removePrefix("VERSION ")
            optional("PUBLIC ON")
            if (config.mode == VARAMode.HF) optional("CWID ON")
            optional("COMPRESSION TEXT")
            required("MYCALL ${config.mycall.uppercase()}")
            optional("LISTEN OFF")
            if (config.mode == VARAMode.HF && config.bandwidth != null) required("BW${config.bandwidth}")
            if (config.mode == VARAMode.HF) optional("WINLINK SESSION")
        } catch (e: Exception) {
            withContext(NonCancellable) { close() }
            throw e
        }
    }

    /** Disconnects any link and closes both ports. */
    suspend fun close() {
        if (state is VARALinkState.Connected) disconnect()
        val c = cmd
        val d = data
        cmd = null
        data = null
        c?.close()
        d?.close()
        scope.cancel()
        modemGone()
    }

    // Commands

    /** Sends a command line and returns the first reply line matching [expect] (default OK/WRONG). */
    suspend fun command(line: String, expect: ((String) -> Boolean)? = null, timeout: Double? = null): String =
        commandGate.withLock {
            val match = expect ?: { it == "OK" || it == "WRONG" }
            waitFor(match, timeout ?: config.commandTimeout, line) { send(line) }
        }

    /** A command that must succeed. xara (like VARA) refuses MYCALL and BW while a link is still
     *  closing, for example one left by a client that went away, so retry for a while. */
    private suspend fun required(line: String, attempts: Int = 10) {
        for (i in 1..attempts) {
            if (command(line) != "WRONG") return
            if (i < attempts) {
                onEvent(VARAEvent.Line("(modem busy, retrying $line)", false))
                delay(1500)
            }
        }
        throw VARAException.Rejected(line)
    }

    /** Commands some modems do not know; a WRONG or no answer is only logged. */
    private suspend fun optional(line: String) {
        try {
            command(line)
        } catch (_: StreamException.Timeout) {
            onEvent(VARAEvent.Line("(no reply to $line)", false))
        }
    }

    private suspend fun send(line: String) {
        val c = cmd ?: throw VARAException.ModemClosed()
        onEvent(VARAEvent.Line(line, true))
        c.write("$line\r")
    }

    /** Registers a waiter, runs [then] (usually sending a command), and waits for a matching line.
     *  [ready] is checked once the waiter is in place, so a line that arrives between the caller's
     *  own check and the registration is not missed; when it holds, this returns "" at once. */
    private suspend fun waitFor(
        match: (String) -> Boolean, timeout: Double, what: String, ready: () -> Boolean = { false }, then: suspend () -> Unit,
    ): String {
        if (cmd == null) throw VARAException.ModemClosed()
        val id = nextId.incrementAndGet()
        val w = Waiter(match, CompletableDeferred())
        waiters[id] = w
        try {
            if (ready()) return ""
            val sender = scope.launch {
                try { then() } catch (e: Exception) { waiters.remove(id)?.result?.completeExceptionally(e) }
            }
            // withTimeoutOrNull, not withTimeout: a caller's own timeout must stay a cancellation.
            return withTimeoutOrNull(secs(timeout)) { w.result.await() } ?: run {
                sender.cancel()
                throw StreamException.Timeout("waiting for a reply to $what")
            }
        } finally {
            waiters.remove(id)
        }
    }

    // Linking

    /** Calls [target] and returns the ARQ link once the modem reports CONNECTED. */
    suspend fun connect(target: String, via: List<String> = emptyList()): VARAConnection {
        if (state != VARALinkState.Idle) throw VARAException.NotIdle()
        val t = target.uppercase()
        // Attach the link before calling: the gateway's first bytes can beat CONNECTED to us.
        val conn = VARAConnection(this, t)
        _buffer = 0
        link = conn
        setState(VARALinkState.Connecting(t))
        val mycall = config.mycall.uppercase()
        val line = if (via.isEmpty()) "CONNECT $mycall $t" else "CONNECT $mycall $t VIA ${via.joinToString(" ")}"
        val reply = try {
            waitFor({ it.startsWith("CONNECTED ") || it == "DISCONNECTED" || it == "WRONG" }, config.connectTimeout, line) { send(line) }
        } catch (e: Throwable) {
            withContext(NonCancellable) {
                linkGone()
                if (state != VARALinkState.Closed) {
                    runCatching { send("ABORT") }
                    setState(VARALinkState.Idle)
                }
            }
            throw e
        }
        when (reply) {
            "WRONG" -> {
                linkGone()
                setState(VARALinkState.Idle)
                throw VARAException.Rejected(line)
            }
            "DISCONNECTED" -> {
                setState(VARALinkState.Idle)
                throw VARAException.ConnectFailed("no answer from $t")
            }
            else -> return conn
        }
    }

    /** Listens for an incoming call (P2P, or a test gateway) and returns the link once connected. */
    suspend fun accept(timeout: Double = 3600.0): VARAConnection {
        if (state != VARALinkState.Idle) throw VARAException.NotIdle()
        val conn = VARAConnection(this, "")
        _buffer = 0
        link = conn
        try {
            required("LISTEN ON", attempts = 1)
            val reply = waitFor({ it.startsWith("CONNECTED ") }, timeout, "an incoming call") {}
            val p = reply.split(" ")
            conn.remote = p.getOrElse(1) { "" }
            return conn
        } catch (e: Throwable) {
            withContext(NonCancellable) {
                linkGone()
                runCatching { command("LISTEN OFF") }
            }
            throw e
        }
    }

    /** Asks the modem to end the link gracefully, falling back to ABORT after [timeout] seconds. */
    suspend fun disconnect(timeout: Double = 60.0) {
        when (state) {
            is VARALinkState.Connected, is VARALinkState.Connecting, VARALinkState.Disconnecting -> {}
            else -> return
        }
        setState(VARALinkState.Disconnecting)
        try {
            waitFor({ it == "DISCONNECTED" }, timeout, "DISCONNECT") { send("DISCONNECT") }
        } catch (e: Exception) {
            abort()
        }
    }

    /** Drops the link at once. */
    suspend fun abort() {
        runCatching { send("ABORT") }
        linkGone()
        if (state != VARALinkState.Closed) setState(VARALinkState.Idle)
    }

    /** Waits for the modem's TX buffer to drop below [limit] bytes (or to empty when limit is 1). */
    internal suspend fun waitForBuffer(limit: Int, timeout: Double = 120.0) {
        while (true) {
            if (state !is VARALinkState.Connected) throw StreamException.Closed()
            if (_buffer < limit) return
            // Each BUFFER report resets the timeout: the link is alive as long as it drains.
            waitFor(
                { it.startsWith("BUFFER") || it == "DISCONNECTED" }, timeout, "buffer to drain",
                ready = { _buffer < limit || state !is VARALinkState.Connected },
            ) {}
        }
    }

    internal fun noteWritten(n: Int) = synchronized(lock) { _buffer += n }

    internal suspend fun writeData(bytes: ByteArray) {
        val d = data ?: throw VARAException.ModemClosed()
        d.write(bytes)
    }

    // Readers

    private suspend fun commandLoop(c: TCPStream) {
        var pending = ByteArray(0)
        while (true) {
            val chunk = try { c.read() } catch (_: Exception) { ByteArray(0) }
            if (chunk.isEmpty()) break
            pending += chunk
            while (true) {
                val i = pending.indexOf(13.toByte())
                if (i < 0) break
                val line = String(pending, 0, i, Charsets.UTF_8).trim()
                pending = pending.copyOfRange(i + 1, pending.size)
                if (line.isNotEmpty()) handle(line)
            }
        }
        modemGone()
    }

    private suspend fun dataLoop(d: TCPStream) {
        while (true) {
            val chunk = try { d.read() } catch (_: Exception) { ByteArray(0) }
            if (chunk.isEmpty()) break
            // Data outside a link is stale; drop it.
            link?.deliver(chunk)
        }
    }

    private fun handle(line: String) {
        onEvent(VARAEvent.Line(line, false))
        when (line) {
            "PTT ON", "PTT OFF" -> {
                ptt = line == "PTT ON"
                onEvent(VARAEvent.Ptt(ptt))
            }
            "BUSY ON", "BUSY OFF" -> {
                busy = line == "BUSY ON"
                onEvent(VARAEvent.Busy(busy))
            }
            "DISCONNECTED" -> {
                linkGone()
                if (state != VARALinkState.Closed) setState(VARALinkState.Idle)
            }
            else -> when {
                line.startsWith("BUFFER ") -> {
                    val n = line.drop(7).trim().toIntOrNull() ?: 0
                    _buffer = n
                    onEvent(VARAEvent.Buffer(n))
                }
                line.startsWith("CONNECTED ") -> {
                    // CONNECTED <caller> <answerer> [VIA ...] <width>
                    val p = line.split(" ").filter { it.isNotEmpty() }
                    setState(VARALinkState.Connected(p.getOrElse(1) { "" }, p.getOrElse(2) { "" }, p.last()))
                }
                line.startsWith("BITRATE") -> onEvent(VARAEvent.Bitrate(line.drop(7).trim()))
                line.startsWith("SN ") -> line.drop(3).toDoubleOrNull()?.let { onEvent(VARAEvent.Snr(it)) }
            }
        }
        for ((id, w) in waiters.entries.toList()) {
            if (w.match(line) && waiters.remove(id) != null) w.result.complete(line)
        }
    }

    private fun setState(s: VARALinkState) {
        val changed = synchronized(lock) {
            val c = _state != s
            _state = s
            c
        }
        if (changed) onEvent(VARAEvent.State(s))
    }

    private fun linkGone() {
        val l = link
        link = null
        l?.remoteClosed()
    }

    private fun modemGone() {
        linkGone()
        cmd = null
        for (id in waiters.keys.toList()) waiters.remove(id)?.result?.completeExceptionally(VARAException.ModemClosed())
        setState(VARALinkState.Closed)
    }
}

/** The ARQ link to the remote station, carried on the modem's data port. */
class VARAConnection internal constructor(private val modem: VARAModem, remote: String) : ByteStream {
    @Volatile var remote: String = remote; internal set
    private val inbox = Channel<ByteArray>(Channel.UNLIMITED)
    @Volatile private var ended = false
    @Volatile private var lastWrite = 0L

    internal fun deliver(b: ByteArray) {
        inbox.trySend(b)
    }

    internal fun remoteClosed() {
        // Data the modem sent just before DISCONNECTED may still be in flight on the data port.
        CoroutineScope(Dispatchers.IO).launch {
            delay(500)
            ended = true
            inbox.close()
        }
    }

    override suspend fun read(): ByteArray = try {
        inbox.receive()
    } catch (_: ClosedReceiveChannelException) {
        ByteArray(0)
    }

    override suspend fun write(bytes: ByteArray) {
        if (ended) throw StreamException.Closed()
        // Keep the modem's queue short so a flush means "on the air", as Pat does.
        modem.waitForBuffer(maxOf(7 * bytes.size, 1))
        modem.noteWritten(bytes.size)
        lastWrite = System.currentTimeMillis()
        modem.writeData(bytes)
    }

    override suspend fun flush() {
        if (ended) return
        modem.waitForBuffer(1)
    }

    override suspend fun close() {
        if (ended) return
        // Let the last frame go out before asking to disconnect.
        val since = System.currentTimeMillis() - lastWrite
        if (since < 2000) delay(2000 - since)
        runCatching { modem.waitForBuffer(1, timeout = 60.0) }
        modem.disconnect()
    }
}
