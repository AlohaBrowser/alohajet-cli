import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

// A loopback stand-in for the browser's automation server, in ~100 lines of POSIX
// sockets — the four routes `-p` drives, and a record of every request it received.
//
// The driver's own wire is already pinned hermetically (RemoteAutomationDriverTests,
// injected transport). What is NOT reachable that way is everything between argv and
// the driver: which AgentSession the flags resolved to, and which stream the CLI prints
// the conversation id on. Both are only observable from OUTSIDE the process, so the
// process needs something real to talk to.
//
// ponytail: one connection at a time, `Connection: close`, no keep-alive, no
// concurrency. `-p` is strictly serial — four requests, in order — which is all this
// has to serve.
nonisolated final class AgentStubServer: @unchecked Sendable {
    struct Request { let method: String, path: String, body: String, authorization: String? }

    /// The conversation this host is already on — what `/agent/lane` reports and what
    /// `--continue` therefore pins under protocol 2.
    static let lane = "11111111-1111-4111-8111-111111111111"
    /// What the host mints when the caller names no conversation.
    static let minted = "22222222-2222-4222-8222-222222222222"

    private var listenFD: Int32 = -1
    private let lock = NSLock()
    private var recorded: [Request] = []
    /// 1 answers `/agent/lane` 404 (the pre-v2 default arm) and serves the three-request
    /// handshake; 2 answers the probe and serves `/agent/run`.
    let protocolVersion: Int
    /// The conversation the host claims to have run in, instead of the one asked for —
    /// a host that ignores the request, which the driver must refuse rather than run in.
    let ranOverride: String?
    /// The final answer `/agent/result` reports.
    let finalText: String
    private(set) var port: Int = 0

    var url: String { "http://127.0.0.1:\(port)" }
    var requests: [Request] { lock.withLock { recorded } }
    func requests(path: String) -> [Request] { requests.filter { $0.path == path } }
    var paths: [String] { requests.map(\.path) }

    init(protocolVersion: Int = 1, finalText: String = "Four.", ranOverride: String? = nil) {
        self.protocolVersion = protocolVersion
        self.finalText = finalText
        self.ranOverride = ranOverride
    }

    func start() throws {
        listenFD = socket(AF_INET, SOCK_STREAM_VALUE, 0)
        guard listenFD >= 0 else { throw Failure.socket(errno) }
        var yes: Int32 = 1
        setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0                      // the kernel picks a free port
        address.sin_addr.s_addr = INADDR_LOOPBACK_BE
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(listenFD, 8) == 0 else { close(listenFD); throw Failure.bind(errno) }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listenFD, $0, &length) }
        }
        port = Int(UInt16(bigEndian: actual.sin_port))
        let thread = Thread { [weak self] in self?.serve() }
        thread.name = "alohajet.test.agent"
        thread.start()
    }

    func stop() {
        let fd = listenFD
        listenFD = -1
        if fd >= 0 { close(fd) }
    }

    private func serve() {
        while listenFD >= 0 {
            let client = accept(listenFD, nil, nil)
            if client < 0 { return }              // the listener closed: we are done
            if let request = read(client) {
                lock.withLock { recorded.append(request) }
                let (status, json) = answer(request)
                write(client, status: status, json: json)
            }
            close(client)
        }
    }

    /// Read one request: headers to the blank line, then exactly `Content-Length` more
    /// bytes. Reading a fixed 4K once would be right until the day a body lands in a
    /// second segment, which is the kind of flake nobody debugs twice.
    private func read(_ client: Int32) -> Request? {
        var raw = Data()
        var scratch = [UInt8](repeating: 0, count: 4096)
        func readMore() -> Bool {
            let got = recv(client, &scratch, scratch.count, 0)
            guard got > 0 else { return false }
            raw.append(contentsOf: scratch[0..<got])
            return true
        }
        let separator = Data("\r\n\r\n".utf8)
        while raw.range(of: separator) == nil { guard readMore() else { return nil } }
        let headEnd = raw.range(of: separator)!
        let head = String(decoding: raw[..<headEnd.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let start = lines.first?.components(separatedBy: " ") ?? []
        guard start.count >= 2 else { return nil }
        func header(_ name: String) -> String? {
            lines.dropFirst()
                .first { $0.lowercased().hasPrefix(name.lowercased() + ":") }
                .map { String($0.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces) }
        }
        let expected = header("Content-Length").flatMap(Int.init) ?? 0
        while raw[headEnd.upperBound...].count < expected { guard readMore() else { return nil } }
        let body = String(decoding: raw[headEnd.upperBound...].prefix(expected), as: UTF8.self)
        return Request(method: start[0],
                       path: URLComponents(string: start[1])?.path ?? start[1],
                       body: body,
                       authorization: header("Authorization"))
    }

    private func answer(_ request: Request) -> (status: Int, json: String) {
        /// The `conversation` / `sessionId` the caller asked for, if any.
        func requested(_ key: String) -> String? {
            (try? JSONSerialization.jsonObject(with: Data(request.body.utf8)))
                .flatMap { ($0 as? [String: Any])?[key] as? String }
        }
        switch (request.path, protocolVersion) {
        case ("/agent/lane", 2):
            return (200, #"{"protocol":2,"conversation":"\#(Self.lane)","known":true}"#)
        case ("/agent/lane", _):
            return (404, #"{"error":"not found","path":"/agent/lane"}"#)
        case ("/agent/run", 2):
            let ran = ranOverride ?? requested("conversation") ?? Self.minted
            return (200, #"{"ok":true,"taskId":"T-1","conversation":"\#(ran)","known":true}"#)
        case ("/agent/new", 1):
            let lane = ranOverride ?? requested("sessionId") ?? Self.minted
            return (200, #"{"ok":true,"sessionId":"\#(lane)"}"#)
        case ("/agent/permissions", 1):
            return (200, #"{"ok":true}"#)
        case ("/agent/task", 1):
            return (200, #"{"ok":true,"taskId":"T-1"}"#)
        case ("/agent/result", _):
            return (200, #"{"state":"done","result":{"finalText":\#(JSONSerialization.escaped(finalText)),"completion":"end_turn"}}"#)
        default:
            return (404, #"{"error":"not found"}"#)
        }
    }

    private func write(_ client: Int32, status: Int, json: String) {
        let body = Data(json.utf8)
        var head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Not Found")\r\nContent-Type: application/json\r\n"
        head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        let response = Data(head.utf8) + body
        response.withUnsafeBytes { buffer in
            var sent = 0
            while sent < buffer.count {
                let wrote = send(client, buffer.baseAddress!.advanced(by: sent), buffer.count - sent, 0)
                if wrote <= 0 { break }
                sent += wrote
            }
        }
    }

    enum Failure: Error { case socket(Int32), bind(Int32) }
}

extension JSONSerialization {
    /// One JSON string literal, quotes and escapes included.
    static func escaped(_ value: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [value])) ?? Data("[\"\"]".utf8)
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }
}

#if canImport(Glibc)
private nonisolated let SOCK_STREAM_VALUE = Int32(SOCK_STREAM.rawValue)
#else
private nonisolated let SOCK_STREAM_VALUE = SOCK_STREAM
#endif
/// 127.0.0.1 in network byte order.
private nonisolated let INADDR_LOOPBACK_BE: in_addr_t = (127 << 24 | 1).bigEndian
