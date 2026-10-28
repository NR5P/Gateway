package com.nr5p.winlink.rig

import com.nr5p.winlink.ByteStream
import com.nr5p.winlink.StreamException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

/** Reads a ByteStream in the background so a caller can wait for a delimiter with a time limit
 *  (a plain `read()` on a quiet radio link would wait forever). */
internal class Inbox(stream: ByteStream) {
    private val lock = Any()
    private var buf = ByteArray(0)
    private var failure: Exception? = null
    private val signal = Channel<Unit>(Channel.CONFLATED)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    init {
        scope.launch {
            while (isActive) {
                try {
                    val bytes = stream.read()
                    if (bytes.isEmpty()) {
                        fail(StreamException.Closed())
                        return@launch
                    }
                    synchronized(lock) { buf += bytes }
                    signal.trySend(Unit)
                } catch (e: Exception) {
                    fail(e)
                    return@launch
                }
            }
        }
    }

    fun cancel() {
        scope.cancel()
        fail(StreamException.Closed())
    }

    private fun fail(e: Exception) {
        synchronized(lock) { if (failure == null) failure = e }
        signal.trySend(Unit)
    }

    /** Bytes up to and including [delim], arriving within [timeout] seconds. */
    suspend fun take(delim: Int, timeout: Double, what: String): ByteArray {
        val deadline = System.currentTimeMillis() + (timeout * 1000).toLong()
        while (true) {
            val got = synchronized(lock) {
                val i = buf.indexOf(delim.toByte())
                if (i >= 0) {
                    val out = buf.copyOfRange(0, i + 1)
                    buf = buf.copyOfRange(i + 1, buf.size)
                    out
                } else {
                    failure?.let { throw it }
                    null
                }
            }
            if (got != null) return got
            val left = deadline - System.currentTimeMillis()
            if (left <= 0) throw StreamException.Timeout(what)
            withTimeoutOrNull(left) { signal.receive() }
        }
    }

    suspend fun line(timeout: Double, what: String): String =
        String(take(10, timeout, what), Charsets.UTF_8).trim()
}
