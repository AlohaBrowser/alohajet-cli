#if os(Linux)
import Foundation
import Glibc

// A minimal pure-Swift RFC 6455 WebSocket client used as the CDP message channel
// on Linux. Foundation's `URLSessionWebSocketTask` is unusable there: it routes
// WebSocket I/O through libcurl, and the system libcurl on Ubuntu is built without
// the (experimental) WebSocket feature, so every frame fails with "WebSockets not
// supported by libcurl". CDP only needs a single, unencrypted `ws://` connection to
// a localhost debugger exchanging text frames, so this implements just that much
// directly over a POSIX socket, on a dedicated blocking reader thread.
//
// All mutable state is guarded by `stateLock`. Swift 6.2 forbids `NSLock.lock()/
// unlock()` inside async functions, so every critical section lives in a SYNCHRONOUS
// helper; the async protocol methods (open/send/receive/close) only call those.
final class LinuxWebSocketChannel: CDPMessageChannel, @unchecked Sendable {
    enum WSError: Error, CustomStringConvertible {
        case connectFailed(String)
        case handshakeFailed(String)
        case closed
        case badFrame(String)
        var description: String {
            switch self {
            case .connectFailed(let s): return "websocket connect failed: \(s)"
            case .handshakeFailed(let s): return "websocket handshake failed: \(s)"
            case .closed: return "websocket closed"
            case .badFrame(let s): return "websocket bad frame: \(s)"
            }
        }
    }

    private let url: URL

    private let stateLock = NSLock()
    private let writeLock = NSLock()
    private var fd: Int32 = -1
    private var closed = false
    private var failureError: Error?

    // Mailbox: buffered complete text messages + at most one suspended receiver.
    private var inbox: [String] = []
    private var pendingReceiver: CheckedContinuation<String, Error>?

    init(url: URL) { self.url = url }

    // MARK: - CDPMessageChannel (async; all locking delegated to sync helpers)

    func open() async {
        do {
            try connectAndHandshake()
            startReader()
        } catch {
            fail(error)
        }
    }

    func send(_ text: String) async throws {
        if let err = preflightError() { throw err }
        try writeAll(Self.encodeFrame(opcode: 0x1, payload: Array(text.utf8)))
    }

    func receive() async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            receiveOrEnqueue(cont)
        }
    }

    func close() async {
        guard let f = beginClose(), f >= 0 else { return }
        _ = try? writeAll(Self.encodeFrame(opcode: 0x8, payload: []))
        shutdown(f, Int32(SHUT_RDWR))
        _ = Glibc.close(f)
    }

    // MARK: - Synchronous critical sections

    private func preflightError() -> Error? {
        stateLock.lock(); defer { stateLock.unlock() }
        if let e = failureError { return e }
        if closed { return WSError.closed }
        return nil
    }

    private func receiveOrEnqueue(_ cont: CheckedContinuation<String, Error>) {
        stateLock.lock()
        if let err = failureError {
            stateLock.unlock(); cont.resume(throwing: err); return
        }
        if !inbox.isEmpty {
            let msg = inbox.removeFirst()
            stateLock.unlock(); cont.resume(returning: msg); return
        }
        if closed {
            stateLock.unlock(); cont.resume(throwing: WSError.closed); return
        }
        pendingReceiver = cont
        stateLock.unlock()
    }

    /// Marks the channel closed and HANDS OVER the fd to tear down, or nil if it was
    /// already closed. Resumes any pending receiver.
    ///
    /// `fd` is cleared as the descriptor is handed out, exactly as ``fail(_:)`` does, so
    /// only ONE path can ever close it. Leaving it set double-closed: the reader thread
    /// woke on our own shutdown, called `fail(_:)`, and closed a number the kernel had
    /// already recycled — surfacing as EBADF in an unrelated socket.
    private func beginClose() -> Int32? {
        stateLock.lock()
        if closed { stateLock.unlock(); return nil }
        closed = true
        let f = fd
        fd = -1
        let waiter = pendingReceiver; pendingReceiver = nil
        stateLock.unlock()
        waiter?.resume(throwing: WSError.closed)
        return f
    }

    private func setFD(_ s: Int32) { stateLock.lock(); fd = s; stateLock.unlock() }
    private func currentFD() -> Int32 { stateLock.lock(); defer { stateLock.unlock() }; return fd }

    private func deliver(_ msg: String) {
        stateLock.lock()
        if let r = pendingReceiver {
            pendingReceiver = nil
            stateLock.unlock()
            r.resume(returning: msg)
        } else {
            inbox.append(msg)
            stateLock.unlock()
        }
    }

    private func fail(_ error: Error) {
        stateLock.lock()
        if failureError == nil { failureError = error }
        closed = true
        let f = fd; fd = -1
        let r = pendingReceiver; pendingReceiver = nil
        stateLock.unlock()
        // Tear the socket down here: `closed` is now set, so a later close() call
        // no-ops via beginClose() and would otherwise leak the descriptor.
        if f >= 0 { _ = Glibc.close(f) }
        r?.resume(throwing: error)
    }

    // MARK: - Connection + handshake

    private func connectAndHandshake() throws {
        let host = url.host ?? "127.0.0.1"
        let port = url.port ?? 80
        var path = url.path.isEmpty ? "/" : url.path
        if let q = url.query, !q.isEmpty { path += "?" + q }

        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        var info: UnsafeMutablePointer<addrinfo>?
        let gai = getaddrinfo(host, String(port), &hints, &info)
        guard gai == 0, let addr = info else {
            throw WSError.connectFailed("getaddrinfo(\(host):\(port)) rc=\(gai)")
        }
        defer { freeaddrinfo(info) }

        let s = socket(addr.pointee.ai_family, addr.pointee.ai_socktype, addr.pointee.ai_protocol)
        guard s >= 0 else { throw WSError.connectFailed("socket() errno \(errno)") }
        guard connect(s, addr.pointee.ai_addr, addr.pointee.ai_addrlen) == 0 else {
            let e = errno; _ = Glibc.close(s)
            throw WSError.connectFailed("connect() errno \(e)")
        }
        setFD(s)

        var keyBytes = [UInt8](repeating: 0, count: 16)
        for i in keyBytes.indices { keyBytes[i] = UInt8.random(in: 0...255) }
        let key = Data(keyBytes).base64EncodedString()
        let req = """
        GET \(path) HTTP/1.1\r
        Host: \(host):\(port)\r
        Upgrade: websocket\r
        Connection: Upgrade\r
        Sec-WebSocket-Key: \(key)\r
        Sec-WebSocket-Version: 13\r
        \r

        """
        try writeAll(Array(req.utf8))

        var buf = [UInt8]()
        let terminator: [UInt8] = [0x0d, 0x0a, 0x0d, 0x0a]
        while !buf.suffix(4).elementsEqual(terminator) {
            buf.append(try readByte(s))
            if buf.count > 16384 { throw WSError.handshakeFailed("response headers too large") }
        }
        let header = String(decoding: buf, as: UTF8.self)
        guard header.contains(" 101 ") else {
            throw WSError.handshakeFailed("no 101 in: \(header.prefix(120))")
        }
    }

    // MARK: - Reader thread

    private func startReader() {
        let t = Thread { [weak self] in self?.readLoop() }
        t.stackSize = 4 << 20
        t.start()
    }

    private func readLoop() {
        let s = currentFD()
        guard s >= 0 else { return }
        var assembled = [UInt8]()
        do {
            while true {
                let (fin, opcode, payload) = try readFrame(s)
                switch opcode {
                case 0x0: // continuation
                    assembled.append(contentsOf: payload)
                    if fin { deliver(String(decoding: assembled, as: UTF8.self)); assembled = [] }
                case 0x1, 0x2: // text / binary
                    if fin {
                        deliver(String(decoding: payload, as: UTF8.self))
                    } else {
                        assembled = payload
                    }
                case 0x8: // close
                    throw WSError.closed
                case 0x9: // ping -> pong
                    try writeAll(Self.encodeFrame(opcode: 0xA, payload: payload))
                case 0xA: // pong -> ignore
                    break
                default:
                    throw WSError.badFrame("opcode \(opcode)")
                }
            }
        } catch {
            fail(error)
        }
    }

    private func readFrame(_ s: Int32) throws -> (fin: Bool, opcode: UInt8, payload: [UInt8]) {
        let b0 = try readByte(s)
        let b1 = try readByte(s)
        let fin = (b0 & 0x80) != 0
        let opcode = b0 & 0x0F
        let masked = (b1 & 0x80) != 0
        var len = UInt64(b1 & 0x7F)
        if len == 126 {
            let hi = try readByte(s); let lo = try readByte(s)
            len = (UInt64(hi) << 8) | UInt64(lo)
        } else if len == 127 {
            var v: UInt64 = 0
            for _ in 0..<8 { v = (v << 8) | UInt64(try readByte(s)) }
            len = v
        }
        var maskKey = [UInt8](repeating: 0, count: 4)
        if masked { for i in 0..<4 { maskKey[i] = try readByte(s) } }
        var payload = try readExactly(s, Int(len))
        if masked { for i in payload.indices { payload[i] ^= maskKey[i % 4] } }
        return (fin, opcode, payload)
    }

    // MARK: - Socket I/O helpers (synchronous)

    private func readByte(_ s: Int32) throws -> UInt8 {
        var b: UInt8 = 0
        try withUnsafeMutablePointer(to: &b) { try readFull(s, $0, 1) }
        return b
    }

    private func readExactly(_ s: Int32, _ n: Int) throws -> [UInt8] {
        if n == 0 { return [] }
        var buf = [UInt8](repeating: 0, count: n)
        try buf.withUnsafeMutableBytes { try readFull(s, $0.baseAddress!, n) }
        return buf
    }

    private func readFull(_ s: Int32, _ base: UnsafeMutableRawPointer, _ n: Int) throws {
        var got = 0
        while got < n {
            let r = recv(s, base.advanced(by: got), n - got, 0)
            if r > 0 { got += r; continue }
            if r == 0 { throw WSError.closed }
            if errno == EINTR { continue }
            throw WSError.connectFailed("recv errno \(errno)")
        }
    }

    @discardableResult
    private func writeAll(_ bytes: [UInt8]) throws -> Int {
        writeLock.lock(); defer { writeLock.unlock() }
        let s = currentFD()
        guard s >= 0 else { throw WSError.closed }
        var sent = 0
        try bytes.withUnsafeBytes { raw in
            let base = raw.baseAddress!
            while sent < bytes.count {
                let w = Glibc.send(s, base.advanced(by: sent), bytes.count - sent, Int32(MSG_NOSIGNAL))
                if w > 0 { sent += w; continue }
                if w < 0 && errno == EINTR { continue }
                throw WSError.connectFailed("send errno \(errno)")
            }
        }
        return sent
    }

    // MARK: - Frame encoding (client frames are always masked)

    static func encodeFrame(opcode: UInt8, payload: [UInt8]) -> [UInt8] {
        var frame = [UInt8]()
        frame.append(0x80 | (opcode & 0x0F))
        let n = payload.count
        if n < 126 {
            frame.append(0x80 | UInt8(n))
        } else if n < 65536 {
            frame.append(0x80 | 126)
            frame.append(UInt8((n >> 8) & 0xFF)); frame.append(UInt8(n & 0xFF))
        } else {
            frame.append(0x80 | 127)
            var v = UInt64(n); var bytes = [UInt8](repeating: 0, count: 8)
            for i in (0..<8).reversed() { bytes[i] = UInt8(v & 0xFF); v >>= 8 }
            frame.append(contentsOf: bytes)
        }
        var mask = [UInt8](repeating: 0, count: 4)
        for i in 0..<4 { mask[i] = UInt8.random(in: 0...255) }
        frame.append(contentsOf: mask)
        var masked = payload
        for i in masked.indices { masked[i] ^= mask[i % 4] }
        frame.append(contentsOf: masked)
        return frame
    }
}
#endif
