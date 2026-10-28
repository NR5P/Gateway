import Foundation

/// Reads a ByteStream in the background so a caller can wait for a delimiter with a time limit
/// (a plain `read()` on a quiet radio link would wait forever).
final class Inbox: @unchecked Sendable {
    private let lock = NSLock()
    private var buf: [UInt8] = []
    private var failure: Error?
    private var waiter: CheckedContinuation<Void, Never>?
    private var reader: Task<Void, Never>?

    init(_ stream: ByteStream) {
        reader = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let bytes = try await stream.read()
                    guard let self else { return }
                    if bytes.isEmpty {
                        self.fail(StreamError.closed)
                        return
                    }
                    self.lock.withLock { self.buf += bytes }
                    self.wake()
                } catch {
                    self?.fail(error)
                    return
                }
            }
        }
    }

    deinit { reader?.cancel() }

    func cancel() {
        reader?.cancel()
        fail(StreamError.closed)
    }

    private func fail(_ e: Error) {
        lock.withLock { if failure == nil { failure = e } }
        wake()
    }

    private func wake() {
        let w: CheckedContinuation<Void, Never>? = lock.withLock {
            defer { waiter = nil }
            return waiter
        }
        w?.resume()
    }

    /// Bytes up to and including `delim`, arriving within `timeout` seconds.
    func take(until delim: UInt8, timeout: TimeInterval, what: String) async throws -> [UInt8] {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let got: [UInt8]? = try lock.withLock {
                if let i = buf.firstIndex(of: delim) {
                    defer { buf.removeFirst(i + 1) }
                    return Array(buf[...i])
                }
                if let failure { throw failure }
                return nil
            }
            if let got { return got }
            let left = deadline.timeIntervalSinceNow
            if left <= 0 { throw StreamError.timeout(what) }
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                let ready: Bool = lock.withLock {
                    if buf.contains(delim) || failure != nil { return true }
                    waiter = c
                    return false
                }
                if ready {
                    c.resume()
                } else {
                    Task { [weak self] in
                        try? await Task.sleep(for: .seconds(left))
                        self?.wake()
                    }
                }
            }
        }
    }

    func line(timeout: TimeInterval, what: String) async throws -> String {
        let bytes = try await take(until: 10, timeout: timeout, what: what)
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
