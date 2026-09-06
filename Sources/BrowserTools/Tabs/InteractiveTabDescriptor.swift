import Foundation

// MARK: - Interactive web tab

/// A minimal tab descriptor for the interactive-web-tab predicate.
public struct InteractiveTabDescriptor: Equatable, Sendable {
    public var tabType: String
    public var hasAgentDom: Bool
    public init(tabType: String, hasAgentDom: Bool) {
        self.tabType = tabType
        self.hasAgentDom = hasAgentDom
    }
}

/// Whether a tab is an interactive website tab: its type is `website` and it has
/// an attached agent DOM.
public func isInteractiveWebTab(_ tab: InteractiveTabDescriptor) -> Bool {
    tab.tabType == "website" && tab.hasAgentDom
}
