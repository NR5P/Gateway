package com.nr5p.winlink

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.IOException
import java.net.InetSocketAddress
import java.net.Socket
import java.net.SocketTimeoutException

class TCPException(host: String, port: Int, reason: String) : IOException("cannot connect to $host:$port: $reason")

/** A TCP connection as a ByteStream. */
class TCPStream private constructor(private val socket: Socket) : ByteStream {
    private val input = socket.getInputStream()
    private val output = socket.getOutputStream()
    @Volatile private var isClosed = false

    companion object {
        suspend fun connect(host: String, port: Int, timeoutSeconds: Double = 10.0): TCPStream = withContext(Dispatchers.IO) {
            val s = Socket()
            try {
                s.tcpNoDelay = true
                s.connect(InetSocketAddress(host, port), (timeoutSeconds * 1000).toInt())
            } catch (e: SocketTimeoutException) {
                s.close()
                throw StreamException.Timeout("connecting to $host:$port")
            } catch (e: IOException) {
                s.close()
                throw TCPException(host, port, e.message ?: e.javaClass.simpleName)
            }
            TCPStream(s)
        }
    }

    override suspend fun read(): ByteArray = withContext(Dispatchers.IO) {
        if (isClosed) return@withContext ByteArray(0)
        val buf = ByteArray(65536)
        try {
            val n = input.read(buf)
            if (n < 0) ByteArray(0) else buf.copyOf(n)
        } catch (e: IOException) {
            // A local close fails pending reads; treat that as end of stream.
            if (isClosed) ByteArray(0) else throw e
        }
    }

    override suspend fun write(bytes: ByteArray) = withContext(Dispatchers.IO) {
        if (isClosed) throw StreamException.Closed()
        output.write(bytes)
        output.flush()
    }

    override suspend fun flush() {}

    override suspend fun close() {
        if (isClosed) return
        isClosed = true
        withContext(Dispatchers.IO) { runCatching { socket.close() } }
    }
}
