import Foundation
import ToolABI

// Tab-addressing decision, applying to all seven atomic page_* / get_text tools: they are
// single-page INTERACTION primitives, not a tab MANAGEMENT surface like `manage_tabs`,
// which takes an explicit `tab_id` because it addresses ANY tab by identity. These operate
// on "the page in front of the agent right now". Structurally, the mechanism they wrap
// (`AgentBrowserBridge` / the in-page `window.__aloha` runtime) is ALSO single-tab: it is
// constructed against one concrete `CDPTabHandle` at a time, with no multi-tab addressing
// built in. So: no tab-id parameter.

struct ResolvedPageTab {
    let tab: TabHandle
    let cdpTab: CDPTabHandle
}

/// A plain `enum` rather than `Result<_, Error>` — the failure case is already a finished,
/// user-facing ``RawToolResult``, not a `Swift.Error` to further translate.
enum ResolvePageTabOutcome {
    case success(ResolvedPageTab)
    case failure(RawToolResult)
}

/// THE active-tab chain for the seven atomic page tools, which must never name
/// different pages in one turn. Session store first, so an in-turn
/// `manage_tabs use` outranks the foreground pin `pinForegroundTab` writes.
func activeTabIdForPageTools(_ session: ChatModeSession?, _ tabsWindow: TabsWindow) -> String? {
    session?.getActiveBrowserTabId() ?? tabsWindow.tabs.activeTabId
}

/// Falls back to adopting a live page target on a miss. `nil` when nothing live carries the
/// id — which is what keeps a typo a failure.
func resolveOrAdoptTab(_ id: String, _ tabs: TabsModel) async -> TabHandle? {
    if let tracked = tabs.getOrRestoreTab(id, restoreIfNeeded: false) { return tracked }
    return await (tabs as? LivePageTargetAdopting)?.adoptLiveTarget(id)
}

/// `requireReady` is true for click/type/read (the DOM must be live). It is
/// false for `page_navigate` goto: a tab whose renderer is asleep fails `wake`
/// with "operation exceeded deadline" and would then never `Page.navigate`.
/// Navigation can revive a sleeping renderer, so goto does not gate on wake.
///
/// `requireValidUrl` is the SECURITY BOUNDARY for the six content tools
/// (click/type/select/get_text/press_keys/wait_for): they read or act on the
/// page in front of the agent, so the tab's own URL must pass the same
/// `validateTabUrl` gate `manage_tabs read`/`use` run — otherwise a `file://`
/// (or any non-http) tab the model never opened is readable through them, and
/// `page_wait_for` alone is a blind content oracle over local files. It is
/// `false` only for `page_navigate`, which does not read the current page: goto
/// validates its DESTINATION separately and must be able to leave `about:blank`
/// or a file tab, and back is pure history navigation.
func resolveActivePageTab(
    _ toolName: String,
    _ context: ToolExecutionContext,
    requireReady: Bool = true,
    requireValidUrl: Bool = true
) async -> ResolvePageTabOutcome {
    guard let tabsWindow = context.services?.tabsService?.window else {
        return .failure(RawToolResult(output: "\(toolName) failed: the tabs service is not available.", isError: true))
    }
    guard let activeTabId = activeTabIdForPageTools(context.services?.session, tabsWindow) else {
        return .failure(RawToolResult(
            output: "\(toolName) failed: no active browser tab. Take one first (manage_tabs action \"use\", or open one).",
            isError: true))
    }
    guard let tab = await resolveOrAdoptTab(activeTabId, tabsWindow.tabs) else {
        return .failure(RawToolResult(output: "\(toolName) failed: active tab \"\(activeTabId)\" was not found.", isError: true))
    }
    if requireValidUrl, case let .rejected(reason) = validateTabUrl(TabUrlInput(url: tab.url)) {
        return .failure(RawToolResult(output: reason, isError: true))
    }
    if requireReady {
        do {
            let wake = try await tab.wake(context.signal)
            guard wake.ok else {
                return .failure(RawToolResult(
                    output: "\(toolName) failed: tab \"\(activeTabId)\" is unavailable (\(wake.message ?? "could not wake")).",
                    isError: true))
            }
        } catch {
            return .failure(RawToolResult(output: "\(toolName) failed: tab \"\(activeTabId)\" could not wake: \(error).", isError: true))
        }
    }
    guard let cdpTab = tab as? CDPTabHandle else {
        return .failure(RawToolResult(output: "\(toolName) failed: the active tab is not an interactive website tab.", isError: true))
    }
    return .success(ResolvedPageTab(tab: tab, cdpTab: cdpTab))
}

func makePageBridge(_ cdpTab: CDPTabHandle, _ signal: AbortSignal) -> AgentBrowserBridge {
    AgentBrowserBridge(backend: CDPAgentBridgeBackend(tab: cdpTab, signal: signal))
}

/// A caller-supplied `Double` as an `Int`, saturating instead of trapping.
///
/// `Int(_:)` traps on `NaN` and on anything outside `Int`'s range, and JSON has no trouble
/// carrying either to a tool argument — so every numeric parameter that becomes an `Int`
/// goes through this or through `Int(exactly:)`. `NaN` has no ordering and no size, so it
/// reads as 0 and the caller's own lower bound takes over.
func intSaturating(_ value: Double) -> Int {
    if value.isNaN { return 0 }
    if value >= Double(Int.max) { return .max }
    if value <= Double(Int.min) { return .min }
    return Int(value)
}

enum PageToolInput {
    static func string(_ input: WorkflowValue?, _ key: String) -> String? {
        guard case let .object(fields)? = input, case let .string(value)? = fields[key] else { return nil }
        return value
    }

    static func bool(_ input: WorkflowValue?, _ key: String) -> Bool? {
        guard case let .object(fields)? = input, case let .bool(value)? = fields[key] else { return nil }
        return value
    }

    static func number(_ input: WorkflowValue?, _ key: String) -> Double? {
        guard case let .object(fields)? = input, case let .number(value)? = fields[key] else { return nil }
        return value
    }

    /// Elements come back as `WorkflowValue`s so the `string`/`bool` readers above work on
    /// each one unchanged.
    static func array(_ input: WorkflowValue?, _ key: String) -> [WorkflowValue]? {
        guard case let .object(fields)? = input, case let .array(items)? = fields[key] else { return nil }
        return items
    }
}

// WHY THE DURABLE SELECTOR EXISTS. An `aloha_id` is a hash — of an authored name or of a frame-scoped xpath — so it
// is stable across walks of the same page and still useless to anyone reading the transcript
// afterwards: there is no page to resolve it against and no way to recompute it. The receipt records
// WHICH handle was clicked and nothing about which element that was.
//
// The derivation already existed (`StepTraceSelector`), and `CDPTabHandle.traceDomNode` is a pure read
// of the DOM service's most recent snapshot — no CDP round-trip, no re-extraction.
//
// APPENDED, NEVER SUBSTITUTED, so a parser keyed on the leading receipt text is unaffected. The id
// stays in the receipt because it is what the caller must reuse this turn; the selector is for whoever
// reads the transcript afterwards.
enum PageToolReceipt {

    /// ` [selector=#search-input]`, or `""` when nothing durable can be derived.
    ///
    /// Resolve this BEFORE the action runs: after a click the snapshot may no longer hold the node, and
    /// a selector derived from the post-action DOM would describe a different element.
    static func selectorNote(alohaId: String, tab: StepTraceTab?) -> String {
        guard let selector = durableSelector(alohaId: alohaId, tab: tab) else { return "" }
        return " [selector=\(selector)]"
    }

    /// `nil` at every gap — no tab, unknown id, or nothing stable on the node. Best-effort by
    /// contract: a guessed selector is worse than none, because a script replayed against one
    /// fails silently.
    static func durableSelector(alohaId: String, tab: StepTraceTab?) -> String? {
        guard let tab, !alohaId.isEmpty, let node = tab.traceDomNode(forAlohaId: alohaId) else { return nil }
        return stableCSSSelector(for: node)
    }
}

extension TabHandle {
    /// Stamps the page this call acted on onto the result, read off the LIVE tab
    /// handle at return time so a navigation names where it landed.
    ///
    /// These tools are dispatched with an `aloha_id` and nothing else — a handle
    /// into a DOM, which names no page anybody has seen — so without this the
    /// only identity a `page_click` could offer is the call itself, and a bucket
    /// counting pages counted clicks. Carried the way `manage_tabs` carries it:
    /// on the result's `metadata`, which reaches no model.
    ///
    /// A call that FAILED still happened on a page, and the runtime knows which:
    /// three failed clicks on one page are one page, not three. Everything the
    /// failure already communicates — its output, its error flag, and so the failed
    /// tense its row prints — is untouched; only the page rides along.
    func naming(_ result: RawToolResult) -> RawToolResult {
        guard result.metadata == nil else { return result }
        let identity = AgentTabIdentity(
            tabId: id,
            title: title?.isEmpty == false ? title : nil,
            url: url.isEmpty ? nil : url)
        var named = result
        named.metadata = identity.metadata.isEmpty ? nil : identity.metadata
        return named
    }
}
