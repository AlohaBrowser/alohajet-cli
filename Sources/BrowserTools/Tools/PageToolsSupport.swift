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
/// and a failure is not the place to spend a DOM walk. EXCEPT when the caller says otherwise with
/// `evenIfError` -- a `page_type` whose typing landed and whose Enter then failed has changed the
/// page, and an error that hides the page it changed leaves the model to re-read it. A snapshot is
/// an addition to a receipt, never a reason to fail one: a read that cannot be taken leaves the
/// receipt alone.
func withPageSnapshot(_ receipt: RawToolResult, _ context: ToolExecutionContext,
                      _ resolved: ResolvedPageTab, changed: Bool = true,
                      evenIfError: Bool = false) async -> RawToolResult {
    guard receipt.isError != true || evenIfError else { return receipt }
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
//
// THE BRACKETS. Every receipt a page tool writes ends in the same bracket groups, in the order
// `RECEIPTS.md` at the package root documents: `[selector=…] [tool=…] [matches=N] [index=i/N]
// [text="…"] [attrs=…] [list=<selector> i/n]`, plus `[submitted=enter]` on a type that submitted.
// A value can contain spaces and brackets, so a token ends at the `]` that closes its `[`, never
// at a space. `Tests/BrowserToolsTests/receipt_registry.js` fails when a bracket is written that
// the document does not list, or the other way round.
enum PageToolReceipt {

    /// ` [selector=#search-input]`, or `""` when nothing durable can be derived.
    ///
    /// Resolve this BEFORE the action runs: after a click the snapshot may no longer hold the node, and
    /// a selector derived from the post-action DOM would describe a different element.
    static func selectorNote(alohaId: String, tab: StepTraceTab?) -> String {
        guard let selector = durableSelector(alohaId: alohaId, tab: tab) else { return "" }
        return " [selector=\(selector)]"
    }

    /// THE WHOLE NOTE FOR AN ELEMENT, read from the LIVE page before the action: the ladder's
    /// selector (a dead position path rebuilt, see `liveSelector`), how many elements it matches,
    /// the element's own text, and its identity (index, attributes, list). One seam for every
    /// tool, so click, type, select, press_keys and get_text cannot drift into five receipts.
    /// `""` when the element has no durable selector: the note never guesses.
    static func liveNote(alohaId: String, tab: StepTraceTab?, bridge: AgentBrowserBridge, tool: String,
                         text: Bool = true) async -> String {
        guard let live = await bridge.liveSelector(durableSelector(alohaId: alohaId, tab: tab), alohaId: alohaId)
        else { return "" }
        return selectorNote(
            selector: live.selector, matches: live.matches,
            text: text ? await bridge.elementText(alohaId: alohaId) : nil,
            identity: await bridge.elementIdentity(selector: live.selector, alohaId: alohaId),
            tool: tool)
    }

    /// ` [selector=…] [matches=N]` and the rest: the durable selector AND how many elements it
    /// matched on the live page when the action ran. The count is what lets a mint decide between
    /// keeping the selector as is (one match) and anchoring it (many): `a.product-link._item`
    /// matches every card on a results page, `button.size-selector-sizes-size__button` every size.
    /// Without it the server had to reason "ask it of every click"; with it the anchor is
    /// evidence-based (agent run jacket-bag-luna-ge32: five receipts, no count on any). The count
    /// is omitted, not invented, when the page could not be asked.
    static func selectorNote(
        selector: String?, matches: Int?, text: String? = nil, identity: ElementIdentity? = nil,
        tool: String? = nil, source: String? = nil
    ) -> String {
        guard let selector else { return "" }
        var note = " [selector=\(selector)]"
        // WHO WROTE THIS RECEIPT, inside the receipt itself: `[tool=get_text]` from a tool,
        // `[source=main-heading]` for the heading line a page read carries. The result already
        // opens with `<tool_result tool="…">`, but a consumer that lifts the bracket groups out of
        // that wrapper lost it (llmdex, 2026-09-30: every receipt reached the mint as `receipt :`),
        // and could not tell a read's receipt from a click's.
        if let tool, !tool.isEmpty { note += " [tool=\(tool)]" }
        if let source, !source.isEmpty { note += " [source=\(source)]" }
        if let matches { note += " [matches=\(matches)]" }
        // WHICH of the N matches this was. Only when there were several: with one match the
        // selector already names the element, and the token would be noise on every receipt.
        // AND WHETHER IT NAMES THIS ELEMENT AT ALL. The identity probe reports no index when the
        // selector's live matches do not include the element -- the snapshot's class or id is gone
        // from it, or the selector matches nothing now and no path could be rebuilt. The address
        // is still written, and `[index=none]` marks it unverified, so a mint does not build a
        // step on it when `[list=]`, `[path=]` or `[anchor=]` offer a checked one (2026-10-04 audit).
        if let matches, let identity {
            if let index = identity.index, matches > 1, index >= 1, index <= matches {
                note += " [index=\(index)/\(matches)]"
            } else if identity.index == nil {
                note += " [index=none]"
            }
        }
        // The element's OWN words, so an anchor for a many-match selector is built from what
        // was on the element rather than from the task's phrasing (which may reorder them).
        if let text, !text.isEmpty {
            note += " [text=\"\(tokenSafe(text))\"]"
        }
        // The element's REAL attributes, as the page wrote them. A scenario replays on this one
        // site, so the receipt may be exactly as site-specific as the element: `data-qa-action`,
        // `aria-label`, `name`, `role`, `href` are all anchors the resolver can use
        // (`[attr="v"]`, `:matches-attr(...)`) and text is not the only one any more.
        if let attributes = identity?.attributes, !attributes.isEmpty {
            let pairs = attributes.map { "\($0.name)=\"\(tokenSafe($0.value))\"" }
            note += " [attrs=\(pairs.joined(separator: " "))]"
        }
        // The repeating list the element sits in, and its place there -- independent of which
        // rung won `[selector=…]`, and written only when the list has two or more members.
        if let list = identity?.list {
            note += " [list=\(list.selector) \(list.index)/\(list.count)]"
        }
        return note
    }

    /// ` [submitted=enter]`: the type call pressed Enter after typing. A mint that turns a run into
    /// a scenario reads bracketed tokens; the sentence "and pressed Enter to submit" is prose it
    /// dropped (agent run github-ss-r4, 2026-09-22: the scenario typed the query and looked for a
    /// results-page filter on the home page). Present only when a submit actually happened.
    static let submittedNote = " [submitted=enter]"

    /// A value inside a `[key=…]` token: no `"` (the token's own quote), no `]` (its close),
    /// no line breaks (the receipt is one line). A consumer tokenizes without quoting rules.
    static func tokenSafe(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "'")
            .replacingOccurrences(of: "]", with: ")")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    /// `nil` at every gap — no tab, unknown id, or nothing stable on the node. Best-effort by
    /// contract: a guessed selector is worse than none, because a script replayed against one
    /// fails silently.
    static func durableSelector(alohaId: String, tab: StepTraceTab?) -> String? {
        guard let tab, !alohaId.isEmpty, let node = tab.traceDomNode(forAlohaId: alohaId) else { return nil }
        return stableCSSSelector(for: node)
    }
}

// MARK: - The control's identity, on the same receipt

/// What the live page said about the element a page tool acted on, beyond its durable selector:
/// which of the selector's matches it was, the attributes it actually carries, and the repeating
/// list it sits in.
///
/// Why: a scenario replays on the one site it was minted from, so the receipt may be exactly as
/// site-specific as the element. Until this rode along a mint had the selector, the count and the
/// element's text -- text was the ONLY anchor, and text is fragile (localised labels, reordered
/// words: agent run jacket-bag-luna-ge34 anchored 'FAUX SUEDE BELTED JACKET' on a card that read
/// 'BELTED FAUX SUEDE JACKET'). The mechanism is general; the content is whatever the page wrote.
struct ElementIdentity: Equatable, Sendable {
    struct Attribute: Equatable, Sendable {
        let name: String
        let value: String
    }
    /// 1-based position of the element among `querySelectorAll(selector)`; nil when the selector
    /// was absent, did not parse, or did not contain the element.
    let index: Int?
    /// The element's attributes in page order, minus the ones that identify nothing
    /// (`class`, `style`, `aloha-id`, `tabindex`, event handlers, `data:` URIs) and minus a form
    /// field's `value` (user data, never identity). Values are capped at 80 characters.
    let attributes: [Attribute]
    /// WHICH ITEM OF A REPEATING LIST the element sits in: a selector that matches the same
    /// control in every item (the position path with the repeating ancestor's index dropped),
    /// and the element's 1-based place among those matches. Nil when nothing above the element
    /// repeats. It is what lets a mint say "the first result" as `list selector` + `nth`
    /// instead of the path that uniquely names today's first result.
    struct ListPosition: Equatable, Sendable {
        let selector: String
        let index: Int
        let count: Int
    }
    var list: ListPosition? = nil
}

/// One page round trip that reads an element's identity for the receipt. The expression is a
/// template (`\#(selectorLiteral)`, `\#(alohaIdLiteral)`) so a harness can run the shipped bytes
/// against a fake document: `Tests/BrowserToolsTests/receipt_identity.js` and `list_position.js`.
enum ReceiptIdentityProbe {
    /// Attributes are capped by count and by total length so a receipt stays one readable line.
    static let maxAttributes = 12
    static let maxValueLength = 80
    static let maxTotalLength = 600
    /// The longest list path emitted, in segments -- the selector ladder's own bound.
    static let maxListSegments = StepTraceSelector.maxPathSegments

    static func expression(selector: String?, alohaId: String) -> String {
        let selectorLiteral = JSValue.string(selector ?? "").stringify()
        let alohaIdLiteral = JSValue.string(alohaId).stringify()
        return #"""
        (function (sel, id) { /* receipt: identity */
          var out = { index: -1, attrs: [] };
          try {
            var el = null;
            var tagged = document.querySelectorAll('[aloha-id]');
            for (var k = 0; k < tagged.length; k++) if (tagged[k].getAttribute('aloha-id') === id) { el = tagged[k]; break; }
            if (!el) return JSON.stringify(out);
            if (sel) {
              try {
                var all = document.querySelectorAll(sel);
                for (var i = 0; i < all.length; i++) if (all[i] === el) { out.index = i + 1; break; }
              } catch (e) {}
            }
            var skip = { 'class': 1, 'style': 1, 'aloha-id': 1, 'tabindex': 1 };
            var tag = String(el.tagName || '').toUpperCase();
            var formField = tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT';
            var names = el.getAttributeNames ? el.getAttributeNames() : [];
            var total = 0;
            for (var j = 0; j < names.length && out.attrs.length < \#(maxAttributes); j++) {
              var n = names[j], ln = n.toLowerCase();
              if (skip[ln] || ln.indexOf('on') === 0) continue;
              if (ln === 'value' && formField) continue;
              var v = String(el.getAttribute(n) == null ? '' : el.getAttribute(n));
              if (v.indexOf('data:') === 0) continue;
              v = v.replace(/\s+/g, ' ').trim();
              if (v.length > \#(maxValueLength)) v = v.slice(0, \#(maxValueLength) - 3) + '...';
              total += n.length + v.length + 4;
              if (total > \#(maxTotalLength)) break;
              out.attrs.push([n, v]);
            }
            // THE LIST THE ELEMENT BELONGS TO. An ancestor-or-self with a sibling of the same tag
            // and the same class string is a repeating item; the element's position path (the
            // ladder's format: an index only where same-tag siblings exist) with ONLY that item's
            // index dropped matches the same control in every item.
            try {
              var chain = [];
              for (var cur = el; cur && cur !== document.body; cur = cur.parentElement) chain.push(cur);
              var reachedBody = chain.length > 0 && chain[chain.length - 1].parentElement === document.body;
              if (reachedBody && chain.length + 1 <= \#(maxListSegments)) {
                var segOf = function (node, bare) {
                  var t = String(node.tagName || '').toLowerCase();
                  if (!/^[a-z][a-z0-9-]*$/.test(t)) return null;
                  if (bare) return t;
                  var p = node.parentElement, same = 0, pos = 0;
                  var kids = p ? p.children : [];
                  for (var q = 0; q < kids.length; q++) if (kids[q].tagName === node.tagName) { same++; if (kids[q] === node) pos = same; }
                  return same > 1 ? t + ':nth-of-type(' + pos + ')' : t;
                };
                // Every level that repeats is a candidate list; the one with the MOST members
                // wins (nearest on a tie). The nearest alone is wrong: HN's comments link sits among
                // five sibling links in one story's subline, while the story list above it has 30.
                var best = null;
                for (var a = 0; a < chain.length; a++) {
                  var nd = chain[a], par = nd.parentElement, cls = nd.getAttribute('class') || '';
                  var kin = par ? par.children : [], repeats = false;
                  for (var b = 0; b < kin.length; b++) {
                    if (kin[b] !== nd && kin[b].tagName === nd.tagName && (kin[b].getAttribute('class') || '') === cls) { repeats = true; break; }
                  }
                  if (!repeats) continue;
                  var segs = ['body'], ok = true;
                  for (var s = chain.length - 1; s >= 0; s--) {
                    var sg = segOf(chain[s], s === a);
                    if (sg == null) { ok = false; break; }
                    segs.push(sg);
                  }
                  if (!ok) continue;
                  var listSel = segs.join('>');
                  var members = document.querySelectorAll(listSel);
                  var at = -1;
                  for (var m = 0; m < members.length; m++) if (members[m] === el) { at = m + 1; break; }
                  if (members.length >= 2 && at >= 1 && (!best || members.length > best.count)) best = { selector: listSel, index: at, count: members.length };
                }
                if (best) out.list = best;
              }
            } catch (e) {}
          } catch (e) {}
          return JSON.stringify(out);
        })(\#(selectorLiteral), \#(alohaIdLiteral))
        """#
    }

    /// The probe's JSON reply -> identity; nil when the reply is not the probe's shape.
    static func parse(_ json: String) -> ElementIdentity? {
        guard let value = JSValue.parse(json), case .object = value else { return nil }
        let rawIndex = value["index"]?.intValue ?? -1
        var attributes: [ElementIdentity.Attribute] = []
        if case let .array(pairs)? = value["attrs"] {
            for pair in pairs {
                guard case let .array(kv) = pair, kv.count == 2,
                      let name = kv[0].stringValue, !name.isEmpty, let val = kv[1].stringValue else { continue }
                attributes.append(.init(name: name, value: val))
            }
        }
        var list: ElementIdentity.ListPosition? = nil
        if let l = value["list"], case .object = l, let sel = l.string("selector"), !sel.isEmpty,
           let i = l["index"]?.intValue, let n = l["count"]?.intValue, n >= 2, i >= 1, i <= n,
           !sel.contains(" "), !sel.contains("]") {
            list = .init(selector: sel, index: i, count: n)
        }
        return ElementIdentity(index: rawIndex >= 1 ? rawIndex : nil, attributes: attributes, list: list)
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
