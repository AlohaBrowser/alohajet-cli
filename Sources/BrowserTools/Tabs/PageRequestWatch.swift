import Foundation
import ToolABI
import CDP

// MARK: - Is the page still waiting for the answer to what a step just did?
//
// A scenario runner (the agent repository's snips replay) dispatches a write -- a click on a
// filter, a submit -- and must not plan the next step against the page as it was. It settles on
// the DOM going quiet, and that is not enough on its own:
//
// MEASURED (github.com search, 2026-09-28, `probe-click-settle.mjs`): a click on the "Go" language
// filter sent ONE fetch at 36 ms that answered at 577 ms; the page swapped its list for a loading
// state at 109 ms and then held still until the URL changed at 604 ms and the results landed at
// 719 ms. A DOM-quiet rule (400 ms unchanged) called that page settled at ~570 ms, and
// github-ss-r54 planned its next three steps against the old list -- the Go filter was lost and
// "open the first repository" clicked nothing. The fetch was in flight the whole time the page
// looked quiet; that is the signal a request watch counts.
//
// Ported from the agent repository (alohajet windows-on-snips f47bf4ac: `PageRequestWatching` and
// `PageRequestCounter` in WriteDispatchBackend.swift, `startPageRequestWatch` and
// `CDPPageRequestWatch` in its CDPTabsService.swift), because the tab and its CDP session now live
// in this package: the agent's runner asks ``CDPTabHandle/startPageRequestWatch()`` and consumes
// the protocol from here.

/// A running watch on the requests a page sends, started just before a write. The step runner
/// asks it whether the page is still waiting for an answer before it plans the next step.
/// `nonisolated` so a runner (or a test fake) may conform and call it from any isolation.
public nonisolated protocol PageRequestWatching: AnyObject, Sendable {
    /// Page-changing requests sent since the watch started that have not finished.
    func inFlight() -> Int
    /// Stop watching. Idempotent; the watch also stops when its last reference goes.
    func stop()
}

/// The counting rule of a request watch, apart from any transport: fed CDP `Network.*` events,
/// it tracks the requests that can change what the page shows -- a document, a fetch, an XHR --
/// and ignores images, fonts, scripts, beacons, pings and persistent streams (the same
/// ``PageReadinessClassifier`` rule the page-readiness wait uses).
public nonisolated final class PageRequestCounter: @unchecked Sendable {
    /// CDP resource types whose answer can change the page.
    public static let countedTypes: Set<String> = ["Document", "Fetch", "XHR"]

    private let lock = NSLock()
    private var pending: Set<String> = []
    private let classifier = PageReadinessClassifier()

    public init() {}

    /// Feed one CDP event. Only `Network.requestWillBeSent` / `loadingFinished` /
    /// `loadingFailed` matter; anything else is ignored.
    public func handle(method: String, params: JSValue) {
        switch method {
        case "Network.requestWillBeSent":
            guard let id = params.string("requestId"), let request = params["request"],
                  let url = request.string("url"), !url.hasPrefix("data:") else { return }
            let type = params.string("type") ?? ""
            guard Self.countedTypes.contains(type) else { return }
            let probe = PageReadinessRequest(url: url, type: type, acceptHeader: request["headers"]?.string("Accept"))
            if classifier.isPersistentConnection(probe) { return }
            lock.lock(); pending.insert(id); lock.unlock()
        case "Network.loadingFinished", "Network.loadingFailed":
            guard let id = params.string("requestId") else { return }
            lock.lock(); pending.remove(id); lock.unlock()
        default:
            return
        }
    }

    /// Counted requests still waiting for their answer.
    public func inFlight() -> Int {
        lock.lock(); defer { lock.unlock() }
        return pending.count
    }
}

/// A ``PageRequestWatching`` over one tab's CDP session: a detached task feeds the session's
/// events into a ``PageRequestCounter`` until ``stop()`` or the last reference goes, and then
/// ends the client subscription it read them from.
nonisolated final class CDPPageRequestWatch: PageRequestWatching, @unchecked Sendable {
    private let counter = PageRequestCounter()
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var end: (@Sendable () async -> Void)?

    /// Starts counting `events` (a client-wide stream) that belong to `sessionId`; `end` ends the
    /// subscription the stream came from.
    func start(_ events: AsyncStream<CDPEvent>, sessionId: String, end: @escaping @Sendable () async -> Void) {
        let counter = self.counter
        let task = Task.detached {
            for await event in events {
                if Task.isCancelled { break }
                guard event.sessionId == sessionId else { continue }
                counter.handle(method: event.method, params: event.params)
            }
        }
        lock.lock(); self.task = task; self.end = end; lock.unlock()
    }

    func inFlight() -> Int { counter.inFlight() }

    func stop() {
        lock.lock()
        let task = self.task, end = self.end
        self.task = nil
        self.end = nil
        lock.unlock()
        task?.cancel()
        if let end { Task.detached { await end() } }
    }

    deinit { stop() }
}

extension CDPTabHandle {
    /// Starts counting the page-changing requests this tab sends from now (see
    /// ``PageRequestCounter``): a scenario runner calls it just before a click so it can tell a
    /// page still waiting for its answer from one that is done, and ``PageRequestWatching/stop()``s
    /// it once settled. The subscription is registered before `Network.enable` is sent and both
    /// before this returns, so a fetch the click sends a few milliseconds later is seen. nil when
    /// the tab is gone or cannot be attached. Best-effort: a page that never answers is the
    /// runner's ceiling to bound, not this watch's.
    public func startPageRequestWatch() async -> PageRequestWatching? {
        if session.isDestroyed { return nil }
        guard let sessionId = try? await session.ensureAttached() else { return nil }
        let client = session.client
        let subscription = UUID()
        let events = await client.subscribeEvents(id: subscription)
        let watch = CDPPageRequestWatch()
        watch.start(events, sessionId: sessionId, end: { await client.endEventSubscription(subscription) })
        _ = try? await client.send(method: "Network.enable", params: [:], sessionId: sessionId)
        return watch
    }
}
