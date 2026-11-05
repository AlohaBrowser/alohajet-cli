import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

// A loopback stand-in for the browser's `POST /mcp` that answers the way it does while a tool
// call is waiting on something: concurrently. Every connection gets its own thread, so a
// `tools/call` can be held open while a ping, a cancel or another call is answered next to it.
// `AgentStubServer` serves one connection at a time, which is exactly what this cannot.
//
// What it answers: `initialize` (with the session id, after an optional delay), `ping` and
// `tools/list` at once, every notification 202. A `tools/call` is held until the test releases
// it, a `notifications/cancelled` names it, `autoRelease` passes, or `maxHold` runs out; an id in
// `failing` gets a 500 instead. Every POST is recorded with when it arrived.
nonisolated final class MCPHoldingStub: @unchecked Sendable {
    struct Post {
        let at: Date
        let method: String?
        let id: Int?
        let session: String?
        /// For a `notifications/cancelled`: the id it names, and why.
        let cancels: Int?
        let reason: String?
    }

    private let initializeDelay: TimeInterval
    private let autoRelease: TimeInterval?
    private let failing: Set<Int>
    private let maxHold: TimeInterval
    private let condition = NSCondition()
    private var recorded: [Post] = []
    private var held: Set<Int> = []
    private var released: [Int: String] = [:]
    private var initializeAnsweredAt: Date?
    private var listenFD: Int32 = -1
    private var stopped = false
    private(set) var port = 0

    var url: String { "http://127.0.0.1:\(port)" }

    init(initializeDelay: TimeInterval = 0, autoRelease: TimeInterval? = nil,
         failing: Set<Int> = [], maxHold: TimeInterval = 120) {
        self.initializeDelay = initializeDelay
        self.autoRelease = autoRelease
        self.failing = failing
        self.maxHold = maxHold
    }

    func start() throws {
        (listenFD, port) = try StubHTTP.listener(port: 0)
        let fd = listenFD
        let thread = Thread { [self] in
            defer { close(fd) }
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { return }
                if condition.withLock({ stopped }) { close(client); return }
                let connection = Thread { [self] in
                    serve(client)
                    close(client)
                }
                connection.name = "alohajet.test.mcp-connection"
                connection.start()
            }
        }
        thread.name = "alohajet.test.mcp"
        thread.start()
    }

    /// Lets every held call go and ends the accept loop, so no thread outlives the test. The loop
    /// is woken by a connection rather than by closing its descriptor: a close does not wake
    /// `accept` on Darwin, and the thread owns closing the listener.
    func stop() {
        let alreadyStopped = condition.withLock {
            defer { stopped = true; condition.broadcast() }
            return stopped
        }
        guard !alreadyStopped, listenFD >= 0 else { return }
        let knock = socket(AF_INET, SOCK_STREAM_VALUE, 0)
        guard knock >= 0 else { return }
        defer { close(knock) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = INADDR_LOOPBACK_BE
        _ = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(knock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }

    var posts: [Post] { condition.withLock { recorded } }
    var cancels: [Post] { posts.filter { $0.method == "notifications/cancelled" } }
    var initializeAnswered: Date? { condition.withLock { initializeAnsweredAt } }
    func isHeld(_ id: Int) -> Bool { condition.withLock { held.contains(id) } }

    func release(_ id: Int) {
        condition.withLock {
            released[id] = "released"
            condition.broadcast()
        }
    }

    /// Polls `predicate` until it holds or `seconds` pass.
    func wait(within seconds: TimeInterval, until predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !predicate() {
            if Date() >= deadline { return false }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return true
    }

    private func serve(_ client: Int32) {
        guard let request = StubHTTP.read(client) else { return }
        let frame = (try? JSONSerialization.jsonObject(with: Data(request.body.utf8))) as? [String: Any]
        let method = frame?["method"] as? String
        let id = frame?["id"] as? Int
        let params = frame?["params"] as? [String: Any]
        let cancels = method == "notifications/cancelled" ? params?["requestId"] as? Int : nil
        condition.withLock {
            recorded.append(Post(at: Date(), method: method, id: id, session: request.mcpSession,
                                 cancels: cancels, reason: params?["reason"] as? String))
            if let cancels, held.contains(cancels) {
                released[cancels] = "cancelled"
                condition.broadcast()
            }
        }
        guard let method, let id else {
            StubHTTP.write(client, status: 202, json: "", mcp: true)
            return
        }
        switch method {
        case "initialize":
            if initializeDelay > 0 { Thread.sleep(forTimeInterval: initializeDelay) }
            condition.withLock { initializeAnsweredAt = Date() }
            answer(client, id, #"{"protocolVersion":"2025-06-18","capabilities":{"tools":{}},"serverInfo":{"name":"holding-fixture","version":"1"}}"#)
        case "tools/call" where failing.contains(id):
            StubHTTP.write(client, status: 500, json: #"{"error":"fixture failure"}"#, mcp: true)
        case "tools/call":
            let outcome = hold(id)
            answer(client, id, #"{"content":[{"type":"text","text":"\#(outcome)"}],"isError":false}"#)
        case "tools/list":
            answer(client, id, #"{"tools":[]}"#)
        default:
            answer(client, id, "{}")
        }
    }

    private func hold(_ id: Int) -> String {
        condition.withLock {
            held.insert(id)
            defer { held.remove(id) }
            let deadline = Date().addingTimeInterval(autoRelease ?? maxHold)
            while released[id] == nil, !stopped {
                if !condition.wait(until: deadline) { return autoRelease == nil ? "held too long" : "released" }
            }
            return released[id] ?? "stopped"
        }
    }

    private func answer(_ client: Int32, _ id: Int, _ result: String) {
        StubHTTP.write(client, status: 200, json: #"{"jsonrpc":"2.0","id":\#(id),"result":\#(result)}"#, mcp: true)
    }
}
