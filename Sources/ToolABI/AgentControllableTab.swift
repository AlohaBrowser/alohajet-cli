import Foundation

/// A tab that may be marked agent-controlled before a tool drives it.
public protocol AgentControllableTab: AnyObject, Sendable {
    var browserAgentControlledAgentId: String? { get }
    var chatSessionId: String? { get set }
    var isAIControlledTab: Bool { get }
    var isBrowserAgentControlled: Bool { get }
    func setAIControlledTab(_ controlled: Bool, agentId: String?)
}

/// Marks a tab as agent-controlled for the supplied session unless it is already
/// controlled by this session or is AI-controlled without browser-agent
/// ownership.
public func markTabAgentControlled(
    _ tab: AgentControllableTab,
    sessionId: String,
    source: String
) {
    let alreadyOwned = tab.browserAgentControlledAgentId == sessionId && tab.chatSessionId == sessionId
    let aiButNotBrowser = tab.isAIControlledTab && !tab.isBrowserAgentControlled
    if alreadyOwned || aiButNotBrowser { return }
    tab.setAIControlledTab(false, agentId: sessionId)
    tab.chatSessionId = sessionId
}
