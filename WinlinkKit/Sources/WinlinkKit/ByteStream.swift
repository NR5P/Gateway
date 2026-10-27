import Foundation

/// A reliable, ordered byte connection: a TCP socket, a VARA ARQ link, a test pipe.
public protocol ByteStream: AnyObject, Sendable {
    /// The next chunk of bytes; an empty array means the remote closed the stream.
    func read() async throws -> [UInt8]
    func write(_ bytes: [UInt8]) async throws
    /// Returns once everything written has left this station (for VARA: the modem's TX buffer is empty).
    func flush() async throws
    func close() async
}

public extension ByteStream {
    func write(_ s: String) async throws { try await write(Array(s.utf8)) }
}

public enum StreamError: Error, Equatable, LocalizedError {
    case closed
    case timeout(String)

    public var errorDescription: String? {
        switch self {
        case .closed: return "connection lost"
        case let .timeout(what): return "timed out \(what)"
        }
    }
}

/// Buffered reading on top of a ByteStream.
final class StreamReader {
    let stream: ByteStream
    private var buf: [UInt8] = []
    private var pos = 0

    init(_ stream: ByteStream, prefix: [UInt8] = []) {
        self.stream = stream
        buf = prefix
    }

    private func fill() async throws {
        let more = try await stream.read()
        if more.isEmpty { throw StreamError.closed }
        if pos > 0 {
            buf.removeFirst(pos)
            pos = 0
        }
        buf += more
    }

    func peek() async throws -> UInt8 {
        while pos >= buf.count { try await fill() }
        return buf[pos]
    }

    func readByte() async throws -> UInt8 {
        let b = try await peek()
        pos += 1
        return b
    }

    /// Bytes up to and including `delim`.
    func read(until delim: UInt8) async throws -> [UInt8] {
        var from = pos
        while true {
            if let i = buf[from...].firstIndex(of: delim) {
                let out = Array(buf[pos...i])
                pos = i + 1
                return out
            }
            from = buf.count
            let off = from - pos
            try await fill()
            from = pos + off
        }
    }

    func read(count: Int) async throws -> [UInt8] {
        while buf.count - pos < count { try await fill() }
        let out = Array(buf[pos..<(pos + count)])
        pos += count
        return out
    }

    /// Whatever is buffered but not yet consumed.
    func drain() -> [UInt8] {
        let out = Array(buf[pos...])
        pos = buf.count
        return out
    }
}

/// A ByteStream that first replays `prefix`, then reads from `inner`.
final class PrefixedStream: ByteStream, @unchecked Sendable {
    private let inner: ByteStream
    private var prefix: [UInt8]
    private let lock = NSLock()

    init(_ inner: ByteStream, prefix: [UInt8]) {
        self.inner = inner
        self.prefix = prefix
    }

    func read() async throws -> [UInt8] {
        let p: [UInt8] = lock.withLock {
            defer { prefix = [] }
            return prefix
        }
        if !p.isEmpty { return p }
        return try await inner.read()
    }

    func write(_ bytes: [UInt8]) async throws { try await inner.write(bytes) }
    func flush() async throws { try await inner.flush() }
    func close() async { await inner.close() }
}

/// An in-memory duplex pipe, for tests and loopback sessions.
public final class PipeStream: ByteStream, @unchecked Sendable {
    private let lock = NSLock()
    private var inbox: [[UInt8]] = []
    private var waiter: CheckedContinuation<[UInt8], Error>?
    private var closed = false
    public private(set) weak var peer: PipeStream?

    public static func pair() -> (PipeStream, PipeStream) {
        let a = PipeStream(), b = PipeStream()
        a.peer = b
        b.peer = a
        // Keep both ends alive as long as either is.
        a.strongPeer = b
        return (a, b)
    }

    private var strongPeer: PipeStream?

    func deliver(_ bytes: [UInt8]) {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        if let w = waiter {
            waiter = nil
            lock.unlock()
            w.resume(returning: bytes)
        } else {
            inbox.append(bytes)
            lock.unlock()
        }
    }

    func hangup() {
        lock.lock()
        closed = true
        let w = waiter
        waiter = nil
        lock.unlock()
        w?.resume(returning: [])
    }

    public func read() async throws -> [UInt8] {
        try await withCheckedThrowingContinuation { c in
            lock.lock()
            if !inbox.isEmpty {
                let b = inbox.removeFirst()
                lock.unlock()
                c.resume(returning: b)
            } else if closed {
                lock.unlock()
                c.resume(returning: [])
            } else {
                waiter = c
                lock.unlock()
            }
        }
    }

    public func write(_ bytes: [UInt8]) async throws {
        let isClosed = lock.withLock { closed }
        guard !isClosed, let p = peer else { throw StreamError.closed }
        p.deliver(bytes)
    }

    public func flush() async throws {}

    public func close() async {
        hangup()
        peer?.hangup()
    }
}
