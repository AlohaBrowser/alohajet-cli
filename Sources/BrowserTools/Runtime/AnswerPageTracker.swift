import Foundation
import ToolABI

// MARK: - The page the answer was read from

/// Which tab the agent looked at last, so the turn's answer receipts (``AnswerReceipt``) are taken
/// on the page the answer came from and nowhere else.
///
/// Every page tool reaches its tab through `makePageBridge` -- a click, a type, a select, a key
/// press, a `get_text`, a `manage_tabs` read / open (the main-heading line) -- so that is where an
/// observation is noted, by the tab's CDP target id. hn-swift-r80 (2026-10-01) closed the tab it
/// had read and the turn end then took receipts on another tab, which held nothing: a receipt has
/// to come from the observed page or not at all.
///
/// CLOSES OF THAT TAB WAIT FOR THE RECEIPTS. Closing a tab is housekeeping, so while a runner has
/// enabled deferral, an agent's `manage_tabs` close of the observed tab is answered as done,
/// recorded, and carried out by the runner after the receipts (``takeDeferredCloses()``, or
/// ``closeDeferredTabs(in:)``). Other tabs close at once. Off by default: only a runner that
/// flushes at turn end turns it on, so nothing else ever keeps a tab open.
///
/// WHICH TRACKER. The page tools note into ``current``: the tracker a runner bound around its turn
/// with ``tracking(_:)`` (a task-local, so it reaches every tool the turn's task runs, and no other
/// turn's), else the process-wide ``shared`` -- the agent repository's original shape. A host that
/// runs one turn at a time can use ``shared`` and nothing else. A host that runs several chats'
/// turns at once keeps a tracker per chat and runs each turn inside its ``tracking(_:)``; with
/// ``shared`` alone the chats would share one "latest observation", and the worst case is a receipt
/// looked for on the other chat's page, where the answer's words are not, so none is written.
///
/// Ported from AlohaBrowser/alohajet `Sources/AgentRuntime/AnswerPageTracker.swift` (branch
/// windows-on-snips, dc514f76..a74a7d63): the page tools moved into this package, so the tracker
/// they feed moved with them.
public final class AnswerPageTracker {
    public static let shared = AnswerPageTracker()

    /// The tracker the page tools note into now: the one bound by ``tracking(_:)`` around the
    /// running turn, else ``shared``.
    public static var current: AnswerPageTracker { bound ?? shared }

    @TaskLocal static var bound: AnswerPageTracker?

    /// Runs `body` -- a runner's whole turn -- with this tracker as ``current``, so the page tools
    /// the turn runs note into it. Tools a turn starts in a DETACHED task do not inherit it and
    /// note into ``shared``.
    public func tracking<T>(_ body: () async throws -> T) async rethrows -> T {
        try await Self.$bound.withValue(self) { try await body() }
    }

    /// The CDP target id of the tab of the latest observation; nil before any page tool ran.
    public private(set) var observedTargetId: String?
    /// Whether closes of the observed tab are deferred to the runner's turn end.
    public private(set) var defersCloses = false
    private var deferred: [String] = []
    /// The elements `get_text` read this turn, oldest first, by tab: the answer receipt prefers
    /// them over another element with the same text (see ``AnswerReceipt``).
    private var reads: [(targetId: String, alohaId: String)] = []

    /// A tracker of its own, for a host that keeps one per chat (bound with ``tracking(_:)``) or a
    /// test.
    public init() {}

    /// A page tool is about to act on, or read, `targetId`'s page.
    func noteObservation(targetId: String) { observedTargetId = targetId }

    /// `get_text` read the element `alohaId` on the page of the latest observation.
    func noteRead(alohaId: String) {
        guard let targetId = observedTargetId, !alohaId.isEmpty else { return }
        reads.removeAll { $0.targetId == targetId && $0.alohaId == alohaId }
        reads.append((targetId, alohaId))
    }

    /// The aloha-ids read on `targetId`'s page this turn, oldest first, each once (a re-read moves
    /// it last).
    public func readIds(onTarget targetId: String) -> [String] {
        reads.filter { $0.targetId == targetId }.map(\.alohaId)
    }

    /// A runner starts a turn: forget the last turn's page and reads, and defer closes when it will
    /// flush them. Closes still waiting from a turn that was never flushed are dropped (their tabs
    /// stay open), never carried into this one.
    public func beginTurn(deferringCloses: Bool) {
        observedTargetId = nil
        deferred = []
        reads = []
        defersCloses = deferringCloses
    }

    /// Should the close of the tab whose CDP target id is `targetId` (tabs-model id `tabId`) wait?
    /// Records it when so.
    func deferCloseIfObserved(tabId: String, targetId: String?) -> Bool {
        guard defersCloses, let targetId, targetId == observedTargetId else { return false }
        if !deferred.contains(tabId) { deferred.append(tabId) }
        return true
    }

    /// Whether a close of `tabId` is waiting for the turn end.
    public func isCloseDeferred(tabId: String) -> Bool { deferred.contains(tabId) }

    /// The tabs-model ids of the closes that waited, in request order; empties the list and stops
    /// deferring for the rest of the turn.
    public func takeDeferredCloses() -> [String] {
        let out = deferred
        deferred = []
        defersCloses = false
        return out
    }

    /// Carries out the closes that waited (``takeDeferredCloses()``) on `tabsWindow`, in request
    /// order, and returns the ids closed. A tab already gone is skipped. For the runner, right after
    /// it took the answer receipts.
    @discardableResult
    public func closeDeferredTabs(in tabsWindow: TabsWindow) async -> [String] {
        var closed: [String] = []
        for tabId in takeDeferredCloses() where tabsWindow.tabs.tab(tabId) != nil {
            await tabsWindow.tabs.closeTab(tabId, skipConfirm: true)
            closed.append(tabId)
        }
        return closed
    }

    /// The live tab of the latest observation in `tabsWindow`, when it is still open: the page the
    /// answer receipts are taken on. nil before any page tool ran this turn, or when that tab is
    /// gone.
    public func observedTab(in tabsWindow: TabsWindow) -> CDPTabHandle? {
        guard let observedTargetId else { return nil }
        return tabsWindow.tabs.orderedTabs.lazy.compactMap { $0 as? CDPTabHandle }
            .first { $0.id == observedTargetId }
    }
}
