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
func activeTabIdForPageTools(_ context: ToolExecutionContext, _ tabsWindow: TabsWindow) -> String? {
    context.services?.session?.getActiveBrowserTabId()
        ?? tabsWindow.tabs.activeTabId
        ?? tabsWindow.tabs.orderedTabs.first?.id
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
    guard let activeTabId = activeTabIdForPageTools(context, tabsWindow) else {
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

// MARK: - The id is on another tab

/// THE ID THE MODEL PASSED IS ON A TAB THIS TOOL DID NOT ACT ON. The page tools act on the
/// focused tab; the model's context holds the pages of EVERY tab it has read. An id from a
/// background tab is therefore live and correct, and a tool that answers "not found, re-read the
/// page" sends the model to re-read a page that already has the id. Measured on
/// AlohaBrowser/alohajet run 33889241270: 40% of "not found" ids were in the very observation
/// the model was reading, on a tab other than the focused one; 260 opens produced 260 distinct
/// tabs and 123 of them (47%) were for a URL already open, so the agent manufactures the
/// ambiguity that then breaks its clicks.
///
/// DIAGNOSIS ONLY, on purpose. This never changes which tab an action lands on. Acting on the
/// owning tab would silently move a write to a page the model did not focus, which on a task with
/// two tabs of the same site is a worse failure than the one it fixes. Say where the element is;
/// let the model decide.
///
/// Costs nothing on the happy path: it runs only after a tool has already failed, and
/// `traceDomNode` reads each tab's CACHED snapshot -- no CDP round-trip, no DOM re-extraction.
func tabHoldingAlohaId(_ alohaId: String, _ context: ToolExecutionContext,
                       excluding activeTabId: String?) -> TabHandle? {
    guard !alohaId.isEmpty,
          let tabsWindow = context.services?.tabsService?.window else { return nil }
    for tab in tabsWindow.tabs.orderedTabs {
        if tab.id == activeTabId { continue }
        guard let traced = tab as? StepTraceTab else { continue }
        if traced.traceDomNode(forAlohaId: alohaId) != nil { return tab }
    }
    return nil
}

/// The sentence to append to a failed page-tool receipt, or nil when no other tab has the id.
///
/// Names the tab id, because that is the argument the model needs to act on it -- a title alone
/// would tell it where the element is and leave it unable to say so.
func otherTabNote(_ alohaId: String, _ context: ToolExecutionContext,
                  excluding activeTabId: String?) -> String? {
    guard let tab = tabHoldingAlohaId(alohaId, context, excluding: activeTabId) else { return nil }
    let title = (tab.title?.isEmpty == false) ? " (\"\(tab.title ?? "")\")" : ""
    return " That id IS on another OPEN tab: \(tab.id)\(title). It is not stale — this tool acted"
        + " on the focused tab, which is a different page. Focus that tab (manage_tabs action"
        + " \"focus\") and repeat this call, or act on an id from the focused tab instead."
}

// MARK: - The page an action left behind

/// EVERY ACTION RETURNS THE PAGE IT LEFT BEHIND. Appends the post-action page to a finished
/// receipt, or returns the receipt untouched.
///
/// WHY. A receipt alone -- `Clicked element "2s" (single).` -- tells the model nothing about what
/// the click did to the page, so it has to spend a round on `manage_tabs read` before it can act
/// again, and when it does not it acts on ids from the page BEFORE the click. Measured on WebArena
/// run 34366647873 over 579 `page_type` calls: 36% came back with a page and 39% with a bare
/// receipt, against 65% for `page_click`; "answered without looking" was 64 of 199 answer turns.
/// The same `manageTabsRead` the `read` action calls, with the same extraction options, so the two
/// cannot disagree about what "the page" is. No screenshot: this fires on every action, and the
/// model needs the ids, which are in the markdown.
///
/// NOTHING MOVED, NOTHING TO SEND. A page identical to the one the model already holds costs a DOM
/// walk here and, far worse, rides in its context for every remaining round: deep in a task that
/// reached 33k tokens against 27k before this existed, and the run's timeouts were 76-92 LLM
/// rounds at a 5-6.3 s median. `changed` comes from `AgentBrowserBridge.pageFingerprint`, which
/// moves exactly when the ids do; an unreadable fingerprint counts as changed, so a snapshot is
/// never lost to a failed probe. `page_type` passes the default `true`: a typed value moves no
/// fingerprint, and for a type the value IS the change worth confirming.
///
/// An errored receipt is returned as-is: the action did not happen, so the page did not change,
/// and a failure is not the place to spend a DOM walk. A snapshot is an addition to a receipt,
/// never a reason to fail one: a read that cannot be taken leaves the receipt alone.
func withPageSnapshot(_ receipt: RawToolResult, _ context: ToolExecutionContext,
                      _ resolved: ResolvedPageTab, changed: Bool = true) async -> RawToolResult {
    guard receipt.isError != true else { return receipt }
    guard changed else { return receipt }
    guard let page = await postActionPageSnapshot(context, tabId: resolved.tab.id) else { return receipt }
    // Mutate a copy rather than build a fresh result: `RawToolResult` carries status, metadata,
    // llmAttrs, format and outputSchema too, and a receipt that set any of them would lose it.
    var enriched = receipt
    enriched.output = receipt.output + "\n" + page
    return enriched
}

/// The page as `manage_tabs read` would render it, or nil when the tab cannot be read.
func postActionPageSnapshot(_ context: ToolExecutionContext, tabId: String) async -> String? {
    guard let tabsWindow = context.services?.tabsService?.window,
          let session = context.services?.session else { return nil }
    let ctx = ManageTabsActionContext(
        sessionId: context.sessionId,
        toolCallId: context.toolCallId,
        session: session,
        abortSignal: context.signal,
        webExtractionOptions: context.services?.webExtractionOptions ?? .baseline)
    let read = await manageTabsRead(tabId, tabsWindow, ctx, false)
    guard !read.isError, let body = read.output,
          !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return body
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
