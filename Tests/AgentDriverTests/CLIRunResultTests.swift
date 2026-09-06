import Testing
import Foundation
@testable import AgentDriver

// The run-result contract, frozen. Two encoders with two different jobs:
//
//   `encodedJSON()`      the one-line `--json` surface a human or a harness reads.
//                        Fixed key order, and it DOES carry the derived `isSuccess`.
//   `encodedWireData()`  the process-to-process form. It does NOT carry `isSuccess`,
//                        so a producer cannot claim success on a failed run — the
//                        consumer re-derives the verdict from the stored fields.
//
// Nothing here launches a browser: every case is a hand-built `CLIRunResult`.
// DO NOT relax the fixtures; a consumer is written against these exact bytes.

@Suite("CLIRunResult JSON surface")
struct CLIRunResultJSONTests {

    // A successful end of turn: text present, `isSuccess` true, snake_case completion.
    @Test func encodesSuccessfulEndTurn() {
        let result = CLIRunResult(finalText: "the answer", completion: .endTurn)
        #expect(
            result.encodedJSON()
                == #"{"finalText":"the answer","completion":"end_turn","isSuccess":true,"failureReason":null}"#)
    }

    // A failed run with no text: `finalText` is JSON `null`, `isSuccess` false, reason carried.
    @Test func encodesFailedTurnWithReason() {
        let result = CLIRunResult(finalText: nil, completion: .failed, failureReason: "boom")
        #expect(
            result.encodedJSON()
                == #"{"finalText":null,"completion":"failed","isSuccess":false,"failureReason":"boom"}"#)
    }

    // `.maxTurns` renders as `max_turns`, NOT the camelCase rawValue.
    @Test func encodesMaxTurnsAsSnakeCase() {
        let result = CLIRunResult(finalText: nil, completion: .maxTurns, failureReason: "max_turns")
        #expect(
            result.encodedJSON()
                == #"{"finalText":null,"completion":"max_turns","isSuccess":false,"failureReason":"max_turns"}"#)
    }

    // Quotes and newlines must be JSON-escaped, or the line is not parseable JSON.
    @Test func escapesSpecialCharactersInFinalText() {
        let result = CLIRunResult(finalText: "line1\n\"q\"", completion: .endTurn)
        #expect(
            result.encodedJSON()
                == #"{"finalText":"line1\n\"q\"","completion":"end_turn","isSuccess":true,"failureReason":null}"#)
    }

    // `Codable` round-trips the stored fields; `isSuccess` recomputes on decode.
    @Test func codableRoundTrips() throws {
        let original = CLIRunResult(finalText: "hi", completion: .endTurn, failureReason: nil)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CLIRunResult.self, from: data)
        #expect(decoded == original)
        #expect(decoded.isSuccess)
    }

    // The completion enum's `Codable` form is the snake_case spelling (wrapped in an
    // array to avoid a top-level JSON fragment).
    @Test func completionCodableUsesSnakeCase() throws {
        let data = try JSONEncoder().encode([CLITurnCompletion.maxTurns])
        #expect(String(data: data, encoding: .utf8) == #"["max_turns"]"#)
        let decoded = try JSONDecoder().decode([CLITurnCompletion].self, from: data)
        #expect(decoded == [.maxTurns])
    }
}

@Suite("CLIRunResult wire round-trip (frozen oracle)")
struct CLIRunResultWireRoundTripTests {

    // SUCCESS fixture: a clean end of turn carrying text and no reason.
    @Test func successFixtureRoundTrips() throws {
        let source = CLIRunResult(finalText: "Four.", completion: .endTurn, failureReason: nil)

        let bytes = try source.encodedWireData()
        let decoded = try JSONDecoder().decode(CLIRunResult.self, from: bytes)

        #expect(decoded == source)
        // Derived on decode — the wire never carried it.
        #expect(decoded.isSuccess)
        #expect(!String(decoding: bytes, as: UTF8.self).contains("isSuccess"))
    }

    // FAILURE fixture: no text, but a carried reason — the shape a success-only
    // surface would drop.
    @Test func failureFixtureRoundTrips() throws {
        let source = CLIRunResult(finalText: nil, completion: .failed, failureReason: "boom")

        let bytes = try source.encodedWireData()
        let decoded = try JSONDecoder().decode(CLIRunResult.self, from: bytes)

        #expect(decoded == source)
        #expect(!decoded.isSuccess)
        #expect(!String(decoding: bytes, as: UTF8.self).contains("isSuccess"))
    }
}

@Suite("A stuck repeat is not a turn cap")
struct StuckRepeatCompletionTests {

    /// They used to be one case. A cap says the work outgrew the budget and a bigger
    /// budget may finish it; a stuck repeat says the same call kept returning the same
    /// thing and a bigger budget buys more of it. Reading one as the other sends the
    /// next change the wrong way.
    @Test func theTwoForcedStopsDoNotCollapseIntoOne() {
        #expect(CLITurnCompletion.stuckRepeat != CLITurnCompletion.maxTurns)
        #expect(CLITurnCompletion.stuckRepeat.jsonValue != CLITurnCompletion.maxTurns.jsonValue)
    }

    /// The wire spelling a peer decoder matches on. Spelled out here because this
    /// module links no loop to read the constant from — this literal IS the contract.
    @Test func theWireSpellingIsFrozen() {
        #expect(CLITurnCompletion.stuckRepeat.jsonValue == "stuck_repeated_tool_error")
    }

    @Test func itSurvivesTheWireRoundTrip() throws {
        let bytes = try JSONEncoder().encode(CLITurnCompletion.stuckRepeat)
        #expect(try JSONDecoder().decode(CLITurnCompletion.self, from: bytes) == .stuckRepeat)
    }

    /// An unknown completion is rejected, not silently mapped to a success.
    @Test func anUnknownCompletionFailsToDecode() {
        let bytes = Data(#""finished""#.utf8)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(CLITurnCompletion.self, from: bytes)
        }
    }
}

@Suite("CLIRunResult equality and verdict")
struct CLIRunResultEqualityTests {

    /// `failureReason` participates in `==`, so a differing reason is a differing result.
    @Test func cleanResultIsNilReasonAndEquatable() {
        let a = CLIRunResult(finalText: "x", completion: .endTurn)
        let b = CLIRunResult(finalText: "x", completion: .endTurn)
        #expect(a.failureReason == nil)
        #expect(a == b)
        let c = CLIRunResult(finalText: "x", completion: .failed, failureReason: "boom")
        #expect(a != c)
    }

    /// Every non-`endTurn` ending is a failure, and so is an `endTurn` with no text.
    @Test func onlyEndTurnWithTextSucceeds() {
        #expect(CLIRunResult(finalText: "x", completion: .endTurn).isSuccess)
        #expect(!CLIRunResult(finalText: nil, completion: .endTurn).isSuccess)
        for completion: CLITurnCompletion in [.maxTurns, .stuckRepeat, .failed, .interrupted] {
            #expect(!CLIRunResult(finalText: "x", completion: completion).isSuccess)
        }
    }
}
