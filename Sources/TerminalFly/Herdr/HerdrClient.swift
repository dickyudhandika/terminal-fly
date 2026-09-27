import Foundation

/// Unix-socket client for herdr's API.
///
/// ## Connection model — verified against herdr 0.8.2, not assumed
///
/// herdr does **not** multiplex requests over a persistent connection. Measured
/// behaviour of the server socket:
///
///   * A plain request gets exactly one response and then the server **closes
///     the connection**. A second request on the same socket fails with a broken
///     pipe / EOF.
///   * `events.subscribe` is the exception: that connection stays open and
///     streams `{"event": ..., "data": ...}` frames, but it will not serve
///     further requests either.
///
/// So: **one connection per request**, plus one long-lived connection if the
/// caller subscribes. An earlier version of this file kept a single socket open
/// and correlated responses by id — which worked for exactly one call and then
/// silently reported "not connected" for every subsequent one. The `id` field is
/// still sent (the server requires it) but correlation is unnecessary.
final class HerdrClient {
    private let socketPath: String
    private let queue = DispatchQueue(label: "terminalfly.herdr", attributes: .concurrent)
    private var counter = 0
    private let counterLock = NSLock()

    /// Held open only while subscribed to events.
    private var subscriptionSource: DispatchSourceRead?
    private var subscriptionFD: Int32 = -1
    private var subscriptionBuffer = Data()

    /// Decoded server-pushed events, delivered on the main queue.
    var onEvent: (([String: Any]) -> Void)?

    init(socketPath: String = HerdrProtocol.defaultSocketPath) {
        self.socketPath = socketPath
    }

    deinit {
        unsubscribe()
    }

    // MARK: - Connection

    private func nextID() -> String {
        counterLock.lock()
        defer { counterLock.unlock() }
        counter += 1
        return "tf-\(counter)"
    }

    /// Opens a socket and connects. Throws `.unavailable` when herdr is simply
    /// not there — the one case that warrants silent fallback to the shell.
    private func openSocket() throws -> Int32 {
        // A stale socket file is a real failure mode: herdr crashed or was
        // force-quit and left the inode behind, so `connect` gets ECONNREFUSED.
        guard FileManager.default.fileExists(atPath: socketPath) else {
            throw HerdrError.unavailable("no socket at \(socketPath) — is herdr running?")
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HerdrError.unavailable("socket() failed") }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else {
            close(fd)
            throw HerdrError.unavailable("socket path too long")
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                for (index, byte) in pathBytes.enumerated() {
                    destination[index] = CChar(bitPattern: byte)
                }
                destination[pathBytes.count] = 0
            }
        }

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Foundation.connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            close(fd)
            throw HerdrError.unavailable("connect failed (errno \(code)) — stale socket?")
        }
        return fd
    }

    // MARK: - Requests (one connection each)

    /// Protocol conformance shim: `HerdrTransport` requires exactly this
    /// signature, and a defaulted `timeout:` parameter does not satisfy it.
    func call(_ method: HerdrProtocol.Method, params: [String: Any]) throws -> Any {
        try call(method, params: params, timeout: 10)
    }

    /// Sends a request on a fresh connection, reads the single response, closes.
    ///
    /// Blocking by design: the call is short (a local socket round-trip) and the
    /// one-shot semantics make a persistent async state machine pointless
    /// complexity. Callers that need it off the main thread should dispatch.
    func call(_ method: HerdrProtocol.Method,
              params: [String: Any] = [:],
              timeout: TimeInterval = 10) throws -> Any {
        let fd = try openSocket()
        defer { close(fd) }

        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let requestID = nextID()
        let payload = try HerdrProtocol.encode(id: requestID, method: method, params: params)
        try writeAll(fd, payload)

        // Read until we have one complete frame; herdr sends one response per
        // connection, so we stop as soon as the newline arrives.
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count > 0 {
                buffer.append(contentsOf: chunk[0..<count])
                let (frames, remainder) = HerdrProtocol.splitFrames(buffer)
                if let first = frames.first {
                    buffer = remainder
                    switch try HerdrProtocol.decode(first) {
                    case let .result(_, value): return value
                    case let .failure(_, error): throw error
                    case let .event(object): return object
                    }
                }
            } else if count == 0 {
                throw HerdrError.unavailable("herdr closed the connection before replying")
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                throw HerdrError.unavailable("timed out waiting for \(method.rawValue)")
            } else if errno != EINTR {
                throw HerdrError.unavailable("read failed (errno \(errno))")
            }
        }
    }

    private func writeAll(_ fd: Int32, _ data: Data) throws {
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.write(fd, base.advanced(by: offset), data.count - offset)
            }
            if written <= 0 {
                throw HerdrError.unavailable("write failed (errno \(errno))")
            }
            offset += written
        }
    }

    // MARK: - Events

    /// Subscribes to server-pushed events. The connection stays open; events are
    /// decoded and delivered via `onEvent` on the main queue.
    func subscribe(to eventTypes: [String]) throws {
        unsubscribe()
        let fd = try openSocket()
        subscriptionFD = fd
        subscriptionBuffer = Data()

        let payload = try HerdrProtocol.encode(id: nextID(),
                                               method: .eventsSubscribe,
                                               params: HerdrProtocol.subscribeParams(eventTypes))
        try writeAll(fd, payload)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readEventFrame() }
        source.setCancelHandler { [weak self] in
            guard let self, self.subscriptionFD >= 0 else { return }
            close(self.subscriptionFD)
            self.subscriptionFD = -1
        }
        subscriptionSource = source
        source.resume()
    }

    func unsubscribe() {
        subscriptionSource?.cancel()
        subscriptionSource = nil
        if subscriptionFD >= 0 {
            close(subscriptionFD)
            subscriptionFD = -1
        }
    }

    /// Tracks whether the `subscription_started` acknowledgement has been seen.
    private var sawSubscriptionAck = false

    private func readEventFrame() {
        guard subscriptionFD >= 0 else { return }
        var chunk = [UInt8](repeating: 0, count: 65536)
        let count = read(subscriptionFD, &chunk, chunk.count)

        if count > 0 {
            subscriptionBuffer.append(contentsOf: chunk[0..<count])
            let (frames, remainder) = HerdrProtocol.splitFrames(subscriptionBuffer)
            subscriptionBuffer = remainder
            for frame in frames where !frame.isEmpty {
                guard let object = try? JSONSerialization.jsonObject(with: frame) as? [String: Any] else {
                    continue
                }
                // The ack carries a result; real events carry "event"/"data".
                if object["result"] != nil { sawSubscriptionAck = true; continue }
                DispatchQueue.main.async { [weak self] in self?.onEvent?(object) }
            }
        } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
            // herdr went away — the UI must leave herdr mode rather than show a
            // frozen panel.
            let reason = count == 0 ? "herdr closed the event stream" : "read failed (errno \(errno))"
            unsubscribe()
            DispatchQueue.main.async { [weak self] in
                self?.onEvent?(["event": "herdr.disconnected", "reason": reason])
            }
        }
    }
}
