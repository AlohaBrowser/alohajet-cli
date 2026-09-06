import Foundation
import ToolABI


/// The narrow tab surface the step tracer captures from. A live `CDPTabHandle`
/// conforms (reaching its DOM service); tests provide a lightweight mock. Kept
/// minimal on purpose — the tracer needs only the identity plus the two capture
/// calls, not the full ``TabHandle`` protocol — so the capture path stays cheap
/// to satisfy and to fake.
public protocol StepTraceTab: Sendable {
    /// The tab's external id, recorded on each step.
    var traceTabId: String { get }
    /// The tab's current URL, recorded on each step.
    var traceTabURL: String { get }
    /// The tab's current title, recorded on each step (when known).
    var traceTabTitle: String? { get }

    /// Captures the page's interactive DOM markdown plus an optional base64 PNG
    /// screenshot. Best-effort: it may throw, which the tracer records as an error
    /// note rather than aborting the step.
    func captureInteractMarkdown() async throws -> StepTraceMarkdown

    /// Captures the page's full accessibility tree as a ``JSValue`` (the raw
    /// `Accessibility.getFullAXTree` result). Best-effort.
    func captureAccessibilityTree() async throws -> JSValue

    /// Resolves the serialized DOM node an `aloha_id` names, from the tab's LAST DOM
    /// snapshot — a pure cache read, never a fresh page round-trip, so tracing keeps
    /// costing the turn nothing.
    ///
    /// The tracer needs the node (not just the id) because `aloha_id` is a HASH —
    /// stable across walks, but nothing off the page can resolve or recompute it, so
    /// only the node's real attributes yield a re-resolvable selector (see
    /// ``stableCSSSelector(for:)``).
    /// Returns `nil` when the id is unknown to the current snapshot.
    func traceDomNode(forAlohaId alohaId: String) -> DomNode?
}

public extension StepTraceTab {
    /// Default: no node data. A capture surface that cannot reach a DOM snapshot
    /// records a null selector rather than forcing every conformance to fake one.
    func traceDomNode(forAlohaId alohaId: String) -> DomNode? { nil }
}

/// The DOM-markdown + screenshot pair the tracer writes for a step.
public nonisolated struct StepTraceMarkdown: Sendable {
    public var markdown: String
    public var screenshotBase64: String?
    public init(markdown: String, screenshotBase64: String?) {
        self.markdown = markdown
        self.screenshotBase64 = screenshotBase64
    }
}

