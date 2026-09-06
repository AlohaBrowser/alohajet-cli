import Foundation
import ToolABI

// MARK: - page_press_keys executor tool

/// The executable `page_press_keys` tool: sends a keyboard key or chord (e.g.
/// `"Enter"`, `"Escape"`, `"Control+a"`) to whatever currently has focus on the
/// active tab. Global and focus-relative — no `aloha_id`, matching the
/// underlying `pressKeys` signature exactly.
///
/// Wraps `PageBridge.swift`'s `pressKeys` case directly: it is a thin
/// `handlePendingRequest` wrapper around the PUBLIC `AgentBrowserBridge.pressKeys`
/// method, which parses the chord and dispatches real CDP `Input.dispatchKeyEvent`
/// sequences itself — no in-page `enqueueCdp` round trip needed, so this tool
/// calls it straight, without `executeAgentCode`.
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
            let result = await bridge.pressKeys(keys)
            return resolved.tab.naming(RawToolResult(output: result.output, isError: result.isError ? true : nil))
        }
    }
}
