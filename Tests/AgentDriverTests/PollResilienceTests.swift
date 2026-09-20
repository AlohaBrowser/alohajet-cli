import Testing
import Foundation
@testable import AgentDriver

// MARK: - A poll that fails is not the turn failing
//
// `/agent/result` is a liveness poll against an endpoint served on the app's main
// thread, so on a loaded machine one GET can miss its deadline while the turn itself is
// running normally. Ending the turn on that — with 2399 polls of budget left, and
// without the id needed to rejoin it — throws away work that completed.

private struct PollTimeout: Error, CustomStringConvertible {
    var description: String { "The request timed out." }
}

/// Throws on the first `count` polls; a negative count throws on every one.
private nonisolated final class FailingPolls: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    private var count = 0

    init(_ remaining: Int) { self.remaining = remaining }

    var thrown: Int { lock.withLock { count } }

    func shouldThrow() -> Bool {
        lock.withLock {
            guard remaining != 0 else { return false }
            if remaining > 0 { remaining -= 1 }
            count += 1
            return true
        }
    }
}

private func makeFlakyDriver(
    stub: ProtocolStub, polls: FailingPolls, session: AgentSession = .fresh
) -> RemoteAutomationDriver {
    RemoteAutomationDriver(
        endpoint: URL(string: "http://127.0.0.1:65535")!,
        session: session,
        transport: { method, url, body in
            if url.path.hasSuffix("/agent/result"), polls.shouldThrow() { throw PollTimeout() }
            return await stub.handle(method: method, path: url.path,
                                     body: body.map { String(decoding: $0, as: UTF8.self) } ?? "")
        },
        pollInterval: .milliseconds(1),
        maxPollAttempts: 200)
}

private let terminal = { try! remoteResultEnvelope(state: "done", result: remoteSuccessFixture) }()

@Suite("poll resilience")
struct PollResilienceTests {

    @Test("a poll that fails is retried, and the turn reaches its terminal result")
    func aFailedPollIsRetried() async throws {
        let polls = FailingPolls(2)
        let stub = ProtocolStub(lane: ProtocolStub.laneV2(), results: [terminal])

        let result = try await makeFlakyDriver(stub: stub, polls: polls).runTask(prompt: "hi")

        #expect(result == remoteSuccessFixture)
        #expect(polls.thrown == 2)
    }

    @Test("a browser that stops answering gives up on a bound, and says so")
    func givingUpIsBoundedAndReadable() async throws {
        let polls = FailingPolls(-1)
        let stub = ProtocolStub(lane: ProtocolStub.laneV2(), results: [terminal])

        let result = try await makeFlakyDriver(stub: stub, polls: polls).runTask(prompt: "hi")

        #expect(!result.isSuccess)
        let reason = try #require(result.failureReason)
        #expect(reason.contains("stopped answering"), "\(reason)")
        #expect(polls.thrown == RemoteAutomationDriver.maxConsecutivePollFailures)
    }

    @Test("a turn that fails while polling still reports the conversation it ran in")
    func aFailedTurnCarriesItsConversation() async throws {
        let polls = FailingPolls(-1)
        let stub = ProtocolStub(lane: ProtocolStub.laneV2(), results: [terminal])

        let (result, sessionId) = await makeFlakyDriver(stub: stub, polls: polls).runTurn(prompt: "hi")

        #expect(!result.isSuccess)
        #expect(sessionId == "BBBBBBBB-0000-4000-8000-00000000BBBB")
    }
}
