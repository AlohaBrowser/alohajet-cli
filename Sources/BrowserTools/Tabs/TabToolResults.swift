import Foundation
import ToolABI

/// One tab as the agent is shown it: what the tab row (``renderTabRow(_:askingChat:)``)
/// prints. `manage_tabs list` and alohajet's tab summary build their rows here.
public struct TabRow: Equatable, Sendable {
    public var id: String
    public var title: String
    public var url: String
    public var attribution: TabAttribution
    /// Whether this is the tab in use: the one the page tools act on.
    public var inUse: Bool

    /// The one way to build a row: from the tab, and the id ``inUseTabId(session:tabs:)``
    /// resolved. It is the one place that names an untitled tab "Untitled" and hides a
    /// non-web address, so every surface describes a tab the same way.
    public init(_ tab: TabHandle, inUseTabId: String?) {
        id = tab.id
        title = tab.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled"
        // Non-http(s) addresses are hidden so a row does not leak a local file path (the
        // page tools refuse to act on such tabs; the path itself is the secret).
        if case .rejected = validateTabUrl(TabUrlInput(url: tab.url)) {
            url = "[non-web URL hidden]"
        } else {
            url = tab.url
        }
        attribution = tab.attribution
        inUse = tab.id == inUseTabId
    }
}

/// The tab row, the one line that describes a tab to the agent, as `askingChat` is told it:
/// `<title> [<url>] (tab-id: <id>) — <whose tab>[, the tab the user is looking at][, in use]`.
/// Whose tab is exactly "the user's tab", "your tab" or "another chat's tab (chat <id>)".
///
/// Words, not decorations: the agent has to know which tabs are its own and which one its
/// page tools act on, and a pictogram it has to guess the meaning of tells it neither. A
/// tool prints its own words about what happened around the row, never inside it.
public func renderTabRow(_ row: TabRow, askingChat: String) -> String {
    let owner = switch row.attribution.ownerView(askingChat: askingChat) {
    case .user: "the user's tab"
    case .askingChat: "your tab"
    case .otherChat(let chat): "another chat's tab (chat \(chat))"
    }
    var words = [owner]
    if row.attribution.foreground == true { words.append("the tab the user is looking at") }
    if row.inUse { words.append("in use") }
    return "\(row.title) [\(row.url)] (tab-id: \(row.id)) — \(words.joined(separator: ", "))"
}

/// Raw result of a tab builtin, before being shaped into an SDK-facing value.
public struct TabToolResult: Equatable, Sendable {
    public var output: String?
    public var isError: Bool
    public var error: String?
    public var tabId: String?
    public var title: String?
    public var url: String?
    public var faviconUrl: String?
    public var previousTabId: String?
    public var tabs: [TabRow]?
    public var matches: [AlohaIdMatch]?
    /// Viewport screenshots this action captured, carried on the result to the
    /// `RawToolResult` the executor returns. Empty unless `include_screenshot`
    /// asked for one.
    public var images: [ParsedDataUrlImage]

    public init(
        output: String? = nil, isError: Bool = false, error: String? = nil, tabId: String? = nil,
        title: String? = nil, url: String? = nil, faviconUrl: String? = nil,
        previousTabId: String? = nil, tabs: [TabRow]? = nil, matches: [AlohaIdMatch]? = nil,
        images: [ParsedDataUrlImage] = []
    ) {
        self.output = output
        self.isError = isError
        self.error = error
        self.tabId = tabId
        self.title = title
        self.url = url
        self.faviconUrl = faviconUrl
        self.previousTabId = previousTabId
        self.tabs = tabs
        self.matches = matches
        self.images = images
    }
}

/// What a tab tool's result knows about the tab it touched: the id the runtime
/// addresses it by, plus the two things a PERSON recognises it by.
///
/// A tab tool is called BY id — `{action:"read", tabId:"tab-4FB963B7-6FB"}` — so its
/// arguments name nothing anybody has ever seen, while the executor holds the tab's
/// title and url the whole time. This is that pair, carried on the result's
/// `metadata` (which reaches no model — only `llmAttrs` keys do) exactly as
/// `present_files` carries its files, so a surface that names the step can name the
/// PAGE instead of printing a handle.
public nonisolated struct AgentTabIdentity: Equatable, Sendable {
    public var tabId: String?
    public var title: String?
    public var url: String?

    public init(tabId: String? = nil, title: String? = nil, url: String? = nil) {
        self.tabId = tabId
        self.title = title
        self.url = url
    }

    public var metadata: [String: WorkflowValue] {
        var out: [String: WorkflowValue] = [:]
        if let tabId, !tabId.isEmpty { out["tabId"] = .string(tabId) }
        if let title, !title.isEmpty { out["title"] = .string(title) }
        if let url, !url.isEmpty { out["url"] = .string(url) }
        return out
    }

    public static func decode(toolMetadata: [String: WorkflowValue]?) -> AgentTabIdentity? {
        func string(_ key: String) -> String? {
            if case let .string(value)? = toolMetadata?[key], !value.isEmpty { return value }
            return nil
        }
        let identity = AgentTabIdentity(
            tabId: string("tabId"), title: string("title"), url: string("url"))
        return identity == AgentTabIdentity() ? nil : identity
    }
}

extension TabToolResult {
    /// The tab this result named, for the metadata channel. `nil` when the action
    /// named no single tab: a list, an unfocus, or a failure that never got one. A
    /// failure that DID get one names it — the call still happened on that page,
    /// and a reader counting pages must not count the three failed attempts.
    public var tabIdentity: AgentTabIdentity? {
        let identity = AgentTabIdentity(tabId: tabId, title: title, url: url)
        return identity.metadata.isEmpty ? nil : identity
    }
}

public enum SdkTabResult: Equatable, Sendable {
    case error(String)
    case read(String)
    case open(tabId: String, title: String?, url: String, faviconUrl: String?)
    case close(tabId: String, title: String?, url: String?, faviconUrl: String?)
    case focus(tabId: String)
    case unfocus(previousTabId: String?)
    case list([TabRow])
    case findByText([AlohaIdMatch])
}

public func toolErrorToSdkError(_ result: TabToolResult) -> SdkTabResult {
    if let output = result.output, !output.isEmpty {
        return .error(output)
    }
    if let error = result.error, !error.isEmpty {
        return .error(error)
    }
    if result.error != nil {
        return .error("")  // non-string truthy errors collapse to String(error); empty here
    }
    return .error("Unknown tool error")
}

public func sdkReadResult(_ result: TabToolResult) -> SdkTabResult {
    if result.isError { return toolErrorToSdkError(result) }
    return .read(result.output ?? "")
}

public func sdkOpenResult(_ result: TabToolResult) -> SdkTabResult {
    if result.isError { return toolErrorToSdkError(result) }
    guard let tabId = result.tabId, let url = result.url, !tabId.isEmpty, !url.isEmpty else {
        return .error("openTab succeeded but returned no tabId — internal bug, please report.")
    }
    return .open(tabId: tabId, title: result.title, url: url, faviconUrl: result.faviconUrl)
}

public func sdkCloseResult(_ result: TabToolResult, _ fallbackTabId: String) -> SdkTabResult {
    if result.isError { return toolErrorToSdkError(result) }
    return .close(
        tabId: result.tabId ?? fallbackTabId, title: result.title, url: result.url,
        faviconUrl: result.faviconUrl)
}

public func sdkFocusResult(_ result: TabToolResult, _ fallbackTabId: String) -> SdkTabResult {
    if result.isError { return toolErrorToSdkError(result) }
    return .focus(tabId: result.tabId ?? fallbackTabId)
}

public func sdkUnfocusResult(_ result: TabToolResult) -> SdkTabResult {
    if result.isError { return toolErrorToSdkError(result) }
    return .unfocus(previousTabId: result.previousTabId)
}

public func sdkListResult(_ result: TabToolResult) -> SdkTabResult {
    if result.isError { return toolErrorToSdkError(result) }
    return .list(result.tabs ?? [])
}

public func sdkFindByTextResult(_ result: TabToolResult) -> SdkTabResult {
    if result.isError { return toolErrorToSdkError(result) }
    return .findByText(result.matches ?? [])
}

public func abortedResultOrNull(_ aborted: Bool) -> TabToolResult? {
    aborted ? TabToolResult(output: executionStoppedError, isError: true) : nil
}

public func abortedSdkErrorOrNull(_ aborted: Bool) -> SdkTabResult? {
    aborted ? .error(executionStoppedError) : nil
}

public func isAbortLikeError(_ error: Error?) -> Bool {
    guard let error else { return false }
    if let named = error as? NamedAbortError, named.name == "AbortError" || named.name == "TimeoutError" {
        return true
    }
    let message = (error as? LocalizedMessageError)?.message ?? String(describing: error)
    return message.range(of: "\\baborted?\\b", options: [.regularExpression, .caseInsensitive]) != nil
}

/// An error carrying a JS-style `name` discriminator.
public struct NamedAbortError: Error, Equatable, Sendable {
    public let name: String
    public let message: String
    public init(name: String, message: String = "") {
        self.name = name
        self.message = message
    }
}

public protocol LocalizedMessageError: Error {
    var message: String { get }
}

public func clampScreenshotTimeout(_ timeoutMs: Double?) -> Double {
    guard let timeoutMs, timeoutMs.isFinite else {
        return Double(maxScreenshotCaptureTimeoutMs)
    }
    return max(1, min(timeoutMs - 1, Double(maxScreenshotCaptureTimeoutMs)))
}

public let executionStoppedError = "Execution stopped"

public let maxScreenshotCaptureTimeoutMs = 5_000
