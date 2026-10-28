package com.nr5p.winlink.rig

import com.nr5p.winlink.TCPStream
import com.nr5p.winlink.write
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.Inet4Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.net.SocketTimeoutException

/** Somewhere a radio can be controlled from. */
data class RigEndpoint(
    val kind: Kind,
    val host: String,
    val port: Int,
    /** The RigHelm station's name, or "" for rigctld. */
    val name: String = "",
    /** RigHelm: a password is set, so the station can allow transmit. */
    val auth: Boolean = false,
    /** RigHelm: the station's own link to its radio ("connected", "not-answering", ...). */
    val radio: String = "",
) {
    enum class Kind(val raw: String) { RIGHELM("RigHelm"), RIGCTLD("rigctld") }

    val id: String get() = "${kind.raw}@$host:$port"

    val title: String
        get() = when (kind) {
            Kind.RIGHELM -> "RigHelm ${name.ifEmpty { host }}"
            Kind.RIGCTLD -> "rigctld $host:$port"
        }
}

/** Finds radios on this device and the LAN:
 *  - RigHelm stations, which answer a `FTDX3000-DISCOVER` probe on UDP 4534. Some access points
 *    filter broadcasts, so the probe also goes straight to every address on the subnet (the
 *    answers are unicast), and to 127.0.0.1. On Android the app holds a multicast lock meanwhile.
 *  - rigctld (hamlib, or RigHelm's own) on 127.0.0.1:4532 and on any `hosts` given, such as
 *    the machine running the modem. */
object RigDiscovery {
    internal const val DISCOVERY_PORT = 4534
    private val PROBE = "FTDX3000-DISCOVER".toByteArray()

    suspend fun scan(duration: Double = 2.5, hosts: List<String> = emptyList()): List<RigEndpoint> = coroutineScope {
        val helms = async(Dispatchers.IO) { probeRigHelm(duration) }
        val rigctlds = (listOf("127.0.0.1") + hosts.filter { it.isNotEmpty() }).toSet()
            .map { h -> async { rigctld(h) } }.awaitAll().filterNotNull()
        helms.await() + rigctlds.sortedBy { it.host }
    }

    /** A rigctld answering `f` with a frequency within a second or two. */
    internal suspend fun rigctld(host: String, port: Int = RigctldRig.DEFAULT_PORT): RigEndpoint? {
        val s = try { TCPStream.connect(host, port, 1.5) } catch (_: Exception) { return null }
        val inbox = Inbox(s)
        try {
            s.write("f\n")
            val l = inbox.line(1.5, "rigctld")
            return if (l.toDoubleOrNull() != null) RigEndpoint(RigEndpoint.Kind.RIGCTLD, host, port) else null
        } catch (_: Exception) {
            return null
        } finally {
            inbox.cancel()
            s.close()
        }
    }

    private fun probeRigHelm(duration: Double): List<RigEndpoint> {
        val sock = openSocket(DISCOVERY_PORT) ?: openSocket(0) ?: return emptyList()
        sock.use {
            sock.soTimeout = 200
            val found = mutableMapOf<String, RigEndpoint>()
            val end = System.currentTimeMillis() + (duration * 1000).toLong()
            var nextProbe = 0L
            val buf = ByteArray(2048)
            while (System.currentTimeMillis() < end) {
                if (System.currentTimeMillis() >= nextProbe) {
                    send(sock, 0x7F00_0001)
                    send(sock, 0xFFFF_FFFF.toInt())
                    for (iface in lanInterfaces()) {
                        send(sock, iface.broadcast)
                        for (host in sweep(iface)) send(sock, host)
                    }
                    nextProbe = System.currentTimeMillis() + 1000
                }
                val p = DatagramPacket(buf, buf.size)
                try {
                    sock.receive(p)
                } catch (_: SocketTimeoutException) {
                    continue
                } catch (_: Exception) {
                    break
                }
                val host = p.address.hostAddress ?: continue
                val (id, e) = parseBeacon(String(p.data, 0, p.length, Charsets.UTF_8), host) ?: continue
                // The same station answers on loopback and on its LAN address; keep loopback.
                if (found[id]?.host != "127.0.0.1") found[id] = e
            }
            return found.values.sortedBy { it.name }
        }
    }

    private fun openSocket(port: Int): DatagramSocket? = try {
        DatagramSocket(null).apply {
            reuseAddress = true
            broadcast = true
            bind(InetSocketAddress(port))
        }
    } catch (_: Exception) {
        null
    }

    private fun send(sock: DatagramSocket, ip: Int) {
        runCatching { sock.send(DatagramPacket(PROBE, PROBE.size, ipAddress(ip), DISCOVERY_PORT)) }
    }

    /** `FTDX3000-REMOTE v1;id=...;name=...;port=4533;audio=1;auth=1;mic=1;radio=connected` */
    internal fun parseBeacon(text: String, host: String): Pair<String, RigEndpoint>? {
        if (!text.startsWith(RigHelmRig.GREETING)) return null
        val f = mutableMapOf<String, String>()
        for (p in text.trim().split(";").drop(1)) {
            val eq = p.indexOf('=')
            if (eq >= 0) f[p.substring(0, eq)] = p.substring(eq + 1)
        }
        val id = f["id"] ?: return null
        if (id.toULongOrNull(16) == null) return null
        val port = f["port"]?.toIntOrNull()?.takeIf { it in 1..65535 } ?: return null
        return id to RigEndpoint(RigEndpoint.Kind.RIGHELM, host, port, f["name"] ?: "", f["auth"] == "1", f["radio"] ?: "")
    }

    internal data class NetInterface(val address: Int, val netmask: Int, val broadcast: Int)

    /** Every other host on the interface's subnet; for one bigger than /22, the /24 around us. */
    internal fun sweep(iface: NetInterface): List<Int> {
        var mask = iface.netmask.toLong() and 0xffff_ffffL
        if (mask < 0xFFFF_FC00L) mask = 0xFFFF_FF00L
        val addr = iface.address.toLong() and 0xffff_ffffL
        val net = addr and mask
        val bcast = net or (mask.inv() and 0xffff_ffffL)
        if (bcast <= net + 1) return emptyList()
        return (net + 1 until bcast).filter { it != addr }.map { it.toInt() }
    }

    private fun ipAddress(ip: Int): InetAddress =
        InetAddress.getByAddress(byteArrayOf((ip ushr 24).toByte(), (ip ushr 16).toByte(), (ip ushr 8).toByte(), ip.toByte()))

    /** Up, IPv4, broadcast-capable interfaces: Wi-Fi and Ethernet, not cellular, VPNs or link-local. */
    private fun lanInterfaces(): List<NetInterface> {
        val out = mutableListOf<NetInterface>()
        val all = try { NetworkInterface.getNetworkInterfaces()?.toList() ?: emptyList() } catch (_: Exception) { emptyList() }
        for (ni in all) {
            if (!ni.isUp || ni.isLoopback || ni.isPointToPoint) continue
            for (ia in ni.interfaceAddresses) {
                val a = ia.address as? Inet4Address ?: continue
                if (ia.broadcast == null) continue
                val b = a.address
                val addr = (b[0].toInt() and 0xff shl 24) or (b[1].toInt() and 0xff shl 16) or (b[2].toInt() and 0xff shl 8) or (b[3].toInt() and 0xff)
                if ((addr ushr 16) == 0xA9FE) continue
                val prefix = ia.networkPrefixLength.toInt()
                val mask = if (prefix == 0) 0 else (-1 shl (32 - prefix))
                val iface = NetInterface(addr, mask, addr or mask.inv())
                if (iface !in out) out += iface
            }
        }
        return out
    }
}
