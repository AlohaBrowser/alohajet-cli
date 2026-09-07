import Foundation

// Deliberately narrow: only the members the browser tools actually call.

/// The session surface the browser tools address tabs through.
public protocol ChatModeSession: AnyObject, Sendable {
    /// The directory for `<tabId>.jsonl` network logs, or `nil` when network
    /// logging is off — which is the default. Recording a page's requests writes
    /// its headers and bodies to disk, so it happens only when a caller asks.
    func sessionNetworkDir() -> String?
    func registerNetworkRecordingTab(_ tab: TabHandle)
    func unregisterNetworkRecordingTab(_ tabId: String)
    func setActiveBrowserTab(_ tabId: String?)
    func getActiveBrowserTabId() -> String?
    func clearActiveBrowserTabIfMatches(_ tabId: String)
}
