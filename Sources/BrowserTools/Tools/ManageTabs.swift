import Foundation
import ToolABI

/// The executable `manage_tabs` tool. Returns the per-action text output unwrapped — the
/// executor wraps it in the tool-result envelope.
@MainActor public final class ManageTabsExecutorTool: ExecutorTool {
    public let name = "manage_tabs"

    public init() {}

    public func execute(_ input: WorkflowValue?, _ context: ToolExecutionContext) async throws -> RawToolResult {
        guard let tabsWindow = context.services?.tabsService?.window else {
            return RawToolResult(output: "Tabs service not available.", isError: true)
        }
        guard let session = context.services?.session else {
            return RawToolResult(output: "Browser session not available.", isError: true)
        }

        let tabId = Self.string(input, "tab_id") ?? Self.legacySpelled(input, "tabId")
        let url = Self.string(input, "url")
        // AN OMITTED `action` WITH A `url` HAS ONE MEANING, so do it instead of spending a round
        // to discover the schema. Measured across the last 40 run directories: 13 `Unknown action:` results
        // over 5 of the 5 rows carrying a trace — every row paid it, the worst five times — and the model
        // recovered by trial and error, typically on its third round. On the cheap rung a wasted round is
        // ~800 reasoning tokens and a step off the budget.
        //
        // `tab_id` is NOT inferred: read, close and use all take one, so choosing among them would be a
        // real guess and would silently do the wrong thing. Only the unambiguous case is filled in.
        let requested = Self.string(input, "action") ?? ""
        let action = canonicalManageTabsAction(requested.isEmpty && url != nil ? "open" : requested)
        let webExtractionOptions = context.services?.webExtractionOptions ?? .baseline
        let ctx = ManageTabsActionContext(
            sessionId: context.sessionId,
            toolCallId: context.toolCallId,
            session: session,
            abortSignal: context.signal,
            webExtractionOptions: webExtractionOptions,
            housekeeping: context.services?.tabHousekeeping ?? .off
        )

        let result: TabToolResult
        switch action {
        case "list":
            // Titles and URLs in the model are caches, and only the tools that touched a
            // tab ever wrote to them: a page the agent navigated listed under the OLD
            // page's title, and a tab nobody read listed as "Untitled". One
            // `Target.getTargets` for the window fixes every row.
            if let live = tabsWindow.tabs as? LiveTabMetadataRefreshing {
                await live.refreshTabMetadata()
            }
            result = manageTabsList(tabsWindow, session)
        case "read":
            guard let tabId else {
                return RawToolResult(output: "tab_id is required for the read action", isError: true)
            }
            // The baseline default is `true`, so an omitted argument keeps the prior
            // `!= false` behavior.
            let includeScreenshot = resolveIncludeScreenshot(
                explicit: Self.bool(input, "include_screenshot"),
                default: webExtractionOptions.defaultIncludeScreenshot)
            result = await manageTabsRead(tabId, tabsWindow, ctx, includeScreenshot)
        case "open":
            guard let url else {
                return RawToolResult(output: "url is required for open action", isError: true)
            }
            // Anything that is not "user" is the agent, collapsed here rather than compared
            // again downstream: an unrecognized value must not land half-way, opening an agent
            // tab that is then not taken into use. A tab opened FOR the user never is — the
            // page tools address the agent's own tabs.
            let controlledBy = Self.string(input, "controlled_by") == "user" ? "user" : "agent"
            let use = controlledBy == "agent"
                && (Self.bool(input, "use") ?? Self.legacyBool(input, "focus")) != false
            // `open` returns the page too: two actions that return the same thing must not
            // disagree about what "the page" includes.
            let openIncludeScreenshot = resolveIncludeScreenshot(
                explicit: Self.bool(input, "include_screenshot"),
                default: webExtractionOptions.defaultIncludeScreenshot)
            result = await manageTabsOpen(url, tabsWindow, ctx, use, controlledBy, openIncludeScreenshot)
        case "close":
            guard let tabId else {
                return RawToolResult(output: "tab_id is required for the close action", isError: true)
            }
            result = await manageTabsClose(tabId, tabsWindow, ctx)
        case "use":
            guard let tabId else {
                return RawToolResult(output: "tab_id is required for the use action", isError: true)
            }
            result = await manageTabsUse(tabId, tabsWindow, ctx)
        case "unuse":
            result = manageTabsUnuse(ctx)
        default:
            // NAME THE VALID ACTIONS AND THE SHAPE. `Unknown action: ` with an empty action told the
            // caller neither what was missing nor what was allowed, which is why recovery took rounds
            // instead of one retry.
            let valid = "list, read, open, close, use, unuse"
            let got = requested.isEmpty ? "no action was given" : "got \(requested)"
            return RawToolResult(
                output: "manage_tabs needs \"action\" — one of: \(valid). \(got). "
                    + "To open a page use {\"action\":\"open\",\"url\":\"…\"}; "
                    + "to read one use {\"action\":\"read\",\"tab_id\":\"…\"}.",
                isError: true)
        }

        return RawToolResult(
            output: result.output ?? "", isError: result.isError ? true : nil,
            metadata: result.tabIdentity?.metadata,
            images: result.images)
    }

    static func string(_ input: WorkflowValue?, _ key: String) -> String? {
        guard case let .object(fields)? = input, case let .string(value)? = fields[key] else { return nil }
        return value
    }

    static func bool(_ input: WorkflowValue?, _ key: String) -> Bool? {
        guard case let .object(fields)? = input, case let .bool(value)? = fields[key] else { return nil }
        return value
    }

    /// Reads a parameter under its un-advertised legacy name, counting the hit. Counted on
    /// read and not on use: a `tabId` in a call whose action ignores it is still evidence the
    /// old spelling is in circulation. See the shim note below ``manageTabsLegacyWireHits``.
    static func legacySpelled(_ input: WorkflowValue?, _ key: String) -> String? {
        guard let value = string(input, key) else { return nil }
        manageTabsLegacyWireHits[key, default: 0] += 1
        return value
    }

    /// ``legacySpelled`` for a boolean: `open`'s background flag used to be `focus`, and a
    /// replayed `focus: false` that goes unread opens a tab that takes over every later page
    /// call — the opposite of what the caller asked for, with no error anywhere.
    static func legacyBool(_ input: WorkflowValue?, _ key: String) -> Bool? {
        guard let value = bool(input, key) else { return nil }
        manageTabsLegacyWireHits[key, default: 0] += 1
        return value
    }
}

// MARK: - Legacy wire compatibility — TEMPORARY, one release

// This tool used to spell its tab parameter `tabId`, its selection actions `focus` / `unfocus`,
// and `open`'s background flag `focus: false`; the spelling here (`tab_id`, `use` / `unuse`,
// `use: false`) is the one that survives. But a compacted transcript and a resumed session both
// replay whatever spelling they were RECORDED with, so refusing the old one makes the model
// spend retries on a call that worked when it made it. The synonyms are therefore accepted and
// deliberately NOT advertised: the schema names the canonical spelling only, so nothing new ever
// learns them.
//
// RETIRED ON EVIDENCE, NOT ON A GUESS: when ``manageTabsLegacyWireHits`` stays empty across a
// release, every transcript still in circulation has been re-recorded in the current spelling,
// and the three call sites (`legacySpelled` and `legacyBool` above, `canonicalManageTabsAction`
// below) go with it.

/// How often each un-advertised legacy spelling — `"tabId"`, `"focus"`, `"unfocus"` — has been
/// accepted in this process. Never reset, so a host can read it at shutdown.
///
/// `@MainActor` is written out because the module's default isolation did not reach this global:
/// without the attribute every reference from another module is rejected as unisolated shared
/// mutable state.
@MainActor public private(set) var manageTabsLegacyWireHits: [String: Int] = [:]

/// Translates a legacy action synonym to the canonical one, counting it on the way through.
private func canonicalManageTabsAction(_ requested: String) -> String {
    switch requested {
    case "focus", "unfocus":
        manageTabsLegacyWireHits[requested, default: 0] += 1
        return requested == "focus" ? "use" : "unuse"
    default:
        return requested
    }
}

/// Baseline `default` is `true`, so an omitted argument still yields a screenshot; a
/// text-first policy passes `default: false` and the model must ask for one explicitly.
func resolveIncludeScreenshot(explicit: Bool?, default fallback: Bool) -> Bool {
    explicit ?? fallback
}

struct ManageTabsActionContext {
    let sessionId: String
    let toolCallId: String
    let session: ChatModeSession
    let abortSignal: AbortSignal?
    /// Resolved at the CLI composition root; `.baseline` keeps an unwired call site at the
    /// exact prior behavior.
    var webExtractionOptions: AgentWebExtractionOptions = .baseline
    /// What this tool may do to the agent's own tabs unasked. `.off` — nothing — unless the
    /// host's ``NativeToolServices`` says otherwise.
    var housekeeping: TabHousekeepingPolicy = .off
}

/// Returns `nil` on success, or the error result the calling action should return.
func ensureTabAwake(_ tab: TabHandle, _ signal: AbortSignal?) async -> TabToolResult? {
    if let abortedBefore = abortedResultOrNull(signal?.aborted == true) { return abortedBefore }

    let wakeResult: WakeResult
    do {
        wakeResult = try await tab.wake(signal)
    } catch {
        if signal?.aborted == true || isAbortLikeError(error) {
            return TabToolResult(output: executionStoppedError, isError: true)
        }
        let message = (error as? AbortSignalError)?.message ?? "\(error)"
        return TabToolResult(output: "Tab \"\(tab.id)\" is unavailable because it failed to wake: \(message)", isError: true)
    }

    if let abortedAfter = abortedResultOrNull(signal?.aborted == true) { return abortedAfter }

    if wakeResult.ok { return nil }
    return TabToolResult(output: wakeResult.message ?? "", isError: true)
}

func tabIsInteractiveWeb(_ tab: TabHandle) -> Bool {
    isInteractiveWebTab(InteractiveTabDescriptor(tabType: tab.tabType, hasAgentDom: tab.agentDOM != nil))
}

func manageTabsList(_ tabsWindow: TabsWindow, _ session: ChatModeSession? = nil) -> TabToolResult {
    let tabsModel = tabsWindow.tabs
    let activeTabId = activeTabIdForPageTools(session, tabsWindow)
    let summaries = tabsModel.orderedTabs.map { tab -> TabSummary in
        // Redact non-http(s) URLs so `list` does not leak a local file path (the
        // page tools refuse to act on such tabs; the path itself is the secret).
        let url: String
        if case .rejected = validateTabUrl(TabUrlInput(url: tab.url)) {
            url = "[non-web URL hidden]"
        } else {
            url = tab.url
        }
        return TabSummary(
            id: tab.id,
            title: tab.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled",
            url: url,
            isActive: tab.id == activeTabId,
            openedByHuman: tab.openedByHuman
        )
    }
    return listTabs(summaries)
}

func manageTabsRead(_ tabId: String, _ tabsWindow: TabsWindow, _ ctx: ManageTabsActionContext, _ includeScreenshot: Bool) async -> TabToolResult {
    let tabsModel = tabsWindow.tabs
    guard let tab = tabsModel.getOrRestoreTab(tabId, restoreIfNeeded: false) else {
        return TabToolResult(output: "Tab \"\(tabId)\" not found.", isError: true)
    }
    if tab.userTookOver {
        return TabToolResult(output: "Tab \"\(tabId)\" was taken over by the user. Pick a different tab or ask the user to hand it back.", isError: true)
    }

    if case let .rejected(reason) = validateTabUrl(TabUrlInput(url: tab.url)) {
        return TabToolResult(output: reason, isError: true)
    }

    if let abortedBeforeMark = abortedResultOrNull(ctx.abortSignal?.aborted == true) { return abortedBeforeMark }

    markTabAgentControlled(tab, sessionId: ctx.sessionId, source: "manage-tabs:read")

    if let wakeFailure = await ensureTabAwake(tab, ctx.abortSignal) { return wakeFailure }

    // The title after the load, not the one the tab was born with. The load wait writes
    // it only on its polling leg, so a tab that finished via the lifecycle event reached
    // here titleless and read back as `Tab: "Untitled"` — for example.com, every time.
    if let live = tabsModel as? LiveTabMetadataRefreshing { await live.refreshTabMetadata() }

    do {
        let title = tab.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled"
        let url = tab.url
        // The id the caller should use from here on. A tab this session just opened was
        // addressed by the provisional id it was allocated with; now that it is attached,
        // its real Chrome target id is the one that outlives this process.
        let tabId = tab.id

        if tabIsInteractiveWeb(tab), let agentDOM = tab.agentDOM {
            let includeUrls = includeUrlsInMarkdownEnabled()

            if let abortedBeforeDom = abortedResultOrNull(ctx.abortSignal?.aborted == true) { return abortedBeforeDom }

            // Call the interactive DOM-build/serialize read directly with the turn's
            // abort signal, with no enclosing timeout/race. The underlying
            // `Runtime.evaluate` calls are each bounded by `CDPClient.send`'s
            // cancellation-aware backstop, so a wedged page cannot hang the turn, and
            // an interrupt unwinds the read via the abort signal.
            // At the baseline (every improvement off) this is exactly
            // `DomSerializeOptions(includeUrls: includeUrls)` — the prior call.
            let serializeOptions = ctx.webExtractionOptions.domSerializeOptions(includeUrls: includeUrls)
            let readPage: () async throws -> ToolABI.InteractMarkdownResult = {
                try await agentDOM.getInteractMarkdown(
                    includeScreenshot, false, serializeOptions: serializeOptions,
                    signal: ctx.abortSignal)
            }

            var interactResult = try await readPage()
            if let abortedAfterDom = abortedResultOrNull(ctx.abortSignal?.aborted == true) { return abortedAfterDom }

            // A CAPTCHA the host cleared after the read leaves this result describing a
            // page that is no longer there, so the remediated page is read AGAIN — once,
            // and only when the host says the page actually changed. Probed rather than
            // required, like the other tab seams: nothing in this package conforms, so
            // with no host behind it this is one read, as it was.
            if let remediating = tab as? PageReadRemediating,
               await remediating.remediateAfterRead(ctx.abortSignal) {
                if let abortedAfterRemediation = abortedResultOrNull(ctx.abortSignal?.aborted == true) { return abortedAfterRemediation }
                interactResult = try await readPage()
            }

            var sections: [String] = []
            sections.append("Tab: \"\(title)\" (ID: \"\(tabId)\")\nURL: \(url)\(viewportLineFor(tab))")
            sections.append("Interactive view: the page rendered as structural markdown — # headings, - list items, [text](href) links, | a | b | table rows, and plain paragraphs. Content is clean and id-free; every actionable element (link, button, input, select, landmark) carries a trailing {aloha-id=\"ID\" tag} marker. Use that id with page_click, page_type, page_select and get_text; to act on a row or a card, use the id on its own link or button trailer. The page tools address the tab currently in use — manage_tabs open and manage_tabs use both set it. Cross-origin iframe internals (payment widgets, embedded auth) cannot be inspected and carry no inner ids; do not read payment values back out.")

            if !interactResult.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sections.append(wrapInteractivePageMarkdown(interactResult.markdown))
            } else if interactResult.diagnostics.domError != nil || interactResult.diagnostics.serializeError != nil {
                let reason = interactResult.diagnostics.domError ?? interactResult.diagnostics.serializeError ?? "unknown"
                sections.append("(Interactive markdown empty: \(reason))")
            }

            // The viewport screenshot rides the result. It used to be handed to a
            // session method nothing implemented, so the capture round-trip was paid
            // and the pixels dropped — `include_screenshot` advertised a capability
            // that ended in a no-op.
            var images: [ParsedDataUrlImage] = []
            if includeScreenshot, let screenshot = interactResult.screenshot, let image = parseDataUrlImage(screenshot) {
                images.append(image)
            }

            return TabToolResult(
                output: sections.joined(separator: "\n\n"), tabId: tabId,
                title: tab.title?.isEmpty == false ? tab.title : nil,
                url: url.isEmpty ? nil : url,
                faviconUrl: tab.faviconUrl?.isEmpty == false ? tab.faviconUrl : nil,
                images: images)
        }

        // Legacy non-interactive path.
        if let abortedBeforeContext = abortedResultOrNull(ctx.abortSignal?.aborted == true) { return abortedBeforeContext }

        let tabContext = try await tabsModel.getTabContext(windowId: tabsWindow.id, tab: tab, signal: ctx.abortSignal)
        if let abortedAfterContext = abortedResultOrNull(ctx.abortSignal?.aborted == true) { return abortedAfterContext }

        guard let tabContext else {
            return TabToolResult(output: "Failed to read tab content: \(tabId)", isError: true)
        }

        let data = tabContext.data ?? ""
        var sections: [String] = []
        sections.append("Tab: \"\(title)\" (ID: \"\(tabId)\")\nURL: \(url)\(viewportLineFor(tab))")
        if !data.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append(wrapPageMarkdown(data))
        }
        if tabContext.type == "web", let domainSpecificData = tabContext.domainSpecificData, !domainSpecificData.isEmpty {
            sections.append(wrapDomainSpecificData(domainSpecificData))
        }

        return TabToolResult(
            output: sections.joined(separator: "\n\n"), tabId: tabId,
            title: tab.title?.isEmpty == false ? tab.title : nil,
            url: url.isEmpty ? nil : url,
            faviconUrl: tab.faviconUrl?.isEmpty == false ? tab.faviconUrl : nil)
    } catch {
        return TabToolResult(output: "Failed to read tab content: \(tabId) - \(error)", isError: true)
    }
}

private func viewportLineFor(_ tab: TabHandle) -> String {
    guard let bounds = tab.viewportBounds(), bounds.width > 0, bounds.height > 0 else { return "" }
    return "\nViewport: \(bounds.width)x\(bounds.height)"
}

func manageTabsOpen(_ url: String, _ tabsWindow: TabsWindow, _ ctx: ManageTabsActionContext, _ use: Bool, _ controlledBy: String, _ includeScreenshot: Bool) async -> TabToolResult {
    let normalized: String
    switch validateOpenUrl(url) {
    case let .ok(value):
        normalized = value
    case let .rejected(reason):
        return TabToolResult(output: reason, isError: true)
    }

    if controlledBy == "user" {
        return manageTabsOpenUserControlled(normalized, tabsWindow)
    }

    // Reuse an existing tab of this session that shows the page — or was opened for it.
    //
    // COMPARED AS RESOURCES, NOT AS STRINGS, because the tab's url is where it LANDED and
    // `normalized` is what was asked for, and the browser routinely changes one into the other.
    // Measured on run 34013723545 over 260 opens: only 36% landed on the byte-identical string,
    // while 40% differed by a trailing slash alone (`http://host` -> `http://host/`). A reuse
    // check defeated by punctuation — it fired 125 times and missed at least 105 more.
    //
    // The cost of a miss is not a stray tab. `page_click` takes an `aloha_id` and no tab, so it
    // acts on whichever tab is in use; with two tabs of the same page the model reads one and
    // clicks into the other. In the same run 40% of `not found` ids were present in the very
    // observation the model was reading, and 65 of 99 attempts had more than one tab carrying
    // ids. And a final-URL grader reads an arbitrary CDP context, so on run 34032045467 56 of 94
    // valid attempts were graded on a URL the agent never ended on, split by tab count: with one
    // tab the grader read the right page 32 times of 34, with two or more it was a coin flip.
    //
    // Where the tab is NOW is checked first, then what it was ASKED to open: the second catches
    // the case the first cannot, a server that rewrote the path after the tab opened (12% of the
    // run's opens differed by path case, which `sameTabTarget` deliberately does not fold).
    let existingTab = tabsWindow.tabs.orderedTabs.first { tab in
        guard let agentId = tab.browserAgentControlledAgentId, agentId == ctx.sessionId else { return false }
        if sameTabTarget(tab.url, normalized) { return true }
        if let asked = (tab as? OpenRequestRemembering)?.requestedOpenURL {
            return sameTabTarget(asked, normalized)
        }
        return false
    }
    if let existingTab {
        if use { ctx.session.setActiveBrowserTab(existingTab.id) }
        // SAY WHERE THE TAB IS when it is no longer on the page it was opened for. A match on
        // the remembered ask means the page has moved — a redirect, or a later navigation —
        // and "same URL" would tell the model it is looking at a page it is not. The current
        // url rides the result for the same reason.
        let stillThere = sameTabTarget(existingTab.url, normalized)
        let lines: [String]
        if stillThere {
            lines = [
                "Reused existing tab (same agent, same URL): \(normalized)",
                "Tab ID: \(existingTab.id)",
                "No new tab created — operate on this id directly."
            ]
        } else {
            lines = [
                "Reused existing tab opened for \(normalized); it has since moved to \(existingTab.url).",
                "Tab ID: \(existingTab.id)",
                "No new tab created. The page is not the one you asked for: read this tab before "
                    + "acting on it, or take it into use and page_navigate to \(normalized) if you "
                    + "need that page itself."
            ]
        }
        return TabToolResult(
            output: lines.joined(separator: "\n"),
            tabId: existingTab.id,
            title: existingTab.title?.isEmpty == false ? existingTab.title : nil,
            url: stillThere ? normalized : existingTab.url,
            faviconUrl: existingTab.faviconUrl?.isEmpty == false ? existingTab.faviconUrl : nil
        )
    }

    let newTab = tabsWindow.tabs.createTab(TabCreateSpec(
        tabType: "website",
        url: normalized,
        openedByHuman: false,
        agentControllerId: ctx.sessionId,
        sessionId: ctx.sessionId
    ))
    // Recorded BEFORE the page can move, so a later ask for the same address finds this tab
    // even though the server has since rewritten its path. See ``OpenRequestRemembering``.
    (newTab as? OpenRequestRemembering)?.requestedOpenURL = normalized

    let session = ctx.session
    // Only when a caller asked for it: `sessionNetworkDir()` is nil unless a network log
    // directory was passed or ALOHAJET_NETWORK_LOG is set. Opening a tab is not consent to
    // have its requests, headers and response bodies written to disk.
    if let networkDir = session.sessionNetworkDir() {
        let networkLogPath = (networkDir as NSString).appendingPathComponent("\(newTab.id).jsonl")
        newTab.startNetworkRecording(logPath: networkLogPath)
        session.registerNetworkRecordingTab(newTab)
    }
    // ATOMIC open: the page's own markdown, in THIS result. Nothing pushes page state to the
    // caller, so an open that returned only a tab id left the page unread — and a hint in the
    // receipt naming `manage_tabs read <tab_id>` did not fix it (measured: the model read the hint
    // and kept clicking). What works is not being able to get it wrong: reuse the read path here,
    // so one call navigates AND returns the content, and a batch of five opens yields five pages.
    //
    // It also has to run BEFORE the receipt is written: the tab is allocated with a
    // provisional id and acquires its real Chrome target id only when this read attaches
    // it. Naming the tab any earlier prints an id that dies with this process — which is
    // exactly what `Tab ID: tab-XXXX` was, an id `manage_tabs list` had never heard of.
    let opened = await manageTabsRead(newTab.id, tabsWindow, ctx, includeScreenshot)
    let tabId = newTab.id
    if use { session.setActiveBrowserTab(tabId) }
    // AFTER the new tab is in use, so it and the tab in use are both protected. Nothing happens
    // here unless the host set a cap — see ``trimAgentTabs``.
    let trimmed = await trimAgentTabs(tabsWindow, ctx, keeping: tabId)

    var outputLines = ["Opened: \(normalized)", "Tab ID: \(tabId)"]
    if use {
        outputLines.append("This tab is now the one page_click, page_type, page_select, page_navigate, page_press_keys, page_wait_for and get_text address. The page below is a snapshot taken at open; nothing refreshes it for you. After any click, type or navigation, call manage_tabs read with this tab_id to see the current page. Pass use: false on open to skip taking it.")
    }
    // SAID OUT LOUD, because a tab vanishing under the model is worse than a tab it must close
    // itself: the ids from a closed tab are gone, and it should know that rather than discover
    // it through a "not found" it cannot explain.
    if !trimmed.isEmpty, let cap = ctx.housekeeping.maxAgentTabs {
        outputLines.append("Closed \(trimmed.count) older tab(s) of yours to stay under the "
            + "\(cap)-tab limit: \(trimmed.joined(separator: ", ")). Any aloha-id from those "
            + "tabs is gone; re-read a tab you still need.")
    }
    if !opened.isError, let body = opened.output,
       !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        outputLines.append(body)
    }

    return TabToolResult(
        output: outputLines.joined(separator: "\n"),
        tabId: tabId,
        title: newTab.title?.isEmpty == false ? newTab.title : nil,
        url: normalized,
        faviconUrl: newTab.faviconUrl?.isEmpty == false ? newTab.faviconUrl : nil,
        images: opened.images
    )
}

/// Closes the OLDEST agent tab of this session while the host's cap is exceeded, never touching
/// the tab in use, the tab just opened, or a tab that is the user's. Nothing when
/// ``TabHousekeepingPolicy/maxAgentTabs`` is nil, which it is unless the host set it.
///
/// A CAP, not a guess about which tab is still wanted. The count is what decides whether a
/// final-URL bench grades the page the agent worked on: `_read_final_url` takes `non_blank[-1]`
/// across all CDP contexts, and on run 34032045467 it read the right page 32 times of 34 when
/// ONE tab was open and roughly half the time with two or more. 402 opens against 26 closes in
/// that run; every abandoned tab is another chance to score a bare origin instead of the work.
///
/// Oldest-first rather than least-recently-used because "recently used" is not knowable here:
/// a click or a type goes through the page tools, which do not report back to this file. Age is
/// the one ordering `orderedTabs` already gives, and where the agent opens the same URL
/// repeatedly the oldest duplicate is exactly the one nothing has addressed for longest.
///
/// The tab in use is resolved the way the page tools resolve it — the session's own pointer
/// first — because `manage_tabs use` writes `session.setActiveBrowserTab` and never touches the
/// window's `activeTabId`; reading the window's field instead protected the wrong tab for a
/// whole run (34052929955).
func trimAgentTabs(_ tabsWindow: TabsWindow, _ ctx: ManageTabsActionContext,
                   keeping newTabId: String) async -> [String] {
    guard let cap = ctx.housekeeping.maxAgentTabs, cap > 0 else { return [] }
    var closed: [String] = []
    let activeId = activeTabIdForPageTools(ctx.session, tabsWindow)
    while true {
        let mine = tabsWindow.tabs.orderedTabs.filter {
            $0.browserAgentControlledAgentId == ctx.sessionId && !$0.openedByHuman
        }
        guard mine.count > cap else { break }
        // A victim already closed once is not offered again: a model whose `closeTab` leaves
        // the handle registered must not spin this loop.
        guard let victim = mine.first(where: {
            $0.id != newTabId && $0.id != activeId && !closed.contains($0.id)
        }) else { break }
        ctx.session.unregisterNetworkRecordingTab(victim.id)
        ctx.session.clearActiveBrowserTabIfMatches(victim.id)
        await tabsWindow.tabs.closeTab(victim.id, skipConfirm: true)
        closed.append(victim.id)
    }
    return closed
}

/// Whether two URLs name the same thing to open, for the purpose of reusing a tab.
///
/// Deliberately narrow. Two differences are safe to ignore because the standards say the strings
/// mean the same resource:
///
///   * the HOST is case-insensitive (RFC 3986 §3.2.2), so `HTTP://Host` and `http://host` match;
///   * a trailing slash on an otherwise-equal path is the same page in every server this bench
///     touches, and an EMPTY path spelled `http://h` vs `http://h/` is the same by spec.
///
/// Two differences are deliberately NOT ignored, because treating them as equal would take into
/// use a tab showing a different page than the caller asked for — a silent wrong answer, which
/// is worse than the extra tab this function exists to avoid:
///
///   * PATH CASE. Paths are case-sensitive by spec, and although one stand happens to redirect
///     `/submit/earthporn` to `/submit/EarthPorn`, a server where those are two pages is
///     perfectly legal. 12% of the run's opens drift this way and they stay unmatched here; the
///     remembered ask (``OpenRequestRemembering``) is what catches them.
///   * A REDIRECT THAT LANDS DEEPER, like `/admin` -> `/admin/admin/dashboard/`. The tab is no
///     longer showing what was asked for, and a caller asking again may well want it back.
///
/// `URL.path` is "" for `http://h` and "/" for `http://h/`, and the first draft left them
/// unequal — the exact 40% case the function exists for. The root folds to "" on both sides.
public func sameTabTarget(_ a: String, _ b: String) -> Bool {
    if a == b { return true }
    guard let ua = URL(string: a), let ub = URL(string: b) else { return false }
    guard ua.scheme?.lowercased() == ub.scheme?.lowercased(),
          ua.host?.lowercased() == ub.host?.lowercased(),
          ua.port == ub.port,
          ua.query == ub.query,
          ua.fragment == ub.fragment
    else { return false }
    func path(_ u: URL) -> String {
        var p = u.path
        while p.count > 1, p.hasSuffix("/") { p = String(p.dropLast()) }
        return p == "/" ? "" : p
    }
    return path(ua) == path(ub)
}

/// `controlled_by: "user"`: a tab opened FOR the user, not one the agent drives. It is created
/// `openedByHuman`, the same flag a tab that was already open carries — so it gets no agent
/// controller, no network recording, is never taken into use, and `close` refuses it. That last
/// one is a real difference from an agent tab and the receipt says so.
func manageTabsOpenUserControlled(_ url: String, _ tabsWindow: TabsWindow) -> TabToolResult {
    let tab = tabsWindow.tabs.createTab(TabCreateSpec(tabType: "website", url: url, openedByHuman: true))
    // The handle is allocation-only — the real browser target is created on first attach, and
    // nothing else ever attaches a user tab, so without this it stays a phantom the user never
    // sees. Not awaited: a background tab is throttled, so waiting out its load would stall the
    // open for the whole wake budget for a page the agent is not going to read.
    Task { _ = try? await tab.wake(nil) }
    let lines = [
        "Opened: \(url)",
        "Tab ID: \(tab.id)",
        "This tab is the user's: opened in the background like a middle-clicked link, with no AI "
            + "indicator and no network recording, and it is NOT the tab the page tools address. "
            + "You can read it; you cannot close it."
    ]
    return TabToolResult(
        output: lines.joined(separator: "\n"),
        tabId: tab.id,
        title: tab.title?.isEmpty == false ? tab.title : nil,
        url: url,
        faviconUrl: tab.faviconUrl?.isEmpty == false ? tab.faviconUrl : nil
    )
}

func manageTabsClose(_ tabId: String, _ tabsWindow: TabsWindow, _ ctx: ManageTabsActionContext) async -> TabToolResult {
    guard let tab = tabsWindow.tabs.tab(tabId) else {
        return TabToolResult(output: "Tab \"\(tabId)\" not found.", isError: true)
    }
    // THE USER'S TABS ARE NOT THE AGENT'S TO CLOSE. This guard used to test `isPinned`,
    // which no CDP-backed tab can ever report true (the DevTools protocol has no pin
    // concept), so it never fired and every tab in the browser — including the ones the
    // user had open before the session attached — was closable. `openedByHuman` is set
    // truthfully at every construction site: true when seeded, restored or adopted live,
    // false only for a tab this session opened or a click spawned.
    if tab.openedByHuman {
        let title = tab.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled"
        return TabToolResult(
            output: "Cannot close \"\(title)\": it is the user's tab, not one you opened. "
                + "You may only close tabs opened by manage_tabs.",
            isError: true)
    }
    // THE PAGE THE WORK IS ON is not the agent's to throw away either — when the host says so.
    // Off by default: for a user, a close that is refused is a tool that did not do what it
    // was told. See ``closeRefusal`` for what was measured.
    if ctx.housekeeping.refuseClosingWorkPage {
        let snapshots = tabsWindow.tabs.orderedTabs.map {
            AgentTabSnapshot(id: $0.id, url: $0.url,
                             agentId: $0.browserAgentControlledAgentId, openedByHuman: $0.openedByHuman)
        }
        if let refusal = closeRefusal(snapshots, sessionId: ctx.sessionId, target: tabId) {
            return TabToolResult(output: refusal, isError: true)
        }
    }

    let title = tab.title
    let url = tab.url
    let faviconUrl = tab.faviconUrl

    ctx.session.unregisterNetworkRecordingTab(tabId)
    ctx.session.clearActiveBrowserTabIfMatches(tabId)
    await tabsWindow.tabs.closeTab(tabId, skipConfirm: true)

    return TabToolResult(
        output: "Closed: \"\(title ?? "")\" (\(url))",
        tabId: tabId,
        title: title?.isEmpty == false ? title : nil,
        url: url.isEmpty ? nil : url,
        faviconUrl: faviconUrl?.isEmpty == false ? faviconUrl : nil
    )
}

func manageTabsUse(_ tabId: String, _ tabsWindow: TabsWindow, _ ctx: ManageTabsActionContext) async -> TabToolResult {
    guard let tab = tabsWindow.tabs.getOrRestoreTab(tabId, restoreIfNeeded: false) else {
        return TabToolResult(output: "Tab \"\(tabId)\" not found.", isError: true)
    }

    if case let .rejected(reason) = validateTabUrl(TabUrlInput(url: tab.url)) {
        return TabToolResult(output: reason, isError: true)
    }

    if let abortedBeforeMark = abortedResultOrNull(ctx.abortSignal?.aborted == true) { return abortedBeforeMark }

    markTabAgentControlled(tab, sessionId: ctx.sessionId, source: "manage-tabs:use")

    if let wakeFailure = await ensureTabAwake(tab, ctx.abortSignal) { return wakeFailure }

    ctx.session.setActiveBrowserTab(tab.id)
    return TabToolResult(
        output: "Tab \"\(tab.id)\" (\(tab.url)) is now the tab the page tools address. Page state is never pushed to you: call manage_tabs read with this tab_id whenever you need to see the current page.",
        tabId: tab.id,
        title: tab.title?.isEmpty == false ? tab.title : nil,
        url: tab.url.isEmpty ? nil : tab.url
    )
}

func manageTabsUnuse(_ ctx: ManageTabsActionContext) -> TabToolResult {
    let previousTabId = ctx.session.getActiveBrowserTabId()
    ctx.session.setActiveBrowserTab(nil)
    if let previousTabId {
        return TabToolResult(
            output: "No tab is in use now (was \"\(previousTabId)\").",
            previousTabId: previousTabId
        )
    }
    return TabToolResult(output: "No tab was in use.")
}

/// OFF by default: hrefs multiply the size of a link-dense page's markdown, and the page
/// tools address ids, not hrefs. `ALOHAJET_MARKDOWN_URLS=1` includes them. Read via
/// `getenv` so a test's `setenv` is observed immediately.
func includeUrlsInMarkdownEnabled() -> Bool {
    guard let raw = getenv("ALOHAJET_MARKDOWN_URLS") else { return false }
    switch String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "1", "true", "yes", "on": return true
    default: return false
    }
}

// MARK: - The work page: what close refuses and what the turn-end collapse keeps

/// One tab, reduced to the four facts the close and collapse rules need.
///
/// The decision is separated from the closing for the same reason `sameTabTarget` is: the rule
/// is what can be wrong, and a rule that takes a `TabsWindow` cannot be tested without one.
public nonisolated struct AgentTabSnapshot: Sendable, Equatable {
    public let id: String
    public let url: String
    /// The session this tab is controlled by, nil for a tab nobody controls.
    public let agentId: String?
    /// The user's tab (see ``TabHandle/openedByHuman``): never ours to close or to keep.
    public let openedByHuman: Bool

    public init(id: String, url: String, agentId: String?, openedByHuman: Bool) {
        self.id = id
        self.url = url
        self.agentId = agentId
        self.openedByHuman = openedByHuman
    }
}

/// How SPECIFIC a page is: the number of non-empty path segments.
///
/// A crude measure on purpose. It is not trying to rank pages; it only has to notice that
/// `/f/MachineLearning/2/the-effectiveness-of-online-learning` is a more particular thing than
/// `/f/MachineLearning` or `/`, which is the whole of what went wrong. Its limit, recorded
/// rather than glossed: it cannot see a query string, so a report whose identity is entirely in
/// its query is protected only by being the deepest or the last.
public func pageSpecificity(_ url: String) -> Int {
    // A SCHEME AND A HOST ARE REQUIRED, not just a successful parse. `URL(string:)` accepts a
    // relative reference, so "not a url" comes back with that whole phrase as its path and would
    // otherwise score 1 — letting a garbage url pass for work worth protecting. Anything that is
    // not an absolute address scores 0, the least specific thing there is.
    guard let parsed = URL(string: url), parsed.scheme != nil,
          let host = parsed.host, !host.isEmpty else { return 0 }
    return parsed.path.split(separator: "/").filter { !$0.isEmpty }.count
}

/// Why this tab may not be closed, or nil when closing it is fine. Consulted only under
/// ``TabHousekeepingPolicy/refuseClosingWorkPage``.
///
/// THE LARGEST MEASURED FAILURE on a final-URL bench (nav-33, 90 of 93 rows `url_match`): the
/// agent finishes the work, closes the tab holding it, and is graded on the front page. Across
/// four runs (34041986201, 34052929955, 34055934215, 34083460926), attempts that closed a page
/// deeper than the one they were finally graded on passed **0 of 24**, against 23-26% for
/// attempts that closed nothing. t625 closed the post it had just been asked to create and was
/// graded on `/`; t631 and t620 closed their own submissions; t705 the filtered sales report;
/// t595 `/f/space/hot`, which was the gold URL.
///
/// WHY IT DOES IT: closing is how it leaves a page. In one run `manage_tabs close` was called 30
/// times and `page_navigate action=back` 3 times, though `back` is implemented and advertised.
/// So the refusal names `back` and `use`, and names a tab it MAY close — a refusal that does not
/// offer the alternative just moves the dead end.
///
/// Two refusals, and both are about what would be LEFT:
///   1. the last tab of this session — closing it leaves the agent with no page at all;
///   2. the most specific tab — closing it would strand the agent on a shallower page than the
///      one it had reached, which is precisely the measured loss.
///
/// Everything else still closes: a tab belonging to someone else, a duplicate of equal depth,
/// and any tab that is not the most specific one. That last part is what keeps the image-trap
/// escape working — `/submission_images/<hash>.jpg` is shallower than the `/f/<forum>/hot` page
/// it came from, so the agent can still close it and return.
public func closeRefusal(_ tabs: [AgentTabSnapshot], sessionId: String, target: String) -> String? {
    guard let victim = tabs.first(where: { $0.id == target }) else { return nil }
    guard victim.agentId == sessionId, !victim.openedByHuman else { return nil }
    let mine = tabs.filter { $0.agentId == sessionId && !$0.openedByHuman }
    let remaining = mine.filter { $0.id != target }
    if remaining.isEmpty {
        return "Refusing to close \"\(target)\" (\(victim.url)): it is your only tab, and closing it "
            + "would leave you with no page. To leave this page use page_navigate with "
            + "action=\"back\"; to work somewhere else, manage_tabs open the page you want first."
    }
    let here = pageSpecificity(victim.url)
    if remaining.allSatisfy({ pageSpecificity($0.url) < here }),
       let shallower = remaining.min(by: { pageSpecificity($0.url) < pageSpecificity($1.url) }) {
        return "Refusing to close \"\(target)\" (\(victim.url)): this tab holds the page the task's "
            + "work is on — the most specific page you have reached — and every other tab of yours "
            + "is further up the site, so closing it would leave that work behind. To leave this "
            + "page use page_navigate with action=\"back\"; to work in another tab use manage_tabs "
            + "use. If you need to close a tab, close a shallower one instead: "
            + "\"\(shallower.id)\" (\(shallower.url))."
    }
    return nil
}

/// EVERY candidate for the tab to keep at the end of a turn, best first.
///
/// THE KEEPER IS THE MOST SPECIFIC TAB, not the one in use. A first version kept whatever the
/// session pointer named, and that was wrong in the one case this exists for: on run 34099567394,
/// t625 r0 created exactly the right post, `/f/MachineLearning/2/the-effectiveness-of-online-learning`,
/// and was graded on `/f/MachineLearning` — the collapse kept the forum and closed the post. It
/// scored 0 of 5 while producing the correct post in all five reps. The agent walks into it: after
/// submitting it reads the post, closes the shallower tabs, tries to comment, and then opens a
/// fresh tab on the bare origin, which becomes the one in use. "Where the agent is pointing"
/// drifts away from the answer; "the most particular page it reached" does not.
///
/// AND IT AGREES WITH `closeRefusal`, which is the real argument: that rule refuses to let the
/// agent close its most specific tab, and a turn-end pass that then closes that same tab itself
/// is a contradiction. `pageSpecificity` is the one measure both use.
///
/// An ORDER rather than a winner because a tab that cannot WAKE reports no URL, so keeping it
/// hands the grader the bare origin. Measured over every archived bench trace containing a wake
/// failure: 16 collapse decisions, 14 of them kept a tab that had failed to wake, and in 6 the
/// collapse HAD an alternative and passed over it. `collapseAgentTabsToActive` walks this order
/// and keeps the first tab that answers. Most specific first; within one specificity the tab in
/// use, then newest — window order is oldest-first, so the later entry is the more recent thing
/// the agent reached.
public func collapseKeeperRanked(_ tabs: [AgentTabSnapshot], sessionId: String, activeId: String?) -> [String] {
    let mine = tabs.filter { $0.agentId == sessionId && !$0.openedByHuman }
    guard !mine.isEmpty else { return [] }
    return mine.enumerated().sorted { a, b in
        let sa = pageSpecificity(a.element.url)
        let sb = pageSpecificity(b.element.url)
        if sa != sb { return sa > sb }
        let aActive = a.element.id == activeId
        let bActive = b.element.id == activeId
        if aActive != bActive { return aActive }
        return a.offset > b.offset
    }.map { $0.element.id }
}

/// The head of ``collapseKeeperRanked``: the tab a caller that cannot probe liveness keeps.
public func collapseKeeper(_ tabs: [AgentTabSnapshot], sessionId: String, activeId: String?) -> String? {
    collapseKeeperRanked(tabs, sessionId: sessionId, activeId: activeId).first
}

/// Which of this session's agent tabs to close at the end of a turn, leaving the keeper.
///
/// WHY THE END OF THE TURN IS A DIFFERENT PROBLEM FROM THE CAP. `maxAgentTabs` bounds what the
/// agent works with WHILE it works, and leaves room for a two-page working set. The grader reads
/// `final_url` from an arbitrary CDP context once the turn is over, so every tab still standing
/// is another way to be scored on a page the agent abandoned — a different requirement, once,
/// at the end. Run 34041986201, with tab reuse already fixed: attempts that still opened two or
/// more tabs passed 2 of 20 against 19 of 74 for the rest.
///
/// Closing at turn end cannot cost the agent anything it still needs: the turn is over, nothing
/// will act again. The only thing that can be lost is the answer, which is why the keeper is
/// chosen by specificity rather than by focus.
public func agentTabsToCollapse(_ tabs: [AgentTabSnapshot], sessionId: String, activeId: String?) -> [String] {
    agentTabsToCollapse(tabs, sessionId: sessionId,
                        keeper: collapseKeeper(tabs, sessionId: sessionId, activeId: activeId))
}

/// The same list for a keeper somebody else chose. The live collapse keeps the first tab that
/// WAKES rather than the first the rule ranks, and it must not then recompute the victims from
/// the rule — that put the keeper back in its own kill list and closed the tab it had just
/// decided to keep. A nil keeper closes nothing: the rule declines rather than empty the window.
public func agentTabsToCollapse(_ tabs: [AgentTabSnapshot], sessionId: String, keeper: String?) -> [String] {
    guard let keeper else { return [] }
    return tabs
        .filter { $0.agentId == sessionId && !$0.openedByHuman && $0.id != keeper }
        .map { $0.id }
}

/// What one end-of-turn collapse did, in the terms needed to read a zero.
///
/// A bare count of closed tabs cannot: zero means "there was nothing to close" AND "the rule
/// declined to act", and on run 34052929955 the zero was neither — the collapse ran 99 times
/// and declined every time, because it was reading the window's active tab, a field the agent
/// never writes. `mine` and `keeper` separate those; log all three.
public nonisolated struct AgentTabCollapse: Sendable, Equatable {
    public let closed: [String]
    /// This session's agent tabs at the moment of the collapse.
    public let mine: Int
    /// The tab the collapse kept, or nil when it had none of its own to keep.
    public let keeper: String?

    public init(closed: [String], mine: Int, keeper: String?) {
        self.closed = closed
        self.mine = mine
        self.keeper = keeper
    }
}

/// The best-ranked tab that can actually be woken, else the best-ranked one.
///
/// ONE CANDIDATE IS NOT A CHOICE, and this is the whole cost control. A wake on a dead tab pays
/// its full deadline, and 68 of 97 archived collapses had a single agent tab — nothing to
/// compare it against, the same answer either way — so the probe is skipped and those turns end
/// exactly as fast as before. With two or three it stops at the first tab that answers.
///
/// A TAB THAT WAKES IS NOT NECESSARILY THE RIGHT PAGE, and the ranking still decides that. This
/// only removes candidates that cannot report a URL at all. If none of them wakes the head is
/// kept anyway: closing everything to avoid keeping something dead would hand the grader an
/// empty window, which is not better. `try?` over the throwing wake: an abort or a transport
/// error during turn-end cleanup means the same thing here as `ok == false`.
private func firstTabThatWakes(_ ranked: [String], _ tabsWindow: TabsWindow) async -> String? {
    guard let head = ranked.first else { return nil }
    guard ranked.count > 1 else { return head }
    for id in ranked {
        guard let tab = tabsWindow.tabs.tab(id) else { continue }
        if let result = try? await tab.wake(nil), result.ok { return id }
    }
    return head
}

/// Closes every agent tab of this session except the most specific one that can be woken, and
/// leaves the session pointing at the tab it kept. The user's tabs and tabs belonging to any
/// other session are never touched.
///
/// A library entry point: the host's turn runner calls it once the turn is over, on EVERY
/// completion rather than a clean answer only — a turn that hit its step budget can still be
/// sitting on the right page, and it is graded the same way. ``collapseAgentTabsAtTurnEnd`` is
/// the same call behind the policy switch.
@MainActor
public func collapseAgentTabsToActive(_ tabsWindow: TabsWindow, _ session: ChatModeSession,
                                      sessionId: String) async -> AgentTabCollapse {
    let snapshots = tabsWindow.tabs.orderedTabs.map {
        AgentTabSnapshot(id: $0.id, url: $0.url,
                         agentId: $0.browserAgentControlledAgentId, openedByHuman: $0.openedByHuman)
    }
    // The session's own pointer first, as the page tools resolve it. `orderedTabs.first` is
    // deliberately NOT a fallback here: it is the OLDEST tab, a fine default for "which page do
    // I act on" and a bad one for "which page may I keep".
    let active = activeTabIdForPageTools(session, tabsWindow)
    let ranked = collapseKeeperRanked(snapshots, sessionId: sessionId, activeId: active)
    let keeper = await firstTabThatWakes(ranked, tabsWindow)
    let victims = agentTabsToCollapse(snapshots, sessionId: sessionId, keeper: keeper)
    for id in victims {
        session.unregisterNetworkRecordingTab(id)
        // CLEAR THE POINTER TOO: a victim CAN be the tab the session names — that is the whole
        // point — and leaving the pointer on a closed tab is how `activeTabIdForPageTools`
        // starts resolving to nothing. `manageTabsClose` pairs these two calls for the same reason.
        session.clearActiveBrowserTabIfMatches(id)
        await tabsWindow.tabs.closeTab(id, skipConfirm: true)
    }
    // AND POINT AT WHAT WAS KEPT, so the grader's arbitrary context has one more reason to be
    // the page the work is on.
    if let keeper, !victims.isEmpty {
        session.setActiveBrowserTab(keeper)
    }
    let mine = snapshots.filter { $0.agentId == sessionId && !$0.openedByHuman }
    return AgentTabCollapse(closed: victims, mine: mine.count, keeper: keeper)
}

/// ``collapseAgentTabsToActive`` under the host's ``TabHousekeepingPolicy``: nil when
/// `collapseAtTurnEnd` is off (the default) or the services carry no window or session, so a
/// caller can wire the call unconditionally and let the policy decide.
@MainActor
public func collapseAgentTabsAtTurnEnd(_ services: NativeToolServices, sessionId: String) async -> AgentTabCollapse? {
    guard services.tabHousekeeping.collapseAtTurnEnd,
          let tabsWindow = services.tabsService?.window,
          let session = services.session else { return nil }
    return await collapseAgentTabsToActive(tabsWindow, session, sessionId: sessionId)
}
