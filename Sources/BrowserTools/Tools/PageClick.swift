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
            // AND WHICH ELEMENT THIS WAS, in terms that survive the next DOM walk. Resolved here, before
            // the click, because afterwards the snapshot may no longer hold the node. Pure cache read —
            // see `PageToolReceipt`.
            let selectorNote = PageToolReceipt.selectorNote(alohaId: alohaId, tab: resolved.cdpTab)
            // `.inline`, NOT the default. `script` is built two lines above from a typed click_type
            // and a quoted aloha-id — there is no model-authored code in it — so it does not need the
            // page to compile a string, and asking the page to do that is what a strict CSP refuses.
            // Measured: 19 WebArena rows died on `Refused to evaluate a string as JavaScript ...
            // 'unsafe-eval'`, every one of them on reddit, whose Postmill ships
            // `script-src 'self' 'unsafe-inline'`. page_click is a core tool; this made it unusable on
            // a whole site of the corpus (and reddit is one of the four sites the official stand hosts).
            let result = await bridge.executeAgentCode(script, compile: .inline)
            // AFTER the page has had a bounded chance to move. Read straight away this was the URL
            // before the navigation committed, so the receipt asserted "did NOT navigate" about a page
            // that was navigating — 190 of 702 such receipts were false on the 158-task preset.
            //
            // ONLY WHEN THE CLICK LANDED. `interpret` returns before it looks at either URL on all
            // three failure paths — a script error, no dispatched click, and a click that reports
            // failure — and the settle costs the WHOLE grace window whenever the page does not move,
            // which is what a failed click always does. The condition below mirrors those three
            // guards rather than duplicating their messages.
            let clickLanded = !result.isError
                && (result.pendingResults.first(where: { $0.type == route.pendingType })?.success ?? false)
            let urlAfter = clickLanded ? await bridge.settledPageURL(after: urlBefore) : urlBefore
            return resolved.tab.naming(
                Self.interpret(result, route: route, alohaId: alohaId, clickType: clickType,
                               urlBefore: urlBefore, urlAfter: urlAfter, selectorNote: selectorNote))
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
        case "single": ClickRoute(call: "click", pendingType: "click")
        case "double": ClickRoute(call: "doubleClick", pendingType: "doubleClick")
        case "triple": ClickRoute(call: "tripleClick", pendingType: "tripleClick")
        case "right": ClickRoute(call: "rightClick", pendingType: "rightClick")
        default: nil
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
