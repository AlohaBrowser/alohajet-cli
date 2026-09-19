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

    /// Where the keystrokes went when the id named a label or a wrapper rather than a field, or
    /// nil when they went where the caller pointed. The bridge resolves a `<label>` (or a wrapper
    /// around exactly one field) to its control and reports that id on `rawResult`; the receipt is
    /// composed HERE, so it has to say so itself -- the bridge's own sentence never reached the
    /// model, and a silent redirect is the mis-type the resolution exists to prevent.
    static func redirect(in result: AgentActionResult) -> (id: String, tag: String)? {
        guard let id = result.rawResult?["redirectedTo"]?.stringValue, !id.isEmpty else { return nil }
        return (id, result.rawResult?["redirectedTag"]?.stringValue ?? "field")
    }

    /// The sentence that follows the receipt's first when the keystrokes were redirected: which id
    /// the model passed, what it was, and which id to use for this field from now on.
    static func redirectNote(from alohaId: String, to redirect: (id: String, tag: String)?) -> String {
        guard let redirect else { return "" }
        return " \"\(alohaId)\" is a label for that <\(redirect.tag)> and holds no text itself; "
            + "use \"\(redirect.id)\" for this field from now on."
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
            var selectorNote = PageToolReceipt.selectorNote(alohaId: alohaId, tab: resolved.cdpTab)
            let typeResult = await bridge.type(alohaId, text, replace: replace)
            if typeResult.isError {
                return resolved.tab.naming(RawToolResult(output: typeResult.output, isError: true))
            }
            // THE ELEMENT THE KEYSTROKES WENT TO, which is the field when the id named its label.
            // The receipt names that field first, since it is the id the model reuses, and the
            // selector is the field's too: the snapshot read is still the pre-typing one here.
            let redirect = Self.redirect(in: typeResult)
            let typedInto = "\"\(redirect?.id ?? alohaId)\""
            let redirectNote = Self.redirectNote(from: alohaId, to: redirect)
            if let redirect {
                selectorNote = PageToolReceipt.selectorNote(alohaId: redirect.id, tab: resolved.cdpTab)
            }
            // Arms `page_click`'s duplicate-submit form read for THIS tab only -- a duplicate
            // submission needs a filled form, and a filled form needs typing. See `SubmittedForms`.
            submittedForms.noteTyped(resolved.tab.id, scope: context.sessionId)
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
                let receipt = RawToolResult(output: "Typed into element \(typedInto)." + redirectNote
                                            + PageDelta.describe(urlBefore: urlBefore, urlAfter: urlAfter)
                                            + selectorNote + hint,
                                            isError: nil)
                // THE PAGE, ALWAYS -- not gated on the fingerprint the other tools use. That gate
                // compares the document generation, the element count and the URL, and a typed
                // VALUE changes none of them, so gating a type on it suppressed the page every
                // time. Measured on WebArena run 33956015125 against 33918469392, the four Magento
                // report tasks that type two dates and run a report:
                //
                //     t706  2/3 -> 0/3     t711  3/3 -> 0/3
                //     t712  3/3 -> 1/3     t713  3/3 -> 0/3
                //
                // shopping_admin fell 11/30 to 1/30 and `page_type` calls rose 369 -> 677: unable
                // to see whether the date had landed in a picker that reformats and rejects input,
                // the model retyped. For a type the value IS the change, and confirming it is the
                // whole reason to send the page back.
                return resolved.tab.naming(await withPageSnapshot(receipt, context, resolved))
            }
            let submitResult = await bridge.pressKeys("Enter")
            if submitResult.isError {
                // The typing LANDED before the Enter failed, so the page has changed and the model
                // needs it to decide what to do next -- an error that hides it costs a re-read.
                let receipt = RawToolResult(
                    output: "Typed into element \(typedInto), but submitting Enter failed: \(submitResult.output)"
                        + redirectNote,
                    isError: true)
                return resolved.tab.naming(await withPageSnapshot(receipt, context, resolved, evenIfError: true))
            }
            // AFTER the Enter, which is the action that navigates. Read before it — as this was —
            // the receipt reports the URL from before the submit, so a form submission that worked
            // is announced as "The page did NOT navigate" every single time.
            let urlAfter = await bridge.settledPageURL(after: urlBefore)
            // A form that was SUBMITTED is the one type whose result matters most, and it was the
            // one branch sending no page at all: `type(submit: true)` returned 230 characters of
            // receipt and nothing else. Measured over 579 distinct `page_type` calls in WebArena
            // run 34366647873: 36% came back with a page and 39% with a bare receipt, against 65%
            // for `page_click`. That gap is this branch. It is also precisely the shape on which
            // "answered without looking" fires -- 64 of 199 answer turns (32%) in the same run --
            // because the model submitted a form and had nothing to look at.
            //
            // ONCE, AFTER THE WHOLE STRING AND THE ENTER -- never per keystroke, and after
            // `settledPageURL` has waited out the navigation the Enter caused. Taking it before that
            // wait would capture the page the form was submitted FROM, which is worse than nothing.
            let receipt = RawToolResult(
                output: "Typed into element \(typedInto) and pressed Enter to submit." + redirectNote
                    + PageDelta.describe(urlBefore: urlBefore, urlAfter: urlAfter)
                    + selectorNote + hint,
                isError: nil)
            return resolved.tab.naming(await withPageSnapshot(receipt, context, resolved))
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
                    // The id the keystrokes went to, first; and when that is not the id the caller
                    // passed, which one it was resolved from, so the next call passes the field.
                    if let redirect = Self.redirect(in: result) {
                        filled.append("\(redirect.id) (the <\(redirect.tag)> that \(field.alohaId) labels; use it from now on)")
                    } else {
                        filled.append(field.alohaId)
                    }
                    submittedForms.noteTyped(resolved.tab.id, scope: context.sessionId)
                }
            }
            let urlAfter = bridge.currentPageURL()
            let delta = PageDelta.describe(urlBefore: urlBefore, urlAfter: urlAfter)

            // EVERY EXIT FROM HERE CARRIES THE PAGE. This is the path the batch hint tells the
            // model to prefer -- "Pass the whole form at once" -- so a batch that returned a bare
            // receipt sent the model down the recommended road and left it blind at the end of
            // it. `withPageSnapshot` skips an errored receipt on its own, so the partly-filled
            // case below attaches the page exactly when something WAS filled.
            if !failures.isEmpty {
                let filledNote = filled.isEmpty ? "No field was filled." : "Filled \(filled.count): \(filled.joined(separator: ", "))."
                let submitNote = submit ? " Did NOT submit, because the form is only partly filled." : ""
                let receipt = RawToolResult(output: "\(filledNote) Failed \(failures.count) — \(failures.joined(separator: "; "))."
                                            + submitNote + delta,
                                            isError: filled.isEmpty ? true : nil)
                return await withPageSnapshot(receipt, context, resolved)
            }
            guard submit else {
                let receipt = RawToolResult(output: "Filled \(filled.count) field(s): \(filled.joined(separator: ", "))." + delta,
                                            isError: nil)
                return await withPageSnapshot(receipt, context, resolved)
            }
            let submitResult = await bridge.pressKeys("Enter")
            if submitResult.isError {
                // Same as the single-field branch: the fields were filled, the page changed, and the
                // error must not hide it.
                let receipt = RawToolResult(
                    output: "Filled \(filled.count) field(s): \(filled.joined(separator: ", ")), "
                        + "but submitting Enter failed: \(submitResult.output)" + delta,
                    isError: true)
                return await withPageSnapshot(receipt, context, resolved, evenIfError: true)
            }
            // Settled, like the single-field submit above: the Enter is what navigates, and an
            // immediate read names the page the form was submitted from.
            let urlFinal = await bridge.settledPageURL(after: urlBefore)
            let receipt = RawToolResult(output: "Filled \(filled.count) field(s): \(filled.joined(separator: ", ")) "
                                        + "and pressed Enter to submit."
                                        + PageDelta.describe(urlBefore: urlBefore, urlAfter: urlFinal),
                                        isError: nil)
            return await withPageSnapshot(receipt, context, resolved)
        }
    }
}
