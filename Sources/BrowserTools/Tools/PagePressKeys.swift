import Foundation
import ToolABI

/// The executable `page_press_keys` tool: sends a key or chord (e.g. `"Enter"`,
/// `"Control+a"`) to whatever currently has focus on the active tab. Focus-relative and
/// global — no `aloha_id`.
///
/// `AgentBrowserBridge.pressKeys` parses the chord and dispatches the CDP
/// `Input.dispatchKeyEvent` sequence itself, so this tool calls it straight, with no
/// in-page round trip through `executeAgentCode`.
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
