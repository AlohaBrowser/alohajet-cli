import Testing
@testable import BrowserTools

@Suite struct PageReadinessClassifierPersistenceTests {
    private let classifier = PageReadinessClassifier()

    @Test func webSocketAndEventSourceTypesArePersistent() {
        #expect(classifier.isPersistentConnection(PageReadinessRequest(url: "https://x.com/ws", type: "WebSocket")))
        #expect(classifier.isPersistentConnection(PageReadinessRequest(url: "https://x.com/sse", type: "EventSource")))
    }

    @Test func eventsPathWithEventStreamAcceptIsPersistent() {
        // Requires BOTH the /events path AND the event-stream accept header.
        #expect(classifier.isPersistentConnection(
            PageReadinessRequest(url: "https://x.com/events", type: "Fetch", acceptHeader: "text/event-stream")))
        // /events without the event-stream accept does not match this branch...
        #expect(!classifier.isPersistentConnection(
            PageReadinessRequest(url: "https://x.com/events", type: "Fetch", acceptHeader: "application/json")))
    }

    @Test func bareEventStreamAcceptHeaderIsPersistent() {
        // An exact text/event-stream accept on any URL is persistent.
        #expect(classifier.isPersistentConnection(
            PageReadinessRequest(url: "https://x.com/stream", type: "Fetch", acceptHeader: "text/event-stream")))
    }

    @Test func pollingAndCometPathsArePersistent() {
        #expect(classifier.isPersistentConnection(PageReadinessRequest(url: "https://x.com/poll", type: "Fetch")))
        #expect(classifier.isPersistentConnection(PageReadinessRequest(url: "https://x.com/long-poll", type: "Fetch")))
        #expect(classifier.isPersistentConnection(PageReadinessRequest(url: "https://x.com/comet", type: "Fetch")))
    }

    @Test func telemetryHostsAndPathsArePersistent() {
        for pattern in PageReadinessClassifier.persistentUrlPatterns {
            #expect(classifier.isPersistentConnection(
                PageReadinessRequest(url: "https://host\(pattern)/x", type: "Fetch")),
                "expected \(pattern) to be persistent")
        }
    }

    @Test func ordinaryRequestIsNotPersistent() {
        #expect(!classifier.isPersistentConnection(
            PageReadinessRequest(url: "https://x.com/api/data", type: "Fetch", acceptHeader: "application/json")))
        #expect(!classifier.isPersistentConnection(PageReadinessRequest(url: "https://x.com/index.html", type: "Document")))
    }
}

@Suite struct PageReadinessClassifierReadyTests {
    private let classifier = PageReadinessClassifier()
    private let options = PageReadinessOptions()

    @Test func defaultOptionValues() {
        #expect(options.networkIdleThreshold == 2)
        #expect(options.networkIdleTimeMs == 500)
        #expect(options.domStableTimeMs == 400)
        #expect(options.minWaitTimeMs == 300)
        #expect(options.timeoutMs == 15_000)
    }

    @Test func readyWhenAllConditionsMet() {
        #expect(classifier.isReady(
            elapsedMs: 1_000, networkIdleForMs: 600, domStableForMs: 500,
            inFlightCount: 0, options: options))
    }

    @Test func notReadyBeforeMinWaitTime() {
        // elapsed (200) < minWaitTimeMs (300) blocks readiness even when otherwise settled.
        #expect(!classifier.isReady(
            elapsedMs: 200, networkIdleForMs: 600, domStableForMs: 500,
            inFlightCount: 0, options: options))
    }

    @Test func notReadyWhenTooManyRequestsInFlight() {
        // inFlightCount (3) > threshold (2).
        #expect(!classifier.isReady(
            elapsedMs: 1_000, networkIdleForMs: 600, domStableForMs: 500,
            inFlightCount: 3, options: options))
        // At exactly the threshold the network counts as idle.
        #expect(classifier.isReady(
            elapsedMs: 1_000, networkIdleForMs: 600, domStableForMs: 500,
            inFlightCount: 2, options: options))
    }

    @Test func notReadyWhenNetworkNotIdleLongEnough() {
        #expect(!classifier.isReady(
            elapsedMs: 1_000, networkIdleForMs: 400, domStableForMs: 500,
            inFlightCount: 0, options: options))
    }

    @Test func domStabilityShortCircuitedByHalfTimeout() {
        // domStableForMs (100) < domStableTimeMs (400) would normally block, but
        // elapsedMs (8000) >= timeoutMs/2 (7500) satisfies the DOM-stable branch.
        #expect(classifier.isReady(
            elapsedMs: 8_000, networkIdleForMs: 600, domStableForMs: 100,
            inFlightCount: 0, options: options))
        #expect(!classifier.isReady(
            elapsedMs: 7_000, networkIdleForMs: 600, domStableForMs: 100,
            inFlightCount: 0, options: options))
    }
}

@Suite struct PageReadinessResultTests {
    @Test func reasonRawValues() {
        #expect(PageReadinessReason.ready.rawValue == "ready")
        #expect(PageReadinessReason.timeout.rawValue == "timeout")
        #expect(PageReadinessReason.aborted.rawValue == "aborted")
        #expect(PageReadinessReason.error.rawValue == "error")
    }

    @Test func resultEquatability() {
        let a = PageReadinessResult(success: true, waitedMs: 120, reason: .ready)
        let b = PageReadinessResult(success: true, waitedMs: 120, reason: .ready)
        let c = PageReadinessResult(success: false, waitedMs: 120, reason: .timeout)
        #expect(a == b)
        #expect(a != c)
    }
}
