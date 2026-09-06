import Foundation
import ToolABI

// MARK: - page_wait_for executor tool

/// The executable `page_wait_for` tool: polls the active tab until an element
/// matching a CSS `selector` appears, or `timeout_ms` elapses. This is the ONE
/// tool in the atomic page-tools set addressed by a raw CSS selector rather
/// than an `aloha_id` — `waitFor` has to wait for elements that do not exist
/// yet, so there is no aloha-id to reference. That is intentional, not an
/// inconsistency with the other six tools.
///
/// NEW invocation path: `window.__aloha.waitFor()` (see
/// `InpageScripts.swift`) has no `handlePendingRequest` / CDP `Input.*`
/// case to wrap — it is MutationObserver-based and resolves/rejects entirely
/// in-page, nothing to dispatch. This tool drives the narrow
/// ``AgentBrowserBridge/waitForSelector(_:timeoutMs:)`` driver method, which
/// evaluates ONE fixed, Swift-constructed `window.__aloha.waitFor(...)` call
/// over `Runtime.evaluate` — the call text is built here in Swift, no
/// caller-authored code reaches the page — preserving the MutationObserver
/// behaviour rather than reimplementing it as a blind poll/sleep loop.
@MainActor public final class PageWaitForExecutorTool: ExecutorTool {
    public let name = "page_wait_for"

    /// The default `timeout_ms` when the argument is omitted.
    static let defaultTimeoutMs: Double = 10_000

    public init() {}

    public func execute(_ input: WorkflowValue?, _ context: ToolExecutionContext) async throws -> RawToolResult {
        guard let selector = PageToolInput.string(input, "selector"), !selector.isEmpty else {
            return RawToolResult(output: "page_wait_for requires a non-empty \"selector\" (CSS selector).", isError: true)
        }
        // Cap at AgentBrowserBridge.maxWaitForTimeoutMs (30s): an over-large
        // request is CLAMPED, not rejected, so it still waits the maximum useful
        // budget instead of hard-failing the call. `waitForSelector` clamps again
        // defensively; the value is clamped here too so the tool's OWN reported
        // wait matches what actually happens.
        let requested = PageToolInput.number(input, "timeout_ms") ?? Self.defaultTimeoutMs
        let timeoutMs = min(max(requested, 0), AgentBrowserBridge.maxWaitForTimeoutMs)

        switch await resolveActivePageTab(name, context) {
        case let .failure(errorResult):
            return errorResult
        case let .success(resolved):
            let bridge = makePageBridge(resolved.cdpTab, context.signal)
            let result = await bridge.waitForSelector(selector, timeoutMs: timeoutMs)
            return resolved.tab.naming(RawToolResult(output: result.output, isError: result.isError ? true : nil))
        }
    }
}
