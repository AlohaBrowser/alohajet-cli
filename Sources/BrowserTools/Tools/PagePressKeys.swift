import Foundation
import ToolABI

/// The executable `page_press_keys` tool: sends a key or chord (e.g. `"Enter"`,
/// `"Control+a"`) to whatever currently has focus on the active tab. Focus-relative and
/// global — no `aloha_id`.
///
/// `AgentBrowserBridge.pressKeys` parses the chord and dispatches the CDP
/// `Input.dispatchKeyEvent` sequence itself, so this tool calls it straight, with no
/// in-page round trip through `executeAgentCode`.
///
/// THE RECEIPT SAYS WHAT THE KEYS WENT INTO. Until 2026-09-23 it was the one write receipt
/// that named no element: `Keys "Enter" sent successfully`, whatever had focus and whatever
/// the page did next. Agent run osm-route-r12 (2026-09-22): the agent typed From and To into
/// OpenStreetMap's directions form and pressed Enter as its own step; the route was computed
/// and the run was right, but the mint had no receipt selector for the submit, invented
/// `form[action="/directions"]`, and its own guard refused the scenario. Now the receipt
/// carries what every other write receipt carries -- the focused element (read BEFORE the
/// keys, since a submit can replace the page), its durable selector and identity, the page
/// delta -- plus `[submitted=enter]` when a plain Enter went into an element, the same token
/// `page_type` writes on its submit path. Nothing here knows the site or the task.
@MainActor public final class PagePressKeysExecutorTool: ExecutorTool {
    public let name = "page_press_keys"

    public init() {}

    public func execute(_ input: WorkflowValue?, _ context: ToolExecutionContext) async throws -> RawToolResult {
        guard let keys = PageToolInput.string(input, "keys"), !keys.isEmpty else {
            return RawToolResult(output: "page_press_keys requires a non-empty \"keys\" string (e.g. \"Enter\", \"Control+a\").", isError: true)
        }

        switch await resolveActivePageTab(name, context) {
        case let .failure(errorResult):
            return errorResult
        case let .success(resolved):
            let bridge = makePageBridge(resolved.cdpTab, context.signal)
            // Two URL reads bracket the action so the receipt can say whether the page moved.
            let urlBefore = bridge.currentPageURL()
            // Which element the keys go into, in replayable terms, resolved BEFORE the keys: a
            // submit can replace the whole document, and the focused node with it.
            let focused = await bridge.focusedElementAlohaId()
            var selectorNote = ""
            if let focused {
                selectorNote = await PageToolReceipt.liveNote(alohaId: focused, tab: resolved.cdpTab, bridge: bridge, tool: "page_press_keys")
            }
            let result = await bridge.pressKeys(keys)
            if result.isError {
                return resolved.tab.naming(RawToolResult(output: result.output, isError: true))
            }
            let urlAfter = await bridge.settledPageURL(after: urlBefore)
            return resolved.tab.naming(RawToolResult(
                output: Self.receipt(keys: keys, focusedAlohaId: focused, urlBefore: urlBefore, urlAfter: urlAfter, selectorNote: selectorNote),
                isError: nil))
        }
    }

    /// The receipt line, from what was read around the key press. Pure, so a test can hold it
    /// to the shape without a browser.
    static func receipt(keys: String, focusedAlohaId: String?, urlBefore: String, urlAfter: String, selectorNote: String) -> String {
        let target = focusedAlohaId.map { " in element \"\($0)\"" } ?? " (nothing on the page had focus)"
        let submitted = focusedAlohaId != nil && submitsForm(keys) ? PageToolReceipt.submittedNote : ""
        return "Pressed \"\(keys)\"\(target)."
            + PageDelta.describe(urlBefore: urlBefore, urlAfter: urlAfter)
            + (focusedAlohaId == nil ? "" : selectorNote)
            + submitted
    }

    /// Does this chord sequence END in a plain Enter? That is the key press that submits the
    /// focused field's form. `Shift+Enter` (a newline in a textarea), `Escape`, `Tab` and
    /// modifier chords do not submit and get no token.
    static func submitsForm(_ keys: String) -> Bool {
        let chords = keys.split(whereSeparator: { $0 == " " || $0 == "," }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let last = chords.last else { return false }
        return last.caseInsensitiveCompare("enter") == .orderedSame || last.caseInsensitiveCompare("return") == .orderedSame
    }
}
