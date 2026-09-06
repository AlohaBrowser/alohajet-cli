import Testing
import Foundation
@testable import AgentDriver

// MARK: - Driver parity (THE GATING ORACLE — hermetic, LLM-free) — FROZEN
//
// Takes a `CLIRunResult` fixture — the exact value an in-process agent loop would
// hand back — and drives it through `RemoteAutomationDriver` over an INJECTED stub
// TRANSPORT that returns what an agent endpoint would emit: the fixture run through
// the ONE wire encoder (`encodedWireData()`), wrapped in the `{ state:"done",
// result }` envelope (see `remoteResultEnvelope`). Then asserts the two are
// observably IDENTICAL from the executable's point of view.
//
// The observable surface `main.swift` owns is `result.encodedJSON()` (the `--json`
// bytes) and the exit code (`isSuccess ? 0 : 1`). Parity means those are
// byte-identical / equal, for a SUCCESS fixture (exit 0) AND a FAILURE fixture
// (exit 1). Because `RemoteAutomationDriver` decodes through `CLIRunResult`'s
// Codable and re-derives `isSuccess`, a matching decoded value yields a
// byte-identical `encodedJSON()` — that is the whole proof.
//
// This package ships ONE driver: the agent loop is reached over HTTP and is never
// linked, so there is no second in-process lane here to run the fixture through.
// The fixture IS that lane's output — a driver whose runner returns it verbatim
// returns it verbatim — so comparing against the fixture proves exactly what a
// two-driver comparison would, without standing up a loop this package does not
// have. A host that adds an `AlohaJetDriver` of its own is held to this same
// oracle: run its driver over these fixtures and the bytes must not move.
//
// DO NOT relax these fixtures: they are the frozen contract every backend is built
// against (alongside `CLIRunResultWireRoundTripTests`).

@Suite("Driver parity (frozen oracle)")
struct DriverParityTests {

    private let prompt = "what is 2+2?"

    /// The remote outcome: a stub transport emits the fixture as an agent endpoint
    /// would (encodedWireData → `{ state:"done", result }`), the driver decodes it.
    private func remoteResult(_ fixture: CLIRunResult) async throws -> CLIRunResult {
        let done = try remoteResultEnvelope(state: "done", result: fixture)
        let stub = RemoteStubServer(resultBodies: [done])
        let driver = makeRemoteDriver(stub: stub)
        return try await driver.runTask(prompt: prompt)
    }

    // SUCCESS fixture (endTurn, finalText:"Four.", failureReason:nil, exit 0): the
    // round trip yields byte-identical `encodedJSON()` and the same exit-code source.
    @Test("SUCCESS fixture: identical encodedJSON() bytes and exit-code across the wire")
    func successParity() async throws {
        let fixture = CLIRunResult(finalText: "Four.", completion: .endTurn, failureReason: nil)

        let remote = try await remoteResult(fixture)

        // Byte-identical CLI `--json` surface.
        #expect(fixture.encodedJSON() == remote.encodedJSON())
        // Identical exit-code source, pinned to success (exit 0).
        #expect(fixture.isSuccess == remote.isSuccess)
        #expect(remote.isSuccess)
        // Nothing was rewritten in transit.
        #expect(remote == fixture)
    }

    // FAILURE fixture (failed, finalText:nil, failureReason:"boom", exit 1): same.
    @Test("FAILURE fixture: identical encodedJSON() bytes and exit-code across the wire")
    func failureParity() async throws {
        let fixture = CLIRunResult(finalText: nil, completion: .failed, failureReason: "boom")

        let remote = try await remoteResult(fixture)

        #expect(fixture.encodedJSON() == remote.encodedJSON())
        #expect(fixture.isSuccess == remote.isSuccess)
        #expect(!remote.isSuccess)
        #expect(remote == fixture)
    }

    // The completions a wire round trip must not smear into one another: each one
    // survives with its own snake_case spelling and its own exit-code answer.
    @Test("every completion survives the wire with its spelling and exit code intact",
          arguments: [CLITurnCompletion.endTurn, .maxTurns, .stuckRepeat, .failed, .interrupted])
    func everyCompletionSurvives(_ completion: CLITurnCompletion) async throws {
        let fixture = CLIRunResult(
            finalText: completion == .endTurn ? "text" : nil,
            completion: completion,
            failureReason: completion == .endTurn ? nil : "why")

        let remote = try await remoteResult(fixture)

        #expect(remote == fixture)
        #expect(remote.encodedJSON() == fixture.encodedJSON())
        #expect(remote.encodedJSON().contains(#""completion":"\#(completion.jsonValue)""#))
    }
}
