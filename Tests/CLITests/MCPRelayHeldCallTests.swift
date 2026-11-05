import Foundation
import Testing

// The relay while a tool call is held open. The browser holds a `tools/call` POST for as long as
// the call runs, which is minutes when it waits on the person at the browser, and it answers
// everything else on the same session at once. A relay that forwards one frame at a time turns
// that into a queue: a ping, a cancel or a second call waits behind the held call. Measured: a
// ping waited 20 s behind a held call through the relay, and was answered in 1 s sent straight
// to the browser.
//
// The assertions are the stub's state (a call still held, a cancel recorded), not elapsed time,
// so a slow machine fails none of them; the deadlines only bound a regression.
@Suite("MCP relay while a call is held", .serialized)
struct MCPRelayHeldCallTests {

    /// A relay to `stub`, past the handshake.
    private func relay(to stub: MCPHoldingStub) throws -> RelaySession {
        try stub.start()
        let relay = try RelaySession(endpoint: stub.url)
        relay.initialize()
        if relay.reply(0, within: 15) == nil {
            relay.finish()
            Issue.record("no answer to initialize: \(relay.stderr)")
            throw HandshakeFailed()
        }
        return relay
    }

    private struct HandshakeFailed: Error {}

    @Test func aPingIsAnsweredWhileAToolCallIsStillHeld() throws {
        let stub = MCPHoldingStub(maxHold: 15)
        defer { stub.stop() }
        let relay = try relay(to: stub)
        defer { relay.finish() }

        relay.callTool(2)
        try #require(stub.wait(within: 10) { stub.isHeld(2) }, "the call never reached the browser")
        relay.ping(3)
        #expect(relay.reply(3, within: 5) != nil, "the ping waited behind the held call")
        #expect(stub.isHeld(2))

        stub.release(2)
        #expect(relay.reply(2, within: 15) != nil)
        relay.closeInput()
        #expect(relay.exitStatus(within: 10) == 0, "\(relay.stderr)")
    }

    @Test func aClientsCancellationReachesTheBrowserWhileItsCallIsHeld() throws {
        let stub = MCPHoldingStub(maxHold: 15)
        defer { stub.stop() }
        let relay = try relay(to: stub)
        defer { relay.finish() }

        relay.callTool(2)
        try #require(stub.wait(within: 10) { stub.isHeld(2) }, "the call never reached the browser")
        relay.cancel(2)
        #expect(stub.wait(within: 5) { !stub.cancels.isEmpty }, "the cancel waited behind the call it names")
        #expect(relay.reply(2, within: 15) != nil)

        relay.closeInput()
        #expect(relay.exitStatus(within: 10) == 0, "\(relay.stderr)")
        // The client withdrew the call itself, so the relay adds no cancel of its own.
        #expect(stub.cancels.map(\.cancels) == [2])
    }

    /// Seven held calls are more than a URL session opens to one host by default, and the app
    /// answers each POST on its own connection: without a higher limit, the eighth request
    /// waits inside the relay however concurrently it was sent.
    @Test func controlFramesDoNotQueueBehindManyHeldCalls() throws {
        let stub = MCPHoldingStub(maxHold: 15)
        defer { stub.stop() }
        let relay = try relay(to: stub)
        defer { relay.finish() }

        let calls = Array(2...8)
        for id in calls { relay.callTool(id) }
        #expect(stub.wait(within: 10) { calls.allSatisfy(stub.isHeld) }, "not every call reached the browser")
        relay.ping(9)
        #expect(relay.reply(9, within: 5) != nil, "the ping waited behind the held calls")
        #expect(calls.allSatisfy(stub.isHeld))

        for id in calls { stub.release(id) }
        #expect(calls.allSatisfy { relay.reply($0, within: 15) != nil })
        relay.closeInput()
        #expect(relay.exitStatus(within: 10) == 0, "\(relay.stderr)")
    }

    /// A request the browser refuses ends the relay, as it did when every frame was sent in
    /// turn: it does not wait for the client to write again.
    @Test func aRefusedRequestEndsTheRelay() throws {
        let stub = MCPHoldingStub(failing: [2])
        defer { stub.stop() }
        let relay = try relay(to: stub)
        defer { relay.finish() }

        relay.callTool(2)
        #expect(relay.exitStatus(within: 10) == 3, "\(relay.stderr)")
        #expect(relay.stderr.contains(stub.url), "\(relay.stderr)")
    }

    /// Every POST after `initialize` must replay the session id its answer carries, and the app
    /// refuses a request without one. So nothing may be forwarded alongside the handshake.
    @Test func nothingButTheHandshakeIsForwardedUntilItIsAnswered() throws {
        let stub = MCPHoldingStub(initializeDelay: 0.5)
        try stub.start()
        defer { stub.stop() }
        let relay = try RelaySession(endpoint: stub.url)
        defer { relay.finish() }

        relay.initialize()
        relay.ping(1)
        #expect(relay.reply(0, within: 15) != nil, "\(relay.stderr)")
        #expect(relay.reply(1, within: 15) != nil, "\(relay.stderr)")

        let posts = stub.posts
        let answered = try #require(stub.initializeAnswered)
        #expect(posts.map(\.method) == ["initialize", "notifications/initialized", "ping"])
        #expect(posts.dropFirst().allSatisfy { $0.at >= answered })
        #expect(posts.dropFirst().allSatisfy { $0.session == AgentStubServer.mcpSession })
        relay.closeInput()
        #expect(relay.exitStatus(within: 10) == 0, "\(relay.stderr)")
    }
}
