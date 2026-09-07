import Foundation
import ToolABI

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

/// In ``nativeAgentToolNames`` order. Deliberately eight and not more: the verbs the
/// underlying bridge exposes are a superset, and each one added is a permanent public
/// surface.
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
