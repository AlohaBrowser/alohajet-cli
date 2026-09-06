import Foundation
import ToolABI

// MARK: - Prompt section builder

/// A built prompt section with an estimated token count.
public nonisolated struct PromptSection: Sendable, Equatable {
    public var name: String
    public var tokens: Int
    public init(name: String, tokens: Int) {
        self.name = name
        self.tokens = tokens
    }
}

/// Builds a system-prompt string from appended text and tagged sections,
/// tracking per-section token estimates.
public final class PromptSectionBuilder {
    private var parts: [String] = []
    private var sections: [PromptSection] = []
    private var currentSectionStart = 0

    public init() {}

    /// Appends non-empty text.
    @discardableResult
    public func append(_ text: String?) -> PromptSectionBuilder {
        if let text, !text.isEmpty { parts.append(text) }
        return self
    }

    /// Appends `count` (>=1) newlines.
    @discardableResult
    public func newline(_ count: Int = 1) -> PromptSectionBuilder {
        parts.append(String(repeating: "\n", count: max(1, count)))
        return self
    }

    /// Wraps `content` in a named XML-like tag with optional attributes,
    /// recording the section's token estimate. Empty content is a no-op.
    @discardableResult
    public func section(_ name: String, _ content: String?, _ attributes: [(String, String)] = []) -> PromptSectionBuilder {
        guard let content, !content.isEmpty else { return self }
        let attrText = attributes.isEmpty
            ? ""
            : " " + attributes.map { "\($0.0)=\"\($0.1)\"" }.joined(separator: " ")
        let block = "\n<\(name)\(attrText)>\n\(content)\n</\(name)>\n"
        parts.append(block)
        sections.append(PromptSection(name: name, tokens: estimateTokenCount(block)))
        return self
    }

    /// Opens a section tag, marking the start of accumulated content.
    @discardableResult
    public func open(_ name: String) -> PromptSectionBuilder {
        currentSectionStart = parts.count
        parts.append("\n<\(name)>")
        return self
    }

    /// Closes a section tag, recording the accumulated content's token estimate.
    @discardableResult
    public func close(_ name: String) -> PromptSectionBuilder {
        parts.append("\n</\(name)>\n")
        let content = parts[currentSectionStart...].joined()
        sections.append(PromptSection(name: name, tokens: estimateTokenCount(content)))
        return self
    }

    /// Returns the joined prompt string.
    public func build() -> String {
        parts.joined()
    }

    /// Returns a copy of the recorded sections.
    public func getSections() -> [PromptSection] {
        sections
    }

    /// Returns the token estimate of the entire built prompt.
    public func getTotalTokens() -> Int {
        estimateTokenCount(build())
    }
}

// MARK: - Open tabs context provider

/// A tab summarized in the open-tabs context.
public struct OpenTabSummary: Sendable, Equatable {
    public var id: String
    public var url: String
    public init(id: String, url: String) {
        self.id = id
        self.url = url
    }
}

/// The open-tabs data snapshot.
public struct OpenTabsData: Sendable, Equatable {
    public var activeTab: OpenTabSummary?
    public var otherTabs: [OpenTabSummary]
    public var allTabs: [OpenTabSummary]
    public init(activeTab: OpenTabSummary?, otherTabs: [OpenTabSummary], allTabs: [OpenTabSummary]) {
        self.activeTab = activeTab
        self.otherTabs = otherTabs
        self.allTabs = allTabs
    }
}

/// The host the open-tabs provider consults for tab data, change tracking, and
/// summary formatting.
///
/// `@MainActor`: the open-tabs provider consumes it during request assembly, and
/// the session-backed conformer's change-tracking reads the main-isolated
/// orchestration.
@MainActor
public protocol OpenTabsContextHost: AnyObject {
    func getOpenTabsData() -> OpenTabsData?
    func getTabContextKey(_ tab: OpenTabSummary) -> String
    func hasContextTrackKey(_ key: String) -> Bool
    func formatTabsSummary(_ activeTab: OpenTabSummary?, _ otherTabs: [OpenTabSummary], _ isUpdate: Bool, _ totalCount: Int) -> String
}

/// Injects a summary of the browser's open tabs, skipping tabs already tracked
/// in context and the whole section when nothing changed.
public final class OpenTabsContextProvider {
    public let id = "open-tabs"

    public init() {}

    public func shouldInject() -> Bool { true }

    /// Builds the open-tabs section, pushing newly-included tab context keys onto
    /// `trackedKeys`. Returns nil when there is no data or nothing changed.
    public func inject(_ host: OpenTabsContextHost, trackedKeys: inout [String]) -> String? {
        guard let data = host.getOpenTabsData() else { return nil }
        let changedActive: OpenTabSummary? = {
            if let active = data.activeTab, !host.hasContextTrackKey(host.getTabContextKey(active)) {
                return active
            }
            return nil
        }()
        let changedOthers = data.otherTabs.filter { !host.hasContextTrackKey(host.getTabContextKey($0)) }
        if changedActive == nil && changedOthers.isEmpty {
            agentLog(.info, "[open-tabs] skipping (all tabs unchanged), total=\(data.allTabs.count)")
            return nil
        }
        let isUpdate = data.allTabs.count != (changedActive != nil ? 1 : 0) + changedOthers.count
        let summary = host.formatTabsSummary(changedActive, changedOthers, isUpdate, data.allTabs.count)
        if let changedActive { trackedKeys.append(host.getTabContextKey(changedActive)) }
        for tab in changedOthers { trackedKeys.append(host.getTabContextKey(tab)) }
        agentLog(.info, """
            [open-tabs] including summary, changedActive=\(changedActive != nil) \
            changedOthers=\(changedOthers.count) total=\(data.allTabs.count) isUpdate=\(isUpdate)
            """)
        return "\(summary)\n\n\(openTabsDisclaimer)"
    }
}

/// Disclaimer appended to the open-tabs prompt section built above.
private let openTabsDisclaimer = "These are open tabs from the browser. They represent general browser state across sessions and may not be relevant to the current chat unless the user refers to them or attaches one."
