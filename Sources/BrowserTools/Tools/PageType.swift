import Foundation
import ToolABI

/// The executable `page_type` tool: types text into an input/textarea/contenteditable
/// element on the active tab by its `aloha_id`, optionally pressing Enter to submit
/// afterward.
///
/// `AgentBrowserBridge.type` resolves + focuses the element and types over real CDP key
/// events itself, so unlike click this tool calls it straight, without `executeAgentCode`.
///
/// `replace` defaults to `true`: an APPEND default silently doubles a re-typed field
/// ("login username -> loop"). That default matches `PageBridge.swift`'s `type` case; it is
/// preserved here, not re-derived.
@MainActor public final class PageTypeExecutorTool: ExecutorTool {
    public let name = "page_type"

    public init() {}

    /// How many fields one call may fill. Same bound and same reason as `get_text`'s: the point is to spend
    /// fewer rounds, and the receipt is paid on every later round.
    private static let maxBatch = 20

    /// The longest `text` one field may carry.
    ///
    /// `PageBridge.type` dispatches TWO `Input.dispatchKeyEvent` round-trips PER CHARACTER, so the cost of a
    /// call is linear in the string and paid entirely in CDP latency. With no bound, a 2,000,000-character
    /// value ran past 120 s and had to be killed, holding the browser for all of it — a page that talks a
    /// model into typing a blob wedges the session. 10k is far longer than any real form field and still
    /// well under a second of typing.
    static let maxTextLength = 10_000

    /// REFUSED, NOT TRUNCATED. Truncating puts a value the caller did not ask for into a form and then
    /// submits it, which is the same failure the partial-fill rule below exists to prevent: a wrong request
    /// the site accepts, and an agent reasoning over the answer to a different question.
    static func refuseTooLong(_ alohaId: String, _ count: Int) -> RawToolResult {
        RawToolResult(
            output: "page_type refused \(count) characters for \"\(alohaId)\": the limit is \(maxTextLength). "
                + "Every character costs two CDP round-trips, so a value this long spends the whole session "
                + "on keystrokes. Type what the field needs.",
            isError: true)
    }

    struct Field: Equatable {
        let alohaId: String
        let text: String
        let replace: Bool
    }

    /// AN ARRAY RATHER THAN A DELIMITED STRING, unlike `get_text`. Ids are opaque tokens so a comma-separated
    /// list is safe for them; typed VALUES are user text, and addresses, prices and sentences contain commas
    /// routinely. A delimited `text` parameter would split "Springfield, IL" into two fields and no amount of
    /// escaping documentation would stop that reaching production.
    static func fields(_ input: WorkflowValue?) -> [Field]? {
        guard let raw = PageToolInput.array(input, "fields"), !raw.isEmpty else { return nil }
        var out: [Field] = []
        for item in raw {
            guard let alohaId = PageToolInput.string(item, "aloha_id"), !alohaId.isEmpty,
                  let text = PageToolInput.string(item, "text") else { continue }
            out.append(Field(alohaId: alohaId, text: text,
                             replace: PageToolInput.bool(item, "replace") ?? true))
        }
        return out.isEmpty ? nil : Array(out.prefix(maxBatch))
    }

    public func execute(_ input: WorkflowValue?, _ context: ToolExecutionContext) async throws -> RawToolResult {
        // A FORM IS FILLED ONE FIELD PER ROUND, AND THAT IS THE ROUND BUDGET. Measured 2026-08-07 over 826 tool
        // calls from 82 stored corpus rows: `page_type` -> `page_type` is the most common consecutive pair in
        // the whole corpus (76), ahead of click -> click (63), and typing plus clicking is 46% of every call
        // made. Since the standing prompt is re-sent every round, a login that costs three rounds and a filter
        // form that costs five are paid at full prompt weight each — the same mechanism that made read
        // granularity the 11.6x token gap.
        if let batch = Self.fields(input) {
            // The whole call, not just the offending field: a form filled with one field missing must
            // not be submitted, which is this tool's own rule about partial fills.
            if let oversized = batch.first(where: { $0.text.count > Self.maxTextLength }) {
                return Self.refuseTooLong(oversized.alohaId, oversized.text.count)
            }
            return await typeBatch(batch, submit: PageToolInput.bool(input, "submit") ?? false, context)
        }
        guard let alohaId = PageToolInput.string(input, "aloha_id"), !alohaId.isEmpty else {
            return RawToolResult(output: "page_type requires an \"aloha_id\" naming the element to type into, "
                                 + "or a \"fields\" list of {aloha_id, text} to fill several at once.", isError: true)
        }
        guard let text = PageToolInput.string(input, "text") else {
            return RawToolResult(output: "page_type requires \"text\" to type.", isError: true)
        }
        guard text.count <= Self.maxTextLength else {
            return Self.refuseTooLong(alohaId, text.count)
        }
        // REPLACE by default — see the type-doc above; an append default doubled
        // re-typed fields in production. Pass replace:false to append instead.
        let replace = PageToolInput.bool(input, "replace") ?? true
        let submit = PageToolInput.bool(input, "submit") ?? false

        switch await resolveActivePageTab(name, context) {
        case let .failure(errorResult):
            return errorResult
        case let .success(resolved):
            let bridge = makePageBridge(resolved.cdpTab, context.signal)
            // Two backend URL reads bracket the action so the receipt can say whether the
            // page moved — see PageDelta, and the 44-row blind-receipt measurement behind it.
            let urlBefore = bridge.currentPageURL()
            // Which element this was, in replayable terms — resolved before the action, since typing can
            // re-render the form and the snapshot would then hold a different node. See `PageToolReceipt`.
            let selectorNote = PageToolReceipt.selectorNote(alohaId: alohaId, tab: resolved.cdpTab)
            let typeResult = await bridge.type(alohaId, text, replace: replace)
            if typeResult.isError {
                return resolved.tab.naming(RawToolResult(output: typeResult.output, isError: true))
            }
            // The same one-line affordance `get_text` carries, at the same kind of moment: a round spent on
            // one field, when `page_type` -> `page_type` is the most common consecutive pair in the corpus.
            // Flag-gated, OFF by baseline.
            //
            // ON BOTH BRANCHES, and the first version was on neither of the ones that matter. It sat only
            // inside `guard submit else`, so a single-field type WITH submit:true — a search box, which is the
            // most common single-field type there is — got no hint at all. Measured: the hints arm made two
            // page_type calls and the hint text appeared in zero traces.
            let hint = (context.services?.webExtractionOptions ?? .baseline).batchHints
                ? "\n(Filling one field per call spends a round each. Pass the whole form at once: "
                  + "fields=[{aloha_id, text}, ...] with submit:true.)"
                : ""
            guard submit else {
                // Settled, not immediate: typing rarely navigates, so this costs the grace window
                // only in the case where the receipt would have been right anyway.
                let urlAfter = await bridge.settledPageURL(after: urlBefore)
                return resolved.tab.naming(
                    RawToolResult(output: "Typed into element \"\(alohaId)\"."
                                  + PageDelta.describe(urlBefore: urlBefore, urlAfter: urlAfter)
                                  + selectorNote + hint,
                                  isError: nil))
            }
            let submitResult = await bridge.pressKeys("Enter")
            if submitResult.isError {
                return resolved.tab.naming(RawToolResult(
                    output: "Typed into element \"\(alohaId)\", but submitting Enter failed: \(submitResult.output)",
                    isError: true))
            }
            // AFTER the Enter, which is the action that navigates. Read before it — as this was —
            // the receipt reports the URL from before the submit, so a form submission that worked
            // is announced as "The page did NOT navigate" every single time.
            let urlAfter = await bridge.settledPageURL(after: urlBefore)
            return resolved.tab.naming(
                RawToolResult(output: "Typed into element \"\(alohaId)\" and pressed Enter to submit."
                              + PageDelta.describe(urlBefore: urlBefore, urlAfter: urlAfter)
                              + selectorNote + hint,
                              isError: nil))
        }
    }

    /// WHY A PARTIAL FILL MUST NOT SUBMIT. Batching a read is harmless when one id is stale — the caller gets
    /// the rest and asks again. A form is not like that: submitting with field two missing sends a WRONG
    /// request that the site accepts, and the agent then reasons over a result that answers a different
    /// question than the one asked. So a failure anywhere cancels the submit and says which id failed, leaving
    /// the form filled and the decision with the caller.
    private func typeBatch(_ fields: [Field], submit: Bool,
                           _ context: ToolExecutionContext) async -> RawToolResult {
        switch await resolveActivePageTab(name, context) {
        case let .failure(errorResult):
            return errorResult
        case let .success(resolved):
            let bridge = makePageBridge(resolved.cdpTab, context.signal)
            let urlBefore = bridge.currentPageURL()
            var filled: [String] = []
            var failures: [String] = []
            for field in fields {
                let result = await bridge.type(field.alohaId, field.text, replace: field.replace)
                if result.isError {
                    failures.append("\"\(field.alohaId)\": \(result.output)")
                } else {
                    filled.append(field.alohaId)
                }
            }
            let urlAfter = bridge.currentPageURL()
            let delta = PageDelta.describe(urlBefore: urlBefore, urlAfter: urlAfter)

            if !failures.isEmpty {
                let filledNote = filled.isEmpty ? "No field was filled." : "Filled \(filled.count): \(filled.joined(separator: ", "))."
                let submitNote = submit ? " Did NOT submit, because the form is only partly filled." : ""
                return RawToolResult(output: "\(filledNote) Failed \(failures.count) — \(failures.joined(separator: "; "))."
                                     + submitNote + delta,
                                     isError: filled.isEmpty ? true : nil)
            }
            guard submit else {
                return RawToolResult(output: "Filled \(filled.count) field(s): \(filled.joined(separator: ", "))." + delta,
                                     isError: nil)
            }
            let submitResult = await bridge.pressKeys("Enter")
            if submitResult.isError {
                return RawToolResult(
                    output: "Filled \(filled.count) field(s): \(filled.joined(separator: ", ")), "
                        + "but submitting Enter failed: \(submitResult.output)" + delta,
                    isError: true)
            }
            let urlFinal = bridge.currentPageURL()
            return RawToolResult(output: "Filled \(filled.count) field(s): \(filled.joined(separator: ", ")) "
                                 + "and pressed Enter to submit."
                                 + PageDelta.describe(urlBefore: urlBefore, urlAfter: urlFinal),
                                 isError: nil)
        }
    }
}
