import Darwin
import Foundation

/// Somewhere a radio can be controlled from.
public struct RigEndpoint: Hashable, Sendable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable {
        case righelm = "RigHelm"
        case rigctld = "rigctld"
    }

    public var kind: Kind
    public var host: String
    public var port: UInt16
    /// The RigHelm station's name, or "" for rigctld.
    public var name: String
    /// RigHelm: a password is set, so the station can allow transmit.
    public var auth: Bool
    /// RigHelm: the station's own link to its radio ("connected", "not-answering", ...).
    public var radio: String

    public var id: String { "\(kind.rawValue)@\(host):\(port)" }

    public init(kind: Kind, host: String, port: UInt16, name: String = "", auth: Bool = false, radio: String = "") {
        (self.kind, self.host, self.port, self.name, self.auth, self.radio) = (kind, host, port, name, auth, radio)
    }

    public var title: String {
        switch kind {
        case .righelm: return "RigHelm \(name.isEmpty ? host : name)"
        case .rigctld: return "rigctld \(host):\(port)"
        }
    }
}

/// Finds radios on this device and the LAN:
/// - RigHelm stations, which answer a `FTDX3000-DISCOVER` probe on UDP 4534. iOS only lets an
///   app broadcast with Apple's multicast entitlement, so the probe also goes straight to every
///   address on the subnet (the answers are unicast and need no entitlement), and to 127.0.0.1.
/// - rigctld (hamlib, or RigHelm's own) on 127.0.0.1:4532 and on any `hosts` given, such as
///   the machine running the modem.
public enum RigDiscovery {
    static let discoveryPort: UInt16 = 4534
    static let probe = Array("FTDX3000-DISCOVER".utf8)

    public static func scan(duration: TimeInterval = 2.5, hosts: [String] = []) async -> [RigEndpoint] {
        async let helms = righelm(duration: duration)
        var rigctlds: [RigEndpoint] = []
        await withTaskGroup(of: RigEndpoint?.self) { g in
            for h in Set(["127.0.0.1"] + hosts.filter { !$0.isEmpty }) {
                g.addTask { await rigctld(host: h) }
            }
            for await e in g { if let e { rigctlds.append(e) } }
        }
        return await helms + rigctlds.sorted { $0.host < $1.host }
    }

    /// A rigctld answering `f` with a frequency within a second or two.
    static func rigctld(host: String, port: UInt16 = RigctldRig.defaultPort) async -> RigEndpoint? {
        guard let s = try? await TCPStream.connect(host: host, port: port, timeout: 1.5) else { return nil }
        defer { Task { await s.close() } }
        let inbox = Inbox(s)
        defer { inbox.cancel() }
        guard (try? await s.write("f\n")) != nil,
              let l = try? await inbox.line(timeout: 1.5, what: "rigctld"), Double(l) != nil
        else { return nil }
        return RigEndpoint(kind: .rigctld, host: host, port: port)
    }

    static func righelm(duration: TimeInterval) async -> [RigEndpoint] {
        await withCheckedContinuation { c in
            DispatchQueue.global(qos: .userInitiated).async {
                c.resume(returning: probeRigHelm(duration: duration))
            }
        }
    }

    private static func probeRigHelm(duration: TimeInterval) -> [RigEndpoint] {
        guard let sock = UDPSocket(port: discoveryPort) ?? UDPSocket(port: 0) else { return [] }
        defer { sock.close() }
        var found: [String: RigEndpoint] = [:]
        let end = Date().addingTimeInterval(duration)
        var nextProbe = Date.distantPast
        while Date() < end {
            if Date() >= nextProbe {
                sock.send(probe, to: 0x7F00_0001, port: discoveryPort)
                sock.send(probe, to: 0xFFFF_FFFF, port: discoveryPort)
                for iface in lanInterfaces() {
                    sock.send(probe, to: iface.broadcast, port: discoveryPort)
                    for host in sweep(iface) { sock.send(probe, to: host, port: discoveryPort) }
                }
                nextProbe = Date().addingTimeInterval(1)
            }
            if let (bytes, ip) = sock.receive(timeout: 0.2),
               let (id, e) = parseBeacon(String(decoding: bytes, as: UTF8.self), from: ipString(ip)) {
                // The same station answers on loopback and on its LAN address; keep loopback.
                if found[id]?.host != "127.0.0.1" { found[id] = e }
            }
        }
        return found.values.sorted { $0.name < $1.name }
    }

    /// `FTDX3000-REMOTE v1;id=...;name=...;port=4533;audio=1;auth=1;mic=1;radio=connected`
    static func parseBeacon(_ text: String, from host: String) -> (String, RigEndpoint)? {
        guard text.hasPrefix(RigHelmRig.greeting) else { return nil }
        var f: [String: String] = [:]
        for p in text.split(separator: ";").dropFirst() {
            if let eq = p.firstIndex(of: "=") { f[String(p[..<eq])] = String(p[p.index(after: eq)...]) }
        }
        guard let id = f["id"], UInt64(id, radix: 16) != nil, let port = f["port"].flatMap({ UInt16($0) }) else { return nil }
        return (id, RigEndpoint(kind: .righelm, host: host, port: port, name: f["name"] ?? "", auth: f["auth"] == "1", radio: f["radio"] ?? ""))
    }

    /// Every other host on the interface's subnet; for one bigger than /22, the /24 around us.
    static func sweep(_ iface: NetInterface) -> [UInt32] {
        var mask = iface.netmask
        if mask < 0xFFFF_FC00 { mask = 0xFFFF_FF00 }
        let net = iface.address & mask
        let bcast = net | ~mask
        guard bcast > net + 1 else { return [] }
        return (net + 1..<bcast).filter { $0 != iface.address }
    }
}

// MARK: - BSD sockets (UDP broadcast is not something Network.framework does)

func ipString(_ ip: UInt32) -> String {
    "\(ip >> 24 & 0xff).\(ip >> 16 & 0xff).\(ip >> 8 & 0xff).\(ip & 0xff)"
}

extension sockaddr_in {
    init(ip: UInt32, port: UInt16) {
        self.init()
        sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sin_family = sa_family_t(AF_INET)
        sin_port = port.bigEndian
        sin_addr = in_addr(s_addr: ip.bigEndian)
    }

    var ip: UInt32 { UInt32(bigEndian: sin_addr.s_addr) }
}

final class UDPSocket {
    private let fd: Int32

    init?(port: UInt16) {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        var one: Int32 = 1
        for opt in [SO_NOSIGPIPE, SO_REUSEADDR, SO_REUSEPORT, SO_BROADCAST] {
            setsockopt(fd, SOL_SOCKET, opt, &one, socklen_t(MemoryLayout<Int32>.size))
        }
        var addr = sockaddr_in(ip: 0, port: port)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard rc == 0 else {
            Darwin.close(fd)
            return nil
        }
        self.fd = fd
    }

    @discardableResult
    func send(_ bytes: [UInt8], to ip: UInt32, port: UInt16) -> Bool {
        var addr = sockaddr_in(ip: ip, port: port)
        let n = withUnsafePointer(to: &addr) { a in
            a.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bytes.withUnsafeBytes { sendto(fd, $0.baseAddress, $0.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }
        return n == bytes.count
    }

    func receive(timeout: TimeInterval) -> (bytes: [UInt8], ip: UInt32)? {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&pfd, 1, Int32(timeout * 1000)) > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: 2048)
        var from = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let n = withUnsafeMutablePointer(to: &from) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &len) }
        }
        guard n > 0 else { return nil }
        return (Array(buf[0..<n]), from.ip)
    }

    func close() { Darwin.close(fd) }
}

struct NetInterface: Equatable {
    var address: UInt32
    var netmask: UInt32
    var broadcast: UInt32
}

/// Up, IPv4, broadcast-capable interfaces: Wi-Fi and Ethernet, not cellular, VPNs or link-local.
func lanInterfaces() -> [NetInterface] {
    var out: [NetInterface] = []
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0 else { return out }
    defer { freeifaddrs(list) }
    var p = list
    while let i = p {
        defer { p = i.pointee.ifa_next }
        let flags = Int32(i.pointee.ifa_flags)
        guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0, flags & IFF_BROADCAST != 0,
              let a = i.pointee.ifa_addr, a.pointee.sa_family == sa_family_t(AF_INET),
              let m = i.pointee.ifa_netmask
        else { continue }
        let addr = a.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.ip }
        let mask = m.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.ip }
        guard addr >> 16 != 0xA9FE else { continue }
        let iface = NetInterface(address: addr, netmask: mask, broadcast: addr | ~mask)
        if !out.contains(iface) { out.append(iface) }
    }
    return out
}
