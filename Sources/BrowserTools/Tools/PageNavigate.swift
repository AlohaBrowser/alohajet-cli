import Foundation
import ToolABI

/// The executable `page_navigate` tool: navigates the active tab's current page IN PLACE.
/// Distinct from `manage_tabs`' "open" action, which always allocates a brand-new tab;
/// this tool never creates a tab, it only moves the existing active one.
///
/// `AgentBrowserBridge.goto` / `.back` drive navigation over the backend's own seam
/// (pacing, load + readiness waits), so this tool calls them straight, without
/// `executeAgentCode`.
///
/// Every URL it navigates to passes ``validateOpenUrl(_:)`` first — see the note on the
/// `goto` branch.
@MainActor public final class PageNavigateExecutorTool: ExecutorTool {
    public let name = "page_navigate"

    public init() {}

    public func execute(_ input: WorkflowValue?, _ context: ToolExecutionContext) async throws -> RawToolResult {
        let action = PageToolInput.string(input, "action") ?? ""
        let url = PageToolInput.string(input, "url")

        switch action {
        case "goto":
            guard let url, !url.isEmpty else {
                return RawToolResult(output: "page_navigate requires \"url\" when action is \"goto\".", isError: true)
            }
            // THE SAME VALIDATION EVERY OTHER NAVIGATION ENTRY POINT RUNS. This one
            // used to skip it, and `Page.navigate` from a real (already-loaded) tab to
            // `file:///…` succeeds — so goto followed by get_text was a working
            // local-file read, reachable by prompt injection because a hostile page's
            // text is already in context when the next call is chosen. Navigate to the
            // NORMALIZED href the validator returns, not the raw argument.
            let normalized: String
            switch validateOpenUrl(url) {
            case let .ok(value):
                normalized = value
            case let .rejected(reason):
                return RawToolResult(output: reason, isError: true)
            }
            // Do not wait on wake: a tab whose renderer is asleep hangs
            // Runtime.evaluate, and a failed wake used to skip Page.navigate.
            // Goto attaches itself (ensureAttached + Page.navigate) and can
            // revive a sleeping renderer. Click/type/read and "back" still wake.
            return await Self.dispatch(name, context, requireReady: false) { bridge in await bridge.goto(normalized) }
        case "back":
            // A passed url is ignored, not an error: the underlying `back` case takes no
            // url argument at all.
            return await Self.dispatch(name, context) { bridge in await bridge.back() }
        default:
            return RawToolResult(
                output: "page_navigate: unknown action \"\(action)\"; expected \"goto\" or \"back\".",
                isError: true)
        }
    }

    private static func dispatch(
        _ toolName: String,
        _ context: ToolExecutionContext,
        requireReady: Bool = true,
        _ operation: (AgentBrowserBridge) async -> AgentActionResult
    ) async -> RawToolResult {
        // page_navigate does not READ the current page: goto validates its own
        // destination and must be able to leave about:blank or a file tab, and
        // back is pure history navigation. So it opts out of the current-tab URL
        // gate the six content tools enforce.
        switch await resolveActivePageTab(toolName, context, requireReady: requireReady, requireValidUrl: false) {
        case let .failure(errorResult):
            return errorResult
        case let .success(resolved):
            let bridge = makePageBridge(resolved.cdpTab, context.signal)
            let result = await operation(bridge)
            return resolved.tab.naming(RawToolResult(output: result.output, isError: result.isError ? true : nil))
        }
    }
}
