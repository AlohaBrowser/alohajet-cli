import Foundation
import ToolABI

// MARK: - manage_tabs executor tool

/// The executable `manage_tabs` tool: the tab-management surface — list, read,
/// open, close, and choose which tab the page_* tools address. It resolves the
/// tabs window and the browser session from the context's services, dispatches
/// on the requested `action`, and returns the per-action text output (unwrapped
/// — the executor wraps it in the tool-result envelope).
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

        let tabId = Self.string(input, "tab_id")
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
        let action = requested.isEmpty && url != nil ? "open" : requested
        let webExtractionOptions = context.services?.webExtractionOptions ?? .baseline
        let ctx = ManageTabsActionContext(
            sessionId: context.sessionId,
            toolCallId: context.toolCallId,
            session: session,
            abortSignal: context.signal,
            webExtractionOptions: webExtractionOptions
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
            result = manageTabsList(tabsWindow)
        case "read":
            guard let tabId else {
                return RawToolResult(output: "tab_id is required for the read action", isError: true)
            }
            // When the call omits `include_screenshot`, fall back to the configured
            // default. The baseline default is `true`, so the OFF path is exactly the
            // prior `!= false` behavior; an explicit value always wins.
            let includeScreenshot = resolveIncludeScreenshot(
                explicit: Self.bool(input, "include_screenshot"),
                default: webExtractionOptions.defaultIncludeScreenshot)
            result = await manageTabsRead(tabId, tabsWindow, ctx, includeScreenshot)
        case "open":
            guard let url else {
                return RawToolResult(output: "url is required for open action", isError: true)
            }
            let use = Self.bool(input, "use") != false
            // `open` now returns the page, so it resolves `include_screenshot` exactly like
            // `read` — same explicit flag, same configured default. Two actions that return the
            // same thing must not disagree about what "the page" includes.
            let openIncludeScreenshot = resolveIncludeScreenshot(
                explicit: Self.bool(input, "include_screenshot"),
                default: webExtractionOptions.defaultIncludeScreenshot)
            result = await manageTabsOpen(url, tabsWindow, ctx, use, openIncludeScreenshot)
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

    // MARK: Input reading

    static func string(_ input: WorkflowValue?, _ key: String) -> String? {
        guard case let .object(fields)? = input, case let .string(value)? = fields[key] else { return nil }
        return value
    }

    /// Returns the boolean field, or `nil` when absent. Callers use this with
    /// `!= false` defaulting, where any non-`false` value (including a missing
    /// key) is treated as "true".
    static func bool(_ input: WorkflowValue?, _ key: String) -> Bool? {
        guard case let .object(fields)? = input, case let .bool(value)? = fields[key] else { return nil }
        return value
    }
}

// MARK: - Read screenshot resolution

/// Decide whether a `manage_tabs` read attaches a viewport screenshot. An explicit
/// `include_screenshot` argument always wins; when the call omits it, the configured
/// `default` is used. The baseline `default` is `true`, so an omitted argument yields a
/// screenshot exactly as before; a text-first policy passes `default: false`, where the
/// model must explicitly pass `include_screenshot: true` to get one.
func resolveIncludeScreenshot(explicit: Bool?, default fallback: Bool) -> Bool {
    explicit ?? fallback
}

// MARK: - Per-action context

/// The per-action context passed to each handler, built from the tool's runtime.
struct ManageTabsActionContext {
    let sessionId: String
    let toolCallId: String
    let session: ChatModeSession
    let abortSignal: AbortSignal?
    /// The toggleable web-extraction options for this read (resolved at the CLI
    /// composition root). Defaults to `.baseline` so any unwired call site keeps the
    /// exact prior behavior.
    var webExtractionOptions: AgentWebExtractionOptions = .baseline
}

// MARK: - Wake into a tab-tool response

/// Wake a tab inside a manage_tabs action, normalizing abort + wake failure into
/// tool-result shaped responses. Returns `nil` on success, or the error result
/// the action should return.
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

/// Whether the live tab is an interactive website tab with an attached agent DOM.
func tabIsInteractiveWeb(_ tab: TabHandle) -> Bool {
    isInteractiveWebTab(InteractiveTabDescriptor(tabType: tab.tabType, hasAgentDom: tab.agentDOM != nil))
}

// MARK: - Action: list

func manageTabsList(_ tabsWindow: TabsWindow) -> TabToolResult {
    let tabsModel = tabsWindow.tabs
    let activeTabId = tabsModel.activeTabId
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
            title: tab.title?.isEmpty == false ? tab.title! : "Untitled",
            url: url,
            isActive: tab.id == activeTabId,
            openedByHuman: tab.openedByHuman
        )
    }
    return listTabs(summaries)
}

// MARK: - Action: read

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
        let title = tab.title?.isEmpty == false ? tab.title! : "Untitled"
        let url = tab.url
        // The id the caller should use from here on. A tab this session just opened was
        // addressed by the provisional id it was allocated with; now that it is attached,
        // its real Chrome target id is the one that outlives this process.
        let tabId = tab.id

        // --- Interactive (agentDOM) markdown path ---
        if tabIsInteractiveWeb(tab), let agentDOM = tab.agentDOM {
            let includeUrls = includeUrlsInMarkdownEnabled()

            if let abortedBeforeDom = abortedResultOrNull(ctx.abortSignal?.aborted == true) { return abortedBeforeDom }

            // Call the interactive DOM-build/serialize read directly with the turn's
            // abort signal, with no enclosing timeout/race. The underlying
            // `Runtime.evaluate` calls are each bounded by `CDPClient.send`'s
            // cancellation-aware backstop, so a wedged page cannot hang the turn, and
            // an interrupt unwinds the read via the abort signal.
            // Thread the resolved web-extraction options through serialization. At the
            // baseline (every improvement off) this produces exactly
            // `DomSerializeOptions(includeUrls: includeUrls)` — the prior call.
            let serializeOptions = ctx.webExtractionOptions.domSerializeOptions(includeUrls: includeUrls)
            // ONE definition of "read this page", used both for the first read and for
            // the re-read that a cleared CAPTCHA earns.
            let readPage: () async throws -> ToolABI.InteractMarkdownResult = {
                try await agentDOM.getInteractMarkdown(
                    includeScreenshot, false, serializeOptions: serializeOptions,
                    signal: ctx.abortSignal)
            }

            let interactResult = try await readPage()
            if let abortedAfterDom = abortedResultOrNull(ctx.abortSignal?.aborted == true) { return abortedAfterDom }

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

        // --- Legacy / non-interactive markdown path ---
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

/// Probes the tab's layer bounds and renders the `\nViewport: WxH` suffix, or an
/// empty string when no live, positive-size layer is available.
private func viewportLineFor(_ tab: TabHandle) -> String {
    guard let bounds = tab.viewportBounds(), bounds.width > 0, bounds.height > 0 else { return "" }
    return "\nViewport: \(bounds.width)x\(bounds.height)"
}

// MARK: - Action: open

func manageTabsOpen(_ url: String, _ tabsWindow: TabsWindow, _ ctx: ManageTabsActionContext, _ use: Bool, _ includeScreenshot: Bool) async -> TabToolResult {
    let normalized: String
    switch validateOpenUrl(url) {
    case let .ok(value):
        normalized = value
    case let .rejected(reason):
        return TabToolResult(output: reason, isError: true)
    }

    // Reuse an existing agent-controlled tab for the same agent + same URL.
    let existingTab = tabsWindow.tabs.orderedTabs.first { tab in
        guard let agentId = tab.browserAgentControlledAgentId, agentId == ctx.sessionId else { return false }
        return tab.url == normalized
    }
    if let existingTab {
        if use { ctx.session.setActiveBrowserTab(existingTab.id) }
        let lines = [
            "Reused existing tab (same agent, same URL): \(normalized)",
            "Tab ID: \(existingTab.id)",
            "No new tab created — operate on this id directly."
        ]
        return TabToolResult(
            output: lines.joined(separator: "\n"),
            tabId: existingTab.id,
            title: existingTab.title?.isEmpty == false ? existingTab.title : nil,
            url: normalized,
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

    var outputLines = ["Opened: \(normalized)", "Tab ID: \(tabId)"]
    if use {
        outputLines.append("This tab is now the one page_click, page_type, page_select, page_navigate, page_press_keys, page_wait_for and get_text address. The page below is a snapshot taken at open; nothing refreshes it for you. After any click, type or navigation, call manage_tabs read with this tab_id to see the current page. Pass use: false on open to skip taking it.")
    }
    if !opened.isError, let body = opened.output,
       !body.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
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

// MARK: - Action: close

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
        let title = tab.title?.isEmpty == false ? tab.title! : "Untitled"
        return TabToolResult(
            output: "Cannot close \"\(title)\": it is the user's tab, not one you opened. "
                + "You may only close tabs opened by manage_tabs.",
            isError: true)
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

// MARK: - Action: use

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

// MARK: - Action: unuse

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

// MARK: - Markdown URL inclusion

/// Whether interactive markdown carries the `href` of anchor elements.
///
/// Replaces a feature-flag read (`FeatureFlagsCache` -> a remote flag table) with the
/// env-var pattern the rest of this package already uses. OFF by default, which is what
/// the flag's own default was: URLs multiply the size of a link-dense page's markdown,
/// and the ids are what the page tools address, not the hrefs. Set
/// `ALOHAJET_MARKDOWN_URLS=1` to include them. Read via `getenv` so a test's `setenv`
/// is observed immediately.
func includeUrlsInMarkdownEnabled() -> Bool {
    guard let raw = getenv("ALOHAJET_MARKDOWN_URLS") else { return false }
    switch String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "1", "true", "yes", "on": return true
    default: return false
    }
}
