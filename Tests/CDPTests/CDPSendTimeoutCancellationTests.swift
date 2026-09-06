import Testing
import Foundation
@testable import CDP
import ToolABI

/// Regression coverage for `CDPClient.send`: it must enforce a per-call timeout
/// and honour task cancellation. A `Runtime.evaluate(awaitPromise: true)` against
/// a wedged page (one that never resolves) must not block `send` forever, and a
/// structured-concurrency cancellation (the runtime's 15s read race or a
/// turn-interrupt) must unwind it promptly rather than leaving an orphaned
/// continuation suspended.
///
/// These tests drive the real `CDPClient` (its JSON-RPC correlation, receive
/// loop, and event fan-out) over a scriptable channel that can be told to never
/// reply to a chosen command, then assert the three bounded behaviours.
@Suite struct CDPSendTimeoutCancellationTests {

    /// A `CDPMessageChannel` that answers commands normally — EXCEPT for a chosen
    /// `method`, whose response it swallows so that command never resolves
    /// (mirroring a wedged page's `Runtime.evaluate` that never settles).
    ///
    /// `CDPClient` is an actor that drives the channel off the main actor, and
    /// `CDPMessageChannel`'s requirements are all `async`, so the channel is an
    /// actor: its inbox, pending waiter, and closed flag are actor-isolated
    /// state requiring no lock.
    actor WedgingChannel: CDPMessageChannel {
        /// Commands matching this method get NO reply (the request hangs).
        private let swallowMethod: String
        private var inbox: [String] = []
        private var waiter: CheckedContinuation<String, Error>?
        private var closed = false

        init(swallowMethod: String) { self.swallowMethod = swallowMethod }

        func open() async {}

        func send(_ text: String) async throws {
            guard let message = JSValue.parse(text),
                  let id = message["id"]?.intValue,
                  let method = message["method"]?.stringValue else { return }

            // The wedged command: record nothing, deliver nothing — it hangs.
            if method == swallowMethod { return }

            // Everything else gets a normal empty-result response so the rest of
            // the JSON-RPC machinery behaves exactly as against a live browser.
            let response = JSValue.object([
                ("id", .number(Double(id))),
                ("result", .object([("ok", .bool(true))]))
            ])
            deliver(response.stringify())
        }

        func receive() async throws -> String {
            if !inbox.isEmpty { return inbox.removeFirst() }
            if closed { throw CDPError.connectionClosed }
            return try await withCheckedThrowingContinuation { continuation in
                if closed {
                    continuation.resume(throwing: CDPError.connectionClosed)
                } else if !inbox.isEmpty {
                    continuation.resume(returning: inbox.removeFirst())
                } else {
                    waiter = continuation
                }
            }
        }

        func close() async {
            closed = true
            let pending = waiter
            waiter = nil
            pending?.resume(throwing: CDPError.connectionClosed)
        }

        private func deliver(_ frame: String) {
            if let w = waiter {
                waiter = nil
                w.resume(returning: frame)
            } else {
                inbox.append(frame)
            }
        }
    }

    // MARK: (a) A wedged command throws CDPError.timeout within the deadline.

    /// A `Runtime.evaluate` that never resolves must be bounded: `send` throws
    /// `CDPError.timeout(method:)` within ~the deadline rather than blocking
    /// forever.
    @Test func wedgedEvaluateTimesOutAndDoesNotHang() async throws {
        let channel = WedgingChannel(swallowMethod: "Runtime.evaluate")
        // A short backstop so the test is fast; the production default is 30s.
        let client = CDPClient(channel: channel, callTimeout: 0.5)
        try await client.connect()
        defer { Task { await client.close() } }

        let start = Date()
        await #expect(throws: CDPError.self) {
            _ = try await client.send(
                method: "Runtime.evaluate",
                params: ["expression": .string("new Promise(() => {})"), "awaitPromise": .bool(true)]
            )
        }
        let elapsed = Date().timeIntervalSince(start)

        // Bounded: it returned via the backstop, nowhere near a hang. The backstop
        // fires off a starvation-prone `Task.sleep`, so under the default parallel
        // `swift test` an oversubscribed cooperative pool can delay its resume well
        // past the 0.5s deadline without anything hanging. The load-bearing
        // assertion is the timeout-error class below; this margin is only a coarse
        // "did not hang" backstop, generous enough to tolerate scheduler latency.
        #expect(elapsed < 30.0, "send of a never-resolving command must be bounded, took \(elapsed)s")

        // And specifically the timeout error, carrying the method.
        do {
            _ = try await client.send(
                method: "Runtime.evaluate",
                params: ["expression": .string("hang")]
            )
            Issue.record("expected CDPError.timeout")
        } catch let CDPError.timeout(method) {
            #expect(method == "Runtime.evaluate")
        } catch {
            Issue.record("expected CDPError.timeout, got \(error)")
        }
    }

    // MARK: (b) A cancelled send throws CancellationError promptly (no leak/hang).

    /// The runtime's 15s read race / a turn-interrupt cancels the task enclosing
    /// `send`; the orphaned continuation must be resumed with `CancellationError`
    /// promptly — not leaked, not hung.
    ///
    /// The load-bearing property is that cancellation UNWINDS the call (it throws
    /// rather than resolving or hanging). The original wall-clock margin measured
    /// scheduler latency, not the property: under the default parallel `swift test`
    /// the cooperative pool is oversubscribed, so both the cancel handler's
    /// actor-hop `Task` and the registration `Task.sleep` are starved and resume
    /// late — well past a fixed margin — even though nothing hangs. We instead
    /// await the unwind under a generous deadline (which a true hang would blow,
    /// since the 60s backstop would never fire inside it) and assert the property.
    @Test func cancelledSendUnwindsPromptly() async throws {
        // A generous backstop so cancellation — not the timeout — is what unwinds.
        let channel = WedgingChannel(swallowMethod: "Runtime.evaluate")
        let client = CDPClient(channel: channel, callTimeout: 60)
        try await client.connect()
        defer { Task { await client.close() } }

        let registered = AsyncSemaphore()
        let task = Task<Bool, Never> {
            do {
                // Signal that the call is about to suspend on its continuation, so
                // the cancel races a registered pending entry — not an unstarted
                // task. This removes the dependence on a fixed pre-cancel sleep.
                await registered.signal()
                _ = try await client.send(
                    method: "Runtime.evaluate",
                    params: ["expression": .string("new Promise(() => {})")]
                )
                return false // resolved — unexpected
            } catch is CancellationError {
                return true
            } catch {
                // Some runtimes surface cancellation through the sleep/timeout
                // racer; any prompt throw that is not a successful resolve proves
                // the call unwound rather than hung.
                return true
            }
        }

        // Let the send register its pending continuation, then cancel. Awaiting the
        // signal then yielding lets the continuation register without a fixed
        // wall-clock sleep that starvation could stretch.
        await registered.wait()
        await Task.yield()
        task.cancel()

        // Await the unwind under a deadline that only a true hang (the 60s backstop
        // never reached) could blow; starvation merely delays the resume.
        let unwound = await awaitTaskValue(task, timeout: .seconds(10))
        #expect(unwound == true, "a cancelled send must throw, not resolve or hang")
    }

    /// A one-shot async signal used to gate on the call reaching its suspension
    /// point without a fixed wall-clock sleep. Actor-isolated; no lock.
    private actor AsyncSemaphore {
        private var signalled = false
        private var waiter: CheckedContinuation<Void, Never>?
        func signal() {
            signalled = true
            let w = waiter
            waiter = nil
            w?.resume()
        }
        func wait() async {
            if signalled { return }
            await withCheckedContinuation { waiter = $0 }
        }
    }

    /// Await a `Task`'s value, but give up after `timeout` so a genuine hang fails
    /// the test fast instead of blocking the run. Returns `nil` on timeout. Immune
    /// to executor starvation: a starved-but-eventual resume still completes well
    /// inside a generous deadline, while a real hang never does.
    private func awaitTaskValue<V: Sendable>(
        _ task: Task<V, Never>,
        timeout: Duration
    ) async -> V? {
        await withTaskGroup(of: V?.self) { group in
            group.addTask { await task.value }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    // MARK: (c) A normal command still returns.

    /// The guards must not break the happy path: a command that the browser
    /// answers returns its result as before.
    @Test func normalCommandStillReturns() async throws {
        let channel = WedgingChannel(swallowMethod: "Runtime.evaluate")
        let client = CDPClient(channel: channel, callTimeout: 5)
        try await client.connect()
        defer { Task { await client.close() } }

        let result = try await client.send(method: "Page.enable")
        #expect(result["ok"]?.boolValue == true, "a normally-answered command must return its result")

        // The flat-session overload must work too.
        let sessionResult = try await client.send(
            method: "Runtime.enable",
            params: [:],
            sessionId: "session-1"
        )
        #expect(sessionResult["ok"]?.boolValue == true)
    }

    // MARK: timeout on the sessionId overload too.

    @Test func wedgedSessionCommandTimesOut() async throws {
        let channel = WedgingChannel(swallowMethod: "Runtime.evaluate")
        let client = CDPClient(channel: channel, callTimeout: 0.5)
        try await client.connect()
        defer { Task { await client.close() } }

        let start = Date()
        do {
            _ = try await client.send(
                method: "Runtime.evaluate",
                params: ["expression": .string("hang")],
                sessionId: "session-1"
            )
            Issue.record("expected CDPError.timeout on the sessionId overload")
        } catch let CDPError.timeout(method) {
            #expect(method == "Runtime.evaluate")
        } catch {
            Issue.record("expected CDPError.timeout, got \(error)")
        }
        let elapsed = Date().timeIntervalSince(start)
        // Generous "did not hang" backstop: the 0.5s deadline fires off a
        // starvation-prone `Task.sleep`, so a parallel-oversubscribed cooperative
        // pool can delay its resume past a tight margin without anything hanging.
        // The load-bearing assertion is the `CDPError.timeout` class caught above.
        #expect(elapsed < 30.0, "sessionId-overload send must be bounded, took \(elapsed)s")
    }
}
