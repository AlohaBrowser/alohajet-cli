import Foundation

public struct InteractMarkdownResult: Sendable {
    public struct Diagnostics: Sendable {
        public var domError: String?
        public var serializeError: String?
        public var screenshotError: String?
        public init(domError: String? = nil, serializeError: String? = nil, screenshotError: String? = nil) {
            self.domError = domError
            self.serializeError = serializeError
            self.screenshotError = screenshotError
        }
    }
    public var markdown: String
    public var screenshot: String?
    public var diagnostics: Diagnostics
    public init(markdown: String, screenshot: String?, diagnostics: Diagnostics) {
        self.markdown = markdown
        self.screenshot = screenshot
        self.diagnostics = diagnostics
    }
}

public protocol AgentDOMSnapshotting: Sendable {
    func getInteractMarkdown(_ includeScreenshot: Bool, _ b: Bool, includeUrls: Bool) async throws -> InteractMarkdownResult
    /// Signal-bearing overload: manage_tabs passes the per-action abort signal
    /// through so read and findByText snapshots can be cancelled.
    func getInteractMarkdown(_ includeScreenshot: Bool, _ b: Bool, includeUrls: Bool, signal: AbortSignal?) async throws -> InteractMarkdownResult
    /// Options-bearing overload: carries the full ``DomSerializeOptions`` (the
    /// toggleable web-extraction improvements) so manage_tabs can thread the resolved
    /// flags into serialization. The default maps it back to the `includeUrls`-only
    /// overload, so existing conformers keep working and the BASELINE options (every
    /// improvement off) are byte-identical to the prior call.
    func getInteractMarkdown(_ includeScreenshot: Bool, _ b: Bool, serializeOptions: DomSerializeOptions, signal: AbortSignal?) async throws -> InteractMarkdownResult
}

public extension AgentDOMSnapshotting {
    /// Default forwards the signal-bearing call to the no-signal method so the
    /// existing injector conformers keep satisfying the protocol.
    func getInteractMarkdown(_ includeScreenshot: Bool, _ b: Bool, includeUrls: Bool, signal: AbortSignal?) async throws -> InteractMarkdownResult {
        try await getInteractMarkdown(includeScreenshot, b, includeUrls: includeUrls)
    }

    /// Default maps the options-bearing call onto the `includeUrls`-only overload, so a
    /// conformer that only knows `includeUrls` still serves it and the baseline options
    /// produce exactly the prior result.
    func getInteractMarkdown(_ includeScreenshot: Bool, _ b: Bool, serializeOptions: DomSerializeOptions, signal: AbortSignal?) async throws -> InteractMarkdownResult {
        try await getInteractMarkdown(includeScreenshot, b, includeUrls: serializeOptions.includeUrls, signal: signal)
    }
}

public protocol InjectorTab: AnyObject, Sendable {
    var id: String { get }
    var tabType: String { get }
    var url: String? { get }
    var title: String? { get }
    var agentDOM: AgentDOMSnapshotting? { get }
    func ensureLoaded() async throws -> Bool
    func hasWebContents() -> Bool
    func waitForNextAnimationFrames(_ count: Int) async throws
}

public nonisolated struct WakeResult: Sendable, Equatable {
    public var ok: Bool
    public var message: String?
    public init(ok: Bool, message: String? = nil) {
        self.ok = ok
        self.message = message
    }
}

/// Ensures a website tab is awake and has live web contents before snapshotting.
/// Non-website tabs are always considered ready.
public func wakeTab(_ tab: InjectorTab) async -> WakeResult {
    guard tab.tabType == "website" else { return WakeResult(ok: true) }
    do {
        guard try await tab.ensureLoaded() else {
            return WakeResult(ok: false, message: "Tab \"\(tab.id)\" is unavailable because it failed to wake or finish loading.")
        }
        guard tab.hasWebContents() else {
            return WakeResult(ok: false, message: "Tab \"\(tab.id)\" is unavailable because it has no live WebContents.")
        }
        return WakeResult(ok: true)
    } catch {
        let message = (error as? AbortSignalError)?.message ?? "\(error)"
        return WakeResult(ok: false, message: "Tab \"\(tab.id)\" is unavailable because it failed to wake: \(message)")
    }
}
