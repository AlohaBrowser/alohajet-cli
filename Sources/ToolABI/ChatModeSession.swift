import Foundation

// Deliberately narrow: only the members the browser tools actually call.

/// The session surface the browser tools address tabs through: which tab the page
/// commands operate on, and where a tab's network log is written.
public protocol ChatModeSession: AnyObject, Sendable {
    /// The directory for `<tabId>.jsonl` network logs, or `nil` when network
    /// logging is off — which is the default. Recording a page's requests writes
    /// its headers and bodies to disk, so it happens only when a caller asks.
    func sessionNetworkDir() -> String?
    /// Registers a tab as network-recording.
    func registerNetworkRecordingTab(_ tab: TabHandle)
    /// Unregisters a network-recording tab by id.
    func unregisterNetworkRecordingTab(_ tabId: String)
    /// Sets (or clears) the active browser tab.
    func setActiveBrowserTab(_ tabId: String?)
    /// Returns the active browser tab id, or `nil`.
    func getActiveBrowserTabId() -> String?
    /// Clears the active browser tab when it matches `tabId`.
    func clearActiveBrowserTabIfMatches(_ tabId: String)
}
