import Foundation
import ToolABI

// MARK: - The run-result contract
//
// The terminal outcome of a run that produces an ANSWER rather than a tool receipt:
// the final assistant text and how the run ended. It is a wire contract first — one
// process produces it, another decodes it — so both the encoders below are frozen by
// `CLIRunResultTests` and neither may be "improved" without breaking a consumer.
//
// Its only dependency is `JSValue`, deliberately: a contract type that drags a
// runtime behind it cannot be decoded by a peer that does not link that runtime.
//
// NOT the type the tool commands return. `open`/`read`/`click`/… each run exactly one
// tool call and emit a `RawToolResult` with its own exit-code taxonomy
// (0 ok · 1 tool error · 2 usage · 3 browser unreachable). This type is for the
// prompt-shaped surface, where a whole run collapses to one answer and one verdict.

// MARK: - Completion

public nonisolated enum CLITurnCompletion: String, Sendable, Equatable, Codable {
    /// A normal end of turn — the only ending that can be a success.
    case endTurn
    /// The run hit its pinned step cap: a truncated, half-finished answer, which is
    /// treated as a failure.
    case maxTurns
    /// The stuck-loop guard ended the run. Deliberately NOT folded into `maxTurns`:
    /// the two have opposite recoveries — a cap says the work was too long for the
    /// budget and a larger budget may finish it; a stuck repeat says the same call
    /// kept returning the same thing and a larger budget buys more of it. Reading a
    /// run's ending as the wrong one of those sends the next change in the wrong
    /// direction.
    case stuckRepeat
    case failed
    case interrupted

    /// The wire spelling (snake_case). DISTINCT from `rawValue` (the camelCase case
    /// names), so the JSON contract is stable independent of those identifiers, and
    /// so `rawValue` stays free for diagnostics. Also the `Codable` form below, so a
    /// result decoded from `--json` output round-trips to the same spelling.
    public var jsonValue: String {
        switch self {
        case .endTurn: return "end_turn"
        case .maxTurns: return "max_turns"
        case .stuckRepeat: return "stuck_repeated_tool_error"
        case .failed: return "failed"
        case .interrupted: return "interrupted"
        }
    }

    // Custom Codable over the snake_case `jsonValue` rather than the default
    // rawValue-based synthesis, so the encoded form matches the `--json` surface
    // exactly.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "end_turn": self = .endTurn
        case "max_turns": self = .maxTurns
        case "stuck_repeated_tool_error": self = .stuckRepeat
        case "failed": self = .failed
        case "interrupted": self = .interrupted
        default:
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath,
                      debugDescription: "unknown CLITurnCompletion '\(raw)'"))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(jsonValue)
    }
}

// MARK: - Result

public nonisolated struct CLIRunResult: Sendable, Equatable, Codable {
    /// The final assistant answer, or `nil` when the run produced none (a
    /// tool-call-last / truncated transcript).
    public let finalText: String?
    public let completion: CLITurnCompletion
    /// When the run did not end cleanly, the reason carried by the terminal event,
    /// so a caller can show WHY instead of a generic string. `nil` on a clean end
    /// of turn.
    public let failureReason: String?

    public init(finalText: String?, completion: CLITurnCompletion, failureReason: String? = nil) {
        self.finalText = finalText
        self.completion = completion
        self.failureReason = failureReason
    }

    /// A run succeeds only when it ended `.endTurn` AND carried assistant text.
    /// `.maxTurns` (half-finished), `.stuckRepeat`, `.failed`, `.interrupted`, and
    /// an `.endTurn` with no text are all failures.
    public var isSuccess: Bool {
        completion == .endTurn && finalText != nil
    }

    /// The human/harness surface: this result as a single, deterministic JSON object
    /// on one line —
    /// `{"finalText":…,"completion":"end_turn","isSuccess":true,"failureReason":null}`.
    /// Key order is FIXED (finalText, completion, isSuccess, failureReason) and `nil`
    /// text/reason serialize as JSON `null`. Built through `JSValue.stringify()` so
    /// strings get correct JSON escaping and the byte stream is stable for a
    /// consuming harness to diff. The computed `isSuccess` is included explicitly
    /// (the synthesized `Codable` omits it).
    /// `sessionId`, when given, is appended as a fifth key so a harness can resume the
    /// conversation the turn ran in without parsing prose off stderr.
    public func encodedJSON(sessionId: String? = nil) -> String {
        let finalTextValue: JSValue = finalText.map { .string($0) } ?? .null
        let failureReasonValue: JSValue = failureReason.map { .string($0) } ?? .null
        var fields: [(String, JSValue)] = [
            ("finalText", finalTextValue),
            ("completion", .string(completion.jsonValue)),
            ("isSuccess", .bool(isSuccess)),
            ("failureReason", failureReasonValue),
        ]
        if let sessionId { fields.append(("sessionId", .string(sessionId))) }
        return JSValue.object(fields).stringify()
    }

    /// The process-to-process wire form: the synthesized `Codable` JSON — the stored
    /// `{finalText?, completion, failureReason?}` and NOTHING else, so the derived
    /// `isSuccess` is NEVER transported. A producer therefore cannot claim success on
    /// a failed run; the consumer re-derives the verdict from the fields it was given.
    /// DISTINCT from `encodedJSON()`, which DOES carry `isSuccess` for the reader's eye.
    public func encodedWireData() throws -> Data {
        try JSONEncoder().encode(self)
    }
}
