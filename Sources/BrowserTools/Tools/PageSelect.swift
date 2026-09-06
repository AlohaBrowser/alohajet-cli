import Foundation
import ToolABI

// MARK: - page_select executor tool

/// The executable `page_select` tool: selects an option in a `<select>`
/// dropdown on the active tab by its `aloha_id`, matching by visible `text`
/// and/or `index`.
///
/// NEW invocation path: `window.__aloha.select()` (see
/// `InpageScripts.swift`) has no `handlePendingRequest` / CDP `Input.*`
/// case to wrap — it mutates the `<select>` element's value directly in-page
/// and dispatches `input`/`change` events itself, so no host-side dispatch is
/// needed. This tool drives the narrow ``AgentBrowserBridge/selectOptionById(_:text:index:)``
/// driver method, which evaluates ONE fixed, Swift-constructed
/// `window.__aloha.select(...)` call over `Runtime.evaluate`. The call text is
/// built here in Swift; no caller-authored code reaches the page.
@MainActor public final class PageSelectExecutorTool: ExecutorTool {
    public let name = "page_select"

    public init() {}

    public func execute(_ input: WorkflowValue?, _ context: ToolExecutionContext) async throws -> RawToolResult {
        guard let alohaId = PageToolInput.string(input, "aloha_id"), !alohaId.isEmpty else {
            return RawToolResult(output: "page_select requires an \"aloha_id\" naming the <select> element.", isError: true)
        }
        let text = PageToolInput.string(input, "text")
        // `Int($0)` TRAPPED on an `index` too large for `Int` (`1e300` is a legal JSON number).
        // Unlike `get_text`'s cap this is an ADDRESS, so a value that cannot be one is refused by
        // name rather than clamped to an option the caller never asked for.
        let indexInput = PageToolInput.number(input, "index")
        let index = indexInput.flatMap { Int(exactly: $0.rounded()) }
        if indexInput != nil, index == nil {
            return RawToolResult(
                output: "page_select \"index\" must be a whole option number, got \(indexInput!).",
                isError: true)
        }
        guard text != nil || index != nil else {
            return RawToolResult(
                output: "page_select requires at least one of \"text\" or \"index\" to identify the option to select.",
                isError: true)
        }

        switch await resolveActivePageTab(name, context) {
        case let .failure(errorResult):
            return errorResult
        case let .success(resolved):
            let bridge = makePageBridge(resolved.cdpTab, context.signal)
            // Two backend URL reads bracket the action so the receipt can say whether the
            // page moved — see PageDelta, and the 44-row blind-receipt measurement behind it.
            let urlBefore = bridge.currentPageURL()
            // Which element this was, in replayable terms — before the action, since selecting an option
            // commonly re-renders dependent controls. See `PageToolReceipt`.
            let selectorNote = PageToolReceipt.selectorNote(alohaId: alohaId, tab: resolved.cdpTab)
            let result = await bridge.selectOptionById(alohaId, text: text, index: index)
            // Settled, not immediate. A select that fires an onchange navigation — Magento's
            // sort-order and page-size controls both do — commits after this line, so an immediate
            // read names the page the select just left.
            //
            // ONLY WHEN THE SELECT LANDED. The error branch below discards `urlAfter` entirely, and
            // the settle costs the WHOLE grace window whenever the page does not move — which is
            // exactly what a rejected id or a missing option does. Polling first would add that
            // window to every failed call for a value nothing reads.
            let urlAfter = result.isError ? urlBefore
                                          : await bridge.settledPageURL(after: urlBefore)
            return resolved.tab.naming(RawToolResult(
                output: result.isError ? result.output
                    : result.output + PageDelta.describe(urlBefore: urlBefore, urlAfter: urlAfter)
                        + selectorNote,
                isError: result.isError ? true : nil))
        }
    }
}
