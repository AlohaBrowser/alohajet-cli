import Foundation
import ToolABI

// MARK: - The browser tool set

/// The ordered names of the eight tools this package exposes.
///
/// The order is the advertising order — ``getNativeAgentToolSchemas()`` maps over
/// this list, so it is also the order a `tools/list` response comes back in.
/// `manage_tabs` leads because it is the only one that can produce the aloha-ids
/// the other seven address.
public let nativeAgentToolNames: [String] = [
    "manage_tabs",
    "page_click",
    "page_type",
    "page_select",
    "get_text",
    "page_navigate",
    "page_press_keys",
    "page_wait_for"
]

/// The tool objects, in ``nativeAgentToolNames`` order.
///
/// The tools read everything they need off the `ToolExecutionContext` they are
/// handed at call time (`context.services`), so nothing is injected here and the
/// list is a literal. It is deliberately eight and not more: the verbs the
/// underlying bridge exposes are a superset, and each one added is a permanent
/// public surface.
public func getNativeAgentTools() -> [ExecutorTool] {
    [
        ManageTabsExecutorTool(),
        PageClickExecutorTool(),
        PageTypeExecutorTool(),
        PageSelectExecutorTool(),
        GetTextExecutorTool(),
        PageNavigateExecutorTool(),
        PagePressKeysExecutorTool(),
        PageWaitForExecutorTool()
    ]
}
