import Foundation
import ToolABI

/// The executable `page_click` tool: single/double/triple/right-clicks an element on the
/// active tab by its `aloha_id`. The `aloha.<verb>(alohaId)` call text is built here from
/// the typed `click_type`; the caller never supplies raw code through this tool.
///
/// `executeAgentCode` is required, not incidental: the click cases need the aloha-id
/// resolved to viewport coordinates, which only the in-page `window.__aloha` runtime can
/// do, and `enqueueCdp` is a no-op outside the `buildAgentCodeRunnerScript` wrapper
/// `executeAgentCode` installs.
///
/// A plain click on a `[uploadable]` file input is refused outright, and the refusal names
/// `page_upload` — the verb that does work — so the model does not spend a retry rediscovering
/// it. That guard lives in `handleClickPendingRequest`, so it applies unconditionally; this
/// tool does not special-case or bypass it.
@MainActor public final class PageClickExecutorTool: ExecutorTool {
    public let name = "page_click"

    public init() {}

    public func execute(_ input: WorkflowValue?, _ context: ToolExecutionContext) async throws -> RawToolResult {
        guard let alohaId = PageToolInput.string(input, "aloha_id"), !alohaId.isEmpty else {
            return RawToolResult(output: "page_click requires an \"aloha_id\" naming the element to click.", isError: true)
        }
        let clickType = PageToolInput.string(input, "click_type") ?? "single"
        guard let route = Self.route(for: clickType) else {
            return RawToolResult(
                output: "page_click: unknown click_type \"\(clickType)\"; expected \"single\", \"double\", \"triple\", or \"right\".",
                isError: true)
        }

        switch await resolveActivePageTab(name, context) {
        case let .failure(errorResult):
            return errorResult
        case let .success(resolved):
            let bridge = makePageBridge(resolved.cdpTab, context.signal)
            let script = "aloha.\(route.call)(\(jsonStringLiteral(alohaId)))"
            // WHERE THE PAGE WAS BEFORE THE CLICK. Two cheap backend reads bracket the action so the
            // receipt can state whether anything moved; see `PageDelta`.
            let urlBefore = bridge.currentPageURL()
            // AND WHAT THE PAGE'S STRUCTURE WAS, so the receipt can carry the page only when the
            // click changed it -- see pageFingerprint.
            let fingerprintBefore = await bridge.pageFingerprint()
            // AND WHICH ELEMENT THIS WAS, in terms that survive the next DOM walk. Resolved here, before
            // the click, because afterwards the snapshot may no longer hold the node. Pure cache read --
            // see PageToolReceipt.
            let selectorNote = PageToolReceipt.selectorNote(alohaId: alohaId, tab: resolved.cdpTab)
            // AND WHAT THE CONTROL SAYS ABOUT ITSELF. A toggle changes its own label or an ARIA flag
            // and nothing else -- same document, same element count, same URL -- so every other
            // signal on this path reports "nothing happened" about a click that worked. See
            // ControlStateChange.
            let stateBefore = await bridge.controlState(alohaId: alohaId)
            // WHAT IS TYPED INTO THIS FORM, so that submitting the identical form twice can be
            // refused -- see SubmittedForms for the seven-of-fifteen measurement. GATED ON HAVING
            // BEEN TYPED INTO: this is the hottest path in a run, and reading the form on every
            // click timed out 25 of 99 attempts at concurrency 16 (median wall 382 s against 126 s).
            // A duplicate submission needs a filled form, and a filled form needs a page_type on
            // that tab, so the gate cannot miss a case the check could have caught.
            // ...OR the clicked control is a submit control inside a form. That is the read's other
            // trigger, for forms nothing typed into -- select-only, pre-populated, checkbox actions,
            // browser-restored values -- and it costs nothing extra: the control-state probe above
            // already reports both facts.
            let scope = context.sessionId
            let submitsAForm = stateBefore?.inForm == true && stateBefore?.submits == true
            let valuesBefore = (submittedForms.hasTyped(resolved.tab.id, scope: scope) || submitsAForm)
                ? (await bridge.formValues() ?? "") : ""
            let submitKey = valuesBefore.isEmpty
                ? "" : submissionKey(pageURL: urlBefore, values: valuesBefore)
            if !submitKey.isEmpty,
               let refusal = duplicateSubmitRefusal(alreadyAt: submittedForms.result(for: submitKey, scope: scope)) {
                // Named like every other resolved return: a refused click still happened on a page.
                return resolved.tab.naming(RawToolResult(output: refusal, isError: true))
            }
            // POLICY: NO NEW COOKIES. A click aimed at a consent prompt's own control -- Accept,
            // Reject, Manage -- is not delivered. The prompt is hidden instead and the receipt says
            // so, with the fresh page attached so the model sees the site without the banner.
            // Not an error: the model wanted past the prompt, and it is past it. See
            // hideConsentLayerContaining.
            if let refusal = await bridge.hideConsentLayerContaining(alohaId: alohaId) {
                let receipt = RawToolResult(output: refusal + selectorNote)
                return resolved.tab.naming(await withPageSnapshot(receipt, context, resolved))
            }
            // BEFORE THE CLICK: if a consent banner or a promo layer covers the target, hide it
            // without answering it, so the mouse event below reaches the element rather than the
            // layer. Nil when nothing covered the target. See hideCoveringOverlay.
            let overlayNote = await bridge.hideCoveringOverlay(alohaId: alohaId)
            // .inline, NOT the default. The script is built above from a typed click_type and a
            // quoted aloha-id -- there is no model-authored code in it -- so it does not need the
            // page to compile a string, and asking the page to do that is what a strict CSP refuses.
            // Measured: 19 WebArena rows died on "Refused to evaluate a string as JavaScript ...
            // 'unsafe-eval'", every one of them on reddit, whose Postmill ships
            // script-src 'self' 'unsafe-inline'.
            let result = await bridge.executeAgentCode(script, compile: .inline)
            // AFTER the page has had a bounded chance to move. Read straight away this was the URL
            // before the navigation committed, so the receipt asserted "did NOT navigate" about a page
            // that was navigating -- 190 of 702 such receipts were false on the 158-task preset.
            // ONLY WHEN THE CLICK LANDED: interpret returns before it looks at either URL on all
            // three failure paths, and the settle costs the WHOLE grace window whenever the page does
            // not move, which is what a failed click always does.
            let clickLanded = !result.isError
                && (result.pendingResults.first(where: { $0.type == route.pendingType })?.success ?? false)
            let urlAfter = clickLanded ? await bridge.settledPageURL(after: urlBefore) : urlBefore
            // A CLICK THAT MOVED THE PAGE off a filled-in form is what a submission looks like from
            // here. Recorded only then: a click that changed nothing submitted nothing, and recording
            // it would refuse the retry that is supposed to follow.
            if !submitKey.isEmpty, clickLanded, urlAfter != urlBefore {
                submittedForms.record(submitKey, landedOn: urlAfter, scope: scope)
            }
            var receipt = Self.interpret(result, route: route, alohaId: alohaId, clickType: clickType,
                                         urlBefore: urlBefore, urlAfter: urlAfter,
                                         selectorNote: selectorNote)
            // SAY WHAT WAS HIDDEN, on every path: the model must learn the layer is gone (so it does
            // not go looking for it) and that no consent was given on the user's behalf.
            if let overlayNote { receipt.output += overlayNote }
            // THE ID MAY BE ALIVE ONE TAB OVER. "not found" tells the model to re-read the page, which
            // is right for a stale id and useless when the element is simply on a tab this tool did
            // not act on. Only on the failure path, so a working click pays nothing.
            if receipt.isError == true, receipt.output.contains("not found"),
               let elsewhere = otherTabNote(alohaId, context, excluding: resolved.tab.id) {
                receipt = RawToolResult(output: receipt.output + elsewhere, isError: true)
            }
            // A click that LANDED and moved nothing is the case worth explaining: either the control
            // itself changed, or something is covering the element, or a form refused to submit --
            // and none of that is visible in the page the model gets back. Only on that path.
            //
            // ORDER MATTERS BETWEEN THE TWO PROBES. If the control moved, the click did its job, and
            // the obstruction note -- which would go on to report that a form is currently invalid --
            // would be a second, contradicting answer to a question already settled.
            if clickLanded, urlAfter == urlBefore {
                let stateAfter = await bridge.controlState(alohaId: alohaId)
                if let changed = ControlStateChange.note(from: stateBefore, to: stateAfter) {
                    receipt.output += changed
                } else if let why = await bridge.clickObstructionNote(alohaId: alohaId) {
                    receipt.output += why
                }
            }
            // THE PAGE THE NEXT ACTION MUST USE, in this result, when the click changed it -- and the
            // mark that tells a host so. Stamped AFTER naming, which skips a result that already
            // carries metadata. See withPageSnapshot and PageStructureChange.
            let fingerprintAfter = await bridge.pageFingerprint()
            let pageMoved = AgentBrowserBridge.pageMoved(before: fingerprintBefore, after: fingerprintAfter)
            return PageStructureChange.stamp(
                resolved.tab.naming(
                    await withPageSnapshot(receipt, context, resolved, changed: pageMoved)),
                moved: pageMoved)
        }
    }

    /// `pendingType` is the `PendingResult.type` the call enqueues under — the case name in
    /// `PageBridge.swift`'s `handlePendingRequest` switch.
    struct ClickRoute: Equatable {
        let call: String
        let pendingType: String
    }

    static func route(for clickType: String) -> ClickRoute? {
        switch clickType {
        case "single": return ClickRoute(call: "click", pendingType: "click")
        case "double": return ClickRoute(call: "doubleClick", pendingType: "doubleClick")
        case "triple": return ClickRoute(call: "tripleClick", pendingType: "tripleClick")
        case "right": return ClickRoute(call: "rightClick", pendingType: "rightClick")
        default: return nil
        }
    }

    /// The pending click op's own success/failure decides the outcome — file-input refusal
    /// included — because `executeAgentCode` stays `isError: false` even when an individual
    /// drained pending op failed.
    static func interpret(_ result: AgentActionResult, route: ClickRoute, alohaId: String, clickType: String,
                          urlBefore: String = "", urlAfter: String = "",
                          selectorNote: String = "") -> RawToolResult {
        if result.isError {
            return RawToolResult(output: result.output, isError: true)
        }
        guard let pending = result.pendingResults.first(where: { $0.type == route.pendingType }) else {
            return RawToolResult(output: "page_click failed: no click was dispatched for element \"\(alohaId)\".", isError: true)
        }
        if !pending.success {
            return RawToolResult(output: pending.error ?? "page_click failed.", isError: true)
        }
        return RawToolResult(
            output: "Clicked element \"\(alohaId)\" (\(clickType))."
                + PageDelta.describe(urlBefore: urlBefore, urlAfter: urlAfter)
                + selectorNote,
            isError: nil)
    }
}
