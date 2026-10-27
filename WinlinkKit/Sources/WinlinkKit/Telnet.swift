// Telnet login to the Winlink CMS, the internet transport.
//
// Follows wl2k-go's transport/telnet (MIT): answer the "Callsign :" and
// "Password :" prompts, after which the CMS starts a B2F session.

import Foundation

public enum CMSTelnet {
    public static let host = "server.winlink.org"
    public static let port: UInt16 = 8772
    /// The fixed telnet password; the account password is checked by the B2F secure login.
    public static let password = "CMSTelnet"
    public static let targetCall = "WL2K"

    /// Connects and logs in, returning a stream positioned at the start of the B2F handshake.
    public static func connect(mycall: String, host: String = host, port: UInt16 = port,
                               log: (String) -> Void = { _ in }) async throws -> ByteStream {
        let tcp = try await TCPStream.connect(host: host, port: port, timeout: 30)
        do {
            let rest = try await login(tcp, mycall: mycall, log: log)
            return PrefixedStream(tcp, prefix: rest)
        } catch {
            await tcp.close()
            throw error
        }
    }

    /// Answers the prompts on `stream` and returns any bytes read past the password prompt.
    static func login(_ stream: ByteStream, mycall: String, log: (String) -> Void) async throws -> [UInt8] {
        var buf: [UInt8] = []
        var sentCall = false
        while true {
            let chunk = try await stream.read()
            if chunk.isEmpty { throw StreamError.closed }
            buf += chunk
            // Prompts may arrive without a line ending, so look at whatever we have.
            while true {
                if !sentCall, let at = find("callsign", in: buf) {
                    let end = lineEnd(buf, from: at)
                    log(String(decoding: buf[..<end], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
                    buf.removeFirst(end)
                    try await stream.write("\(mycall.uppercased())\r")
                    sentCall = true
                    continue
                }
                if let at = find("password", in: buf) {
                    let end = lineEnd(buf, from: at)
                    log(String(decoding: buf[..<end], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
                    buf.removeFirst(end)
                    try await stream.write("\(password)\r")
                    return buf
                }
                break
            }
        }
    }

    /// The index just past a case-insensitive ASCII match of `needle`.
    private static func find(_ needle: String, in b: [UInt8]) -> Int? {
        let n = Array(needle.utf8)
        guard b.count >= n.count else { return nil }
        for i in 0...(b.count - n.count) {
            var ok = true
            for j in 0..<n.count where (b[i + j] | 0x20) != n[j] {
                ok = false
                break
            }
            if ok { return i + n.count }
        }
        return nil
    }

    /// The index just past the prompt: through a CR/LF if one follows, else through a trailing ':' and spaces.
    private static func lineEnd(_ b: [UInt8], from: Int) -> Int {
        var i = min(from, b.count)
        while i < b.count, b[i] != 13, b[i] != 10 { i += 1 }
        while i < b.count, b[i] == 13 || b[i] == 10 { i += 1 }
        return i
    }
}
