import Testing
import Foundation
import ToolABI
import CDP
@testable import BrowserTools

@Suite("DOM stability MutationObserver script")
struct DomStabilityScriptTests {
    @Test func scriptObservesMainContentNodeWithDebounce() {
        let script = buildDomStabilityScript(stableTimeMs: 400)
        #expect(script.contains("new MutationObserver"))
        #expect(script.contains("'#app, #root, main, [role=\"main\"]'"))
        #expect(script.contains("|| document.body"))
        #expect(script.contains("childList: true"))
        #expect(script.contains("subtree: true"))
        #expect(script.contains("attributes: false"))
        #expect(script.contains("var stableTime = 400"))
    }

    @Test func scriptHasTenSecondSafetyCap() {
        let script = buildDomStabilityScript(stableTimeMs: 250)
        #expect(script.contains("10000"))
        #expect(script.contains("observer.disconnect()"))
        #expect(script.contains("resolve()"))
    }

    @Test func scriptHasNoForbiddenToken() {
        let script = buildDomStabilityScript(stableTimeMs: 300).lowercased()
        #expect(!script.contains("straw" + "berry"))
        #expect(!script.contains("berry"))
    }
}

@Suite("PageReadinessNetworkTracker")
struct PageReadinessNetworkTrackerTests {
    private func requestEvent(_ id: String, url: String, type: String = "XHR", accept: String? = nil) -> CDPEvent {
        var headers: [(String, JSValue)] = []
        if let accept { headers.append(("Accept", .string(accept))) }
        let request = JSValue.object([
            ("url", .string(url)),
            ("method", .string("GET")),
            ("headers", .object(headers)),
        ])
        return CDPEvent(method: "Network.requestWillBeSent", params: .object([
            ("requestId", .string(id)),
            ("type", .string(type)),
            ("request", request),
        ]))
    }

    private func finishedEvent(_ id: String) -> CDPEvent {
        CDPEvent(method: "Network.loadingFinished", params: .object([("requestId", .string(id))]))
    }

    @Test func countsInFlightRequests() {
        let tracker = PageReadinessNetworkTracker(classifier: PageReadinessClassifier())
        tracker.handle(requestEvent("r1", url: "https://x.test/a"))
        tracker.handle(requestEvent("r2", url: "https://x.test/b"))
        #expect(tracker.inFlightCount() == 2)
        tracker.handle(finishedEvent("r1"))
        #expect(tracker.inFlightCount() == 1)
    }

    @Test func loadingFailedAlsoRemoves() {
        let tracker = PageReadinessNetworkTracker(classifier: PageReadinessClassifier())
        tracker.handle(requestEvent("r1", url: "https://x.test/a"))
        tracker.handle(CDPEvent(method: "Network.loadingFailed", params: .object([("requestId", .string("r1"))])))
        #expect(tracker.inFlightCount() == 0)
    }

    @Test func ignoresDataUrls() {
        let tracker = PageReadinessNetworkTracker(classifier: PageReadinessClassifier())
        tracker.handle(requestEvent("r1", url: "data:image/png;base64,AAAA"))
        #expect(tracker.inFlightCount() == 0)
    }

    @Test func excludesPersistentConnections() {
        let tracker = PageReadinessNetworkTracker(classifier: PageReadinessClassifier())
        // WebSocket and SSE/long-poll do not count towards the in-flight total.
        tracker.handle(requestEvent("ws", url: "https://x.test/socket", type: "WebSocket"))
        tracker.handle(requestEvent("sse", url: "https://x.test/events", accept: "text/event-stream"))
        tracker.handle(requestEvent("an", url: "https://google-analytics.com/collect"))
        #expect(tracker.inFlightCount() == 0)
    }

    @Test func networkIdleAccumulatesWhileAtOrBelowThreshold() {
        let tracker = PageReadinessNetworkTracker(classifier: PageReadinessClassifier())
        let t0 = Date()
        // Below threshold from the start: idle clock runs.
        #expect(tracker.networkIdleForMs(threshold: 2, now: t0) == 0)
        let later = t0.addingTimeInterval(0.5)
        #expect(tracker.networkIdleForMs(threshold: 2, now: later) >= 400)
    }

    @Test func networkIdleResetsWhenAboveThreshold() {
        let tracker = PageReadinessNetworkTracker(classifier: PageReadinessClassifier())
        let t0 = Date()
        _ = tracker.networkIdleForMs(threshold: 1, now: t0)
        // Three in-flight requests push above the threshold.
        tracker.handle(requestEvent("r1", url: "https://x.test/1"))
        tracker.handle(requestEvent("r2", url: "https://x.test/2"))
        tracker.handle(requestEvent("r3", url: "https://x.test/3"))
        let later = t0.addingTimeInterval(1.0)
        #expect(tracker.networkIdleForMs(threshold: 1, now: later) == 0)
    }
}

@Suite("DomStableTimestamp")
struct DomStableTimestampTests {
    @Test func reportsZeroUntilMarked() {
        let stamp = DomStableTimestamp()
        #expect(stamp.stableForMs(now: Date()) == 0)
    }

    @Test func reportsElapsedSinceMark() {
        let stamp = DomStableTimestamp()
        stamp.markStable()
        let later = Date().addingTimeInterval(0.3)
        #expect(stamp.stableForMs(now: later) >= 250)
    }

    @Test func firstMarkWins() {
        let stamp = DomStableTimestamp()
        stamp.markStable()
        let firstReading = stamp.stableForMs(now: Date().addingTimeInterval(0.2))
        stamp.markStable()
        let secondReading = stamp.stableForMs(now: Date().addingTimeInterval(0.2))
        #expect(secondReading >= firstReading - 50)
    }
}
