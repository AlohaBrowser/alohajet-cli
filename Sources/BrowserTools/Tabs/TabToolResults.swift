import Foundation
import ToolABI

/// A tab description as surfaced to the agent in list output.
public struct TabSummary: Equatable, Sendable {
    public var id: String
    public var title: String
    public var url: String
    public var isActive: Bool
    /// Whether the tab is the user's rather than this session's — rendered as the
    /// "user's tab" marker, and the reason `close` refuses it.
    public var openedByHuman: Bool
    public init(id: String, title: String, url: String, isActive: Bool, openedByHuman: Bool) {
        self.id = id
        self.title = title
        self.url = url
        self.isActive = isActive
        self.openedByHuman = openedByHuman
    }
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
    public var tabs: [TabSummary]?
    public var matches: [AlohaIdMatch]?
    /// Viewport screenshots this action captured, carried on the result to the
    /// `RawToolResult` the executor returns. Empty unless `include_screenshot`
    /// asked for one.
    public var images: [ParsedDataUrlImage]

    public init(
        output: String? = nil, isError: Bool = false, error: String? = nil, tabId: String? = nil,
        title: String? = nil, url: String? = nil, faviconUrl: String? = nil,
        previousTabId: String? = nil, tabs: [TabSummary]? = nil, matches: [AlohaIdMatch]? = nil,
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

    /// The identity a tab tool's result carried, or `nil` when it carried none.
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

/// SDK-facing representation: either an error or a typed success payload.
public enum SdkTabResult: Equatable, Sendable {
    case error(String)
    case read(String)
    case open(tabId: String, title: String?, url: String, faviconUrl: String?)
    case close(tabId: String, title: String?, url: String?, faviconUrl: String?)
    case focus(tabId: String)
    case unfocus(previousTabId: String?)
    case list([TabSummary])
    case findByText([AlohaIdMatch])
}

/// Coerces a failed tool result into a stable error string.
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

/// Renders the open-tab list into the agent-facing text block plus structured tabs.
public func listTabs(_ tabs: [TabSummary]) -> TabToolResult {
    let lines = tabs.enumerated().map { index, tab -> String in
        let activeMarker = tab.isActive ? "● " : ""
        // Named, not decorated: the agent has to know which tabs it may close, and a
        // pictogram it has to guess the meaning of is not that. `close` refuses these.
        let ownerMarker = tab.openedByHuman ? " [the user's tab — cannot be closed]" : ""
        return "\(index + 1). \(activeMarker)\(tab.title)\(ownerMarker)\n   ID: \(tab.id)\n   URL: \(tab.url)"
    }
    let joined = lines.joined(separator: "\n\n")
    return TabToolResult(
        output: "\(tabs.count) tab(s) open:\n\n\(joined)",
        tabs: tabs)
}

/// Returns an aborted-execution result when the signal is set, else `nil`.
public func abortedResultOrNull(_ aborted: Bool) -> TabToolResult? {
    aborted ? TabToolResult(output: executionStoppedError, isError: true) : nil
}

public func abortedSdkErrorOrNull(_ aborted: Bool) -> SdkTabResult? {
    aborted ? .error(executionStoppedError) : nil
}

/// Heuristically classifies an error as an abort/timeout.
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

/// An error carrying a plain message string.
public protocol LocalizedMessageError: Error {
    var message: String { get }
}

public func clampScreenshotTimeout(_ timeoutMs: Double?) -> Double {
    guard let timeoutMs, timeoutMs.isFinite else {
        return Double(maxScreenshotCaptureTimeoutMs)
    }
    return max(1, min(timeoutMs - 1, Double(maxScreenshotCaptureTimeoutMs)))
}

/// The output a tool returns when its abort signal is already set.
public let executionStoppedError = "Execution stopped"

/// The ceiling a screenshot capture timeout is clamped to.
public let maxScreenshotCaptureTimeoutMs = 5_000
