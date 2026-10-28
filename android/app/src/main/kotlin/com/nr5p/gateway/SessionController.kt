package com.nr5p.gateway

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.nr5p.winlink.B2FException
import com.nr5p.winlink.B2FSession
import com.nr5p.winlink.ByteStream
import com.nr5p.winlink.CMSTelnet
import com.nr5p.winlink.LinkSpeed
import com.nr5p.winlink.Mailbox
import com.nr5p.winlink.SessionEvent
import com.nr5p.winlink.VARAConfig
import com.nr5p.winlink.VARAEvent
import com.nr5p.winlink.VARALinkState
import com.nr5p.winlink.VARAMode
import com.nr5p.winlink.VARAModem
import com.nr5p.winlink.rig.DialFrequency
import com.nr5p.winlink.rig.RigMode
import com.nr5p.winlink.write
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.time.Instant
import java.util.concurrent.atomic.AtomicLong

data class LogLine(val kind: Kind, val text: String, val time: Instant = Instant.now(), val id: Long = nextId.incrementAndGet()) {
    enum class Kind { INFO, SENT, RECEIVED, MODEM_SENT, MODEM_RECEIVED, ERROR }

    companion object {
        private val nextId = AtomicLong()
    }
}

data class Progress(val title: String, val sending: Boolean, val done: Int, val total: Int)

class SessionException(message: String) : Exception(message)

/** Runs one connection at a time: dial (VARA or telnet), exchange messages, hang up. */
class SessionController(private val settings: Settings) {
    var running by mutableStateOf(false); private set
    var status by mutableStateOf("Idle"); private set
    val log = mutableStateListOf<LogLine>()
    var ptt by mutableStateOf(false); private set
    var busy by mutableStateOf(false); private set
    var linkState: VARALinkState by mutableStateOf(VARALinkState.Closed); private set
    var progress: Progress? by mutableStateOf(null); private set
    /** The link's current speed level, bitrate and modulation, from the modem's BITRATE lines. */
    var speed: LinkSpeed? by mutableStateOf(null); private set
    private var speedMode = VARAMode.HF
    private var speedBandwidth: String? = null

    // Terminal (keyboard to keyboard: a BBS or node, or another operator)
    var terminal by mutableStateOf(""); private set
    var terminalLinked by mutableStateOf(false); private set

    private val main = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var task: Job? = null
    private var modem: VARAModem? = null
    private var stream: ByteStream? = null
    private var rig: RigController? = null
    private var rigKeysPTT = false

    fun clearLog() = log.clear()

    fun append(kind: LogLine.Kind, text: String) {
        log.add(LogLine(kind, text))
        if (log.size > 2000) log.removeRange(0, log.size - 2000)
    }

    /** From any thread. */
    private fun post(f: () -> Unit) {
        main.launch { f() }
    }

    fun start(store: MailStore, rig: RigController) {
        if (running) return
        val mycall = settings.mycall
        if (mycall.isEmpty()) {
            append(LogLine.Kind.ERROR, "Set your call sign in Settings first.")
            return
        }
        val kind = settings.transportKind
        val answering = kind == TransportKind.LISTEN || (kind == TransportKind.TERMINAL && settings.terminalAnswer)
        val target = (if (kind == TransportKind.VARA) settings.gateway else settings.peer).trim().uppercase()
        if (kind.usesRadio && !answering && target.isEmpty()) {
            append(
                LogLine.Kind.ERROR,
                if (kind == TransportKind.VARA) "Enter the gateway (RMS) call sign to connect to." else "Enter the call sign of the station to call.",
            )
            return
        }
        val password = settings.password
        val locator = settings.locator.trim()
        val mailbox = store.sessionMailbox { post { store.reload() } }
        val cfg = VARAConfig(
            host = settings.modemHost.trim(), commandPort = settings.modemPort, mycall = mycall, mode = settings.mode,
            bandwidth = if (settings.mode == VARAMode.HF) settings.bandwidth else null, connectTimeout = 300.0,
        )
        speedMode = cfg.mode
        speedBandwidth = cfg.bandwidth
        speed = null
        val cmsHost = settings.cmsHost.trim()
        val cmsPort = settings.cmsPort
        val useRig = kind.usesRadio && settings.rigMode != RigControlMode.OFF
        val dialText = settings.dialFrequency.trim()
        val dial = DialFrequency.parse(dialText)
        if (useRig && dialText.isNotEmpty() && dial == null) {
            append(LogLine.Kind.ERROR, "$dialText is not a frequency. Use kHz (14105.0) or MHz (14.105).")
            return
        }
        if (kind == TransportKind.VARA) {
            settings.remember(target)
            if (dial != null) settings.remember(dial, target)
        }
        this.rig = if (useRig) rig else null
        rigKeysPTT = useRig && settings.rigKeysPTT
        terminal = ""

        running = true
        progress = null
        task = main.launch {
            try {
                if (kind == TransportKind.TELNET) {
                    status = "Connecting to $cmsHost:$cmsPort"
                    append(LogLine.Kind.INFO, status)
                    val conn = CMSTelnet.connect(mycall, cmsHost, cmsPort) { l -> post { append(LogLine.Kind.RECEIVED, l) } }
                    stream = conn
                    exchange(conn, mycall, CMSTelnet.TARGET_CALL, locator, mailbox, false, password)
                } else {
                    if (useRig) {
                        status = dial?.let { "Tuning the radio to ${DialFrequency.format(it)}" } ?: "Opening the radio"
                        try {
                            rig.prepare(dial, if (cfg.mode == VARAMode.FM) RigMode.DATA_FM else RigMode.DATA_USB)
                        } catch (e: CancellationException) {
                            throw e
                        } catch (e: Exception) {
                            // Never transmit on whatever frequency the radio happens to be on.
                            if (dial != null) throw SessionException("radio: ${e.message}")
                            append(LogLine.Kind.ERROR, "Radio: ${e.message}. Continuing without radio control.")
                        }
                    }
                    status = "Opening modem ${cfg.host}:${cfg.commandPort}"
                    append(LogLine.Kind.INFO, status)
                    val m = VARAModem(cfg)
                    m.onEvent = { e -> post { modemEvent(e) } }
                    modem = m
                    m.open()
                    append(LogLine.Kind.INFO, "Modem: ${m.version}")
                    if (answering) {
                        // Answer calls until aborted: a P2P partner may call more than once.
                        while (isActive) {
                            status = "Listening as $mycall on VARA ${cfg.mode.raw}"
                            append(LogLine.Kind.INFO, status)
                            val link = m.accept(24 * 3600.0)
                            stream = link
                            append(LogLine.Kind.INFO, "Call from ${link.remote}")
                            try {
                                if (kind == TransportKind.TERMINAL) {
                                    runTerminal(link, link.remote)
                                } else {
                                    exchange(link, mycall, link.remote, locator, mailbox, true, password)
                                }
                            } catch (e: CancellationException) {
                                throw e
                            } catch (e: Exception) {
                                append(LogLine.Kind.ERROR, "Session with ${link.remote} failed: ${e.message}")
                            }
                            m.disconnect(30.0)
                            stream = null
                        }
                    } else {
                        status = "Calling $target"
                        append(LogLine.Kind.INFO, "Calling $target on VARA ${cfg.mode.raw}" + (cfg.bandwidth?.let { " $it Hz" } ?: ""))
                        val conn = m.connect(target)
                        stream = conn
                        if (kind == TransportKind.TERMINAL) {
                            runTerminal(conn, target)
                        } else {
                            // A P2P partner is a master like a gateway; only mail addressed to it goes.
                            exchange(conn, mycall, target, locator, mailbox, false, password)
                        }
                        m.disconnect(30.0)
                    }
                }
            } catch (e: CancellationException) {
                status = "Aborted"
                append(LogLine.Kind.ERROR, status)
            } catch (e: B2FException) {
                if (e.isLoginFailure) {
                    status = "Login failed: check your Winlink password"
                    append(LogLine.Kind.ERROR, e.message ?: "")
                } else {
                    status = "Failed: ${e.message}"
                    append(LogLine.Kind.ERROR, status)
                }
            } catch (e: Exception) {
                status = "Failed: ${e.message ?: e.javaClass.simpleName}"
                append(LogLine.Kind.ERROR, status)
            }
            withContext(NonCancellable) {
                this@SessionController.rig?.sessionEnded()
                modem?.close()
            }
            modem = null
            stream = null
            progress = null
            running = false
            store.reload()
        }
    }

    /** One B2F exchange: as the client (calling a gateway or a P2P station) or as the master
     *  (answering a P2P call, announcing our call so the caller sends only mail for us). */
    private suspend fun exchange(
        conn: ByteStream, mycall: String, target: String, locator: String, mailbox: Mailbox, master: Boolean, password: String,
    ) {
        status = "Connected to $target"
        append(LogLine.Kind.INFO, status)
        val session = B2FSession(mycall, target, locator, mailbox)
        session.isMaster = master
        session.userAgent = B2FSession.UserAgent("Gateway", BuildConfig.VERSION_NAME)
        session.password = { addr -> if (addr.addr == mycall && password.isNotEmpty()) password else null }
        session.onEvent = { e -> post { sessionEvent(e) } }
        val stats = withContext(Dispatchers.IO) { session.exchange(conn) }
        status = "Done with $target: ${stats.sent.size} sent, ${stats.received.size} received"
        append(LogLine.Kind.INFO, status)
    }

    private suspend fun runTerminal(conn: ByteStream, remote: String) {
        status = "Terminal: connected to $remote"
        append(LogLine.Kind.INFO, status)
        terminalLinked = true
        try {
            terminal += "*** Connected to $remote\n"
            while (true) {
                val bytes = conn.read()
                if (bytes.isEmpty()) break
                // BBSes end lines with CR; keep printable text, tabs and line breaks.
                val text = String(bytes, Charsets.UTF_8).replace("\r\n", "\n").replace("\r", "\n")
                    .filter { it == '\n' || it == '\t' || !(it.code < 32 || it.code == 127) }
                terminal += text
                if (terminal.length > 100_000) terminal = terminal.takeLast(80_000)
            }
            terminal += "\n*** Disconnected\n"
            status = "Terminal: $remote disconnected"
            append(LogLine.Kind.INFO, status)
        } finally {
            terminalLinked = false
        }
    }

    /** Sends a typed line over the terminal link (CR-terminated, like a packet terminal). */
    fun sendTerminal(line: String) {
        val s = stream
        if (!terminalLinked || s == null) return
        terminal += line + "\n"
        main.launch {
            try {
                s.write("$line\r")
            } catch (e: Exception) {
                append(LogLine.Kind.ERROR, "Send failed: ${e.message}")
            }
        }
    }

    /** Ends a terminal link politely (the modem disconnects), leaving listening on. */
    fun hangUp() {
        val m = modem ?: return
        main.launch { m.disconnect(30.0) }
    }

    /** Stops at once: ABORT to the modem (drops the RF link) or closes the socket. */
    fun abort() {
        if (!running) return
        append(LogLine.Kind.ERROR, "Aborting")
        val m = modem
        val s = stream
        CoroutineScope(Dispatchers.IO).launch {
            m?.abort()
            s?.close()
            m?.close()
        }
        task?.cancel()
    }

    private fun modemEvent(e: VARAEvent) {
        when (e) {
            is VARAEvent.Line -> {
                val l = e.text
                if (settings.showModemTraffic && !l.startsWith("PTT ") && !l.startsWith("BUFFER") && l != "IAMALIVE") {
                    append(if (e.outbound) LogLine.Kind.MODEM_SENT else LogLine.Kind.MODEM_RECEIVED, l)
                }
            }
            is VARAEvent.State -> {
                linkState = e.state
                if (e.state is VARALinkState.Connecting || e.state == VARALinkState.Idle || e.state == VARALinkState.Closed) speed = null
                if (e.state == VARALinkState.Closed) {
                    if (ptt && rigKeysPTT) rig?.followModem(false)
                    ptt = false
                    busy = false
                }
            }
            is VARAEvent.Ptt -> {
                ptt = e.on
                if (rigKeysPTT) rig?.followModem(e.on)
            }
            is VARAEvent.Busy -> busy = e.on
            is VARAEvent.Bitrate -> speed = LinkSpeed.parse(e.text, speedMode, speedBandwidth) ?: speed
            else -> {}
        }
    }

    private fun sessionEvent(e: SessionEvent) {
        when (e) {
            is SessionEvent.Line -> append(if (e.outbound) LogLine.Kind.SENT else LogLine.Kind.RECEIVED, e.text)
            is SessionEvent.Info -> append(LogLine.Kind.INFO, e.text)
            is SessionEvent.Progress -> progress = Progress(e.title, e.sending, e.done, e.total)
        }
    }
}
