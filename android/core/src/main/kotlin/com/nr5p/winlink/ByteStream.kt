package com.nr5p.winlink

import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.ClosedReceiveChannelException

/** A reliable, ordered byte connection: a TCP socket, a VARA ARQ link, a test pipe. */
interface ByteStream {
    /** The next chunk of bytes; an empty array means the remote closed the stream. */
    suspend fun read(): ByteArray
    suspend fun write(bytes: ByteArray)
    /** Returns once everything written has left this station (for VARA: the modem's TX buffer is empty). */
    suspend fun flush()
    suspend fun close()
}

suspend fun ByteStream.write(s: String) = write(s.toByteArray(Charsets.UTF_8))

open class StreamException(message: String) : java.io.IOException(message) {
    class Closed : StreamException("connection lost")
    class Timeout(what: String) : StreamException("timed out $what")
}

/** Buffered reading on top of a ByteStream. */
internal class StreamReader(val stream: ByteStream, prefix: ByteArray = ByteArray(0)) {
    private var buf = prefix
    private var pos = 0

    private suspend fun fill() {
        val more = stream.read()
        if (more.isEmpty()) throw StreamException.Closed()
        buf = buf.copyOfRange(pos, buf.size) + more
        pos = 0
    }

    suspend fun peek(): Int {
        while (pos >= buf.size) fill()
        return buf[pos].u
    }

    suspend fun readByte(): Int {
        val b = peek()
        pos += 1
        return b
    }

    /** Bytes up to and including [delim]. */
    suspend fun readUntil(delim: Int): ByteArray {
        var from = pos
        while (true) {
            for (i in from until buf.size) {
                if (buf[i].u == delim) {
                    val out = buf.copyOfRange(pos, i + 1)
                    pos = i + 1
                    return out
                }
            }
            val off = buf.size - pos
            fill()
            from = pos + off
        }
    }

    suspend fun read(count: Int): ByteArray {
        while (buf.size - pos < count) fill()
        val out = buf.copyOfRange(pos, pos + count)
        pos += count
        return out
    }

    /** Whatever is buffered but not yet consumed. */
    fun drain(): ByteArray {
        val out = buf.copyOfRange(pos, buf.size)
        pos = buf.size
        return out
    }
}

/** A ByteStream that first replays [prefix], then reads from [inner]. */
internal class PrefixedStream(private val inner: ByteStream, prefix: ByteArray) : ByteStream {
    @Volatile private var prefix: ByteArray? = prefix

    override suspend fun read(): ByteArray {
        val p = synchronized(this) { prefix.also { prefix = null } }
        if (p != null && p.isNotEmpty()) return p
        return inner.read()
    }

    override suspend fun write(bytes: ByteArray) = inner.write(bytes)
    override suspend fun flush() = inner.flush()
    override suspend fun close() = inner.close()
}

/** An in-memory duplex pipe, for tests and loopback sessions. */
class PipeStream private constructor() : ByteStream {
    private val inbox = Channel<ByteArray>(Channel.UNLIMITED)
    private lateinit var peer: PipeStream

    companion object {
        fun pair(): Pair<PipeStream, PipeStream> {
            val a = PipeStream()
            val b = PipeStream()
            a.peer = b
            b.peer = a
            return a to b
        }
    }

    private fun hangup() {
        inbox.close()
    }

    override suspend fun read(): ByteArray = try {
        inbox.receive()
    } catch (_: ClosedReceiveChannelException) {
        ByteArray(0)
    }

    override suspend fun write(bytes: ByteArray) {
        if (inbox.isClosedForSend || peer.inbox.trySend(bytes).isFailure) throw StreamException.Closed()
    }

    override suspend fun flush() {}

    override suspend fun close() {
        hangup()
        peer.hangup()
    }
}
