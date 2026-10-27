import Foundation
import Network

/// A TCP connection (Network.framework) as a ByteStream.
public final class TCPStream: ByteStream, @unchecked Sendable {
    private let conn: NWConnection
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var isClosed = false

    private init(_ conn: NWConnection, queue: DispatchQueue) {
        self.conn = conn
        self.queue = queue
    }

    public static func connect(host: String, port: UInt16, timeout: TimeInterval = 10) async throws -> TCPStream {
        guard let p = NWEndpoint.Port(rawValue: port) else { throw StreamError.closed }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        let conn = NWConnection(host: NWEndpoint.Host(host), port: p, using: params)
        let queue = DispatchQueue(label: "tcp.\(host).\(port)")
        let once = Once()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                conn.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        once.run { c.resume() }
                    case let .waiting(err), let .failed(err):
                        // .waiting means "refused, will retry later"; report it now.
                        once.run {
                            conn.cancel()
                            c.resume(throwing: TCPError.connect(host: host, port: port, reason: err.localizedDescription))
                        }
                    case .cancelled:
                        once.run { c.resume(throwing: CancellationError()) }
                    default:
                        break
                    }
                }
                conn.start(queue: queue)
                queue.asyncAfter(deadline: .now() + timeout) {
                    once.run {
                        conn.cancel()
                        c.resume(throwing: StreamError.timeout("connecting to \(host):\(port)"))
                    }
                }
            }
        } onCancel: {
            conn.cancel()
        }
        conn.stateUpdateHandler = nil
        return TCPStream(conn, queue: queue)
    }

    public func read() async throws -> [UInt8] {
        if lock.withLock({ isClosed }) { return [] }
        return try await withCheckedThrowingContinuation { c in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
                if let data, !data.isEmpty {
                    c.resume(returning: Array(data))
                } else if complete {
                    c.resume(returning: [])
                } else if let error {
                    // A local close cancels pending receives; treat that as end of stream.
                    if case .posix(.ECANCELED) = error { c.resume(returning: []) } else { c.resume(throwing: error) }
                } else {
                    c.resume(returning: [])
                }
            }
        }
    }

    public func write(_ bytes: [UInt8]) async throws {
        if lock.withLock({ isClosed }) { throw StreamError.closed }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            conn.send(content: Data(bytes), completion: .contentProcessed { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            })
        }
    }

    public func flush() async throws {}

    public func close() async {
        let first: Bool = lock.withLock {
            defer { isClosed = true }
            return !isClosed
        }
        if first { conn.cancel() }
    }
}

public enum TCPError: Error, LocalizedError {
    case connect(host: String, port: UInt16, reason: String)

    public var errorDescription: String? {
        switch self {
        case let .connect(host, port, reason): return "cannot connect to \(host):\(port): \(reason)"
        }
    }
}

final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ f: () -> Void) {
        let go: Bool = lock.withLock {
            defer { done = true }
            return !done
        }
        if go { f() }
    }
}
