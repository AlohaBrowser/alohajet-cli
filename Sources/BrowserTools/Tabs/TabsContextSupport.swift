import Foundation

// MARK: - Page readiness classification

/// Options governing how ``PageReadinessClassifier`` decides a page is ready.
public nonisolated struct PageReadinessOptions: Sendable, Equatable {
    public var networkIdleThreshold: Int
    public var networkIdleTimeMs: Int
    public var domStableTimeMs: Int
    public var minWaitTimeMs: Int
    public var timeoutMs: Int

    public init(
        networkIdleThreshold: Int = 2,
        networkIdleTimeMs: Int = 500,
        domStableTimeMs: Int = 400,
        minWaitTimeMs: Int = 300,
        timeoutMs: Int = 15_000
    ) {
        self.networkIdleThreshold = networkIdleThreshold
        self.networkIdleTimeMs = networkIdleTimeMs
        self.domStableTimeMs = domStableTimeMs
        self.minWaitTimeMs = minWaitTimeMs
        self.timeoutMs = timeoutMs
    }
}

/// Why a page-readiness wait completed.
public nonisolated enum PageReadinessReason: String, Sendable, Equatable {
    case ready
    case timeout
    case aborted
    case error
}

/// The result of a page-readiness wait.
public nonisolated struct PageReadinessResult: Sendable, Equatable {
    public var success: Bool
    public var waitedMs: Int
    public var reason: PageReadinessReason

    public init(success: Bool, waitedMs: Int, reason: PageReadinessReason) {
        self.success = success
        self.waitedMs = waitedMs
        self.reason = reason
    }
}

/// A network request observed while waiting for a page to settle, used to decide
/// whether it should be ignored as a persistent / streaming connection.
public nonisolated struct PageReadinessRequest: Sendable, Equatable {
    public var url: String
    public var type: String
    public var acceptHeader: String?

    public init(url: String, type: String, acceptHeader: String? = nil) {
        self.url = url
        self.type = type
        self.acceptHeader = acceptHeader
    }
}

/// The portable classification logic underpinning the page-readiness waiter:
/// decides which in-flight network requests are long-lived / streaming and thus
/// should not block readiness, and computes whether the page is ready given the
/// current timing state. The transport-bound observation loop (CDP network
/// events and DOM-stability observation) is supplied by the native shell.
public nonisolated struct PageReadinessClassifier: Sendable {
    public init() {}

    /// Persistent / streaming / telemetry connection patterns that never count
    /// towards the in-flight request total.
    public static let persistentUrlPatterns: [String] = [
        "/analytics",
        "/beacon",
        "/heartbeat",
        "/ping",
        "google-analytics.com",
        "googletagmanager.com",
        "facebook.com/tr",
        "segment.io",
        "mixpanel.com"
    ]

    /// Returns true when a request represents a persistent/streaming/telemetry
    /// connection that should be excluded from the in-flight network count.
    public func isPersistentConnection(_ request: PageReadinessRequest) -> Bool {
        let url = request.url
        let type = request.type
        if type == "WebSocket" || type == "EventSource" {
            return true
        }
        let accept = request.acceptHeader
        if url.contains("/events"), let accept, accept.contains("text/event-stream") {
            return true
        }
        if accept == "text/event-stream" {
            return true
        }
        if url.contains("/poll") || url.contains("/long-poll") || url.contains("/comet") {
            return true
        }
        return Self.persistentUrlPatterns.contains { url.contains($0) }
    }

    /// Given the elapsed time, time since the network first went idle, time since
    /// the DOM became stable, and the current in-flight request count, decides
    /// whether the page is ready under the supplied options.
    public func isReady(
        elapsedMs: Int,
        networkIdleForMs: Int,
        domStableForMs: Int,
        inFlightCount: Int,
        options: PageReadinessOptions
    ) -> Bool {
        let minElapsed = elapsedMs >= options.minWaitTimeMs
        let networkIdle = inFlightCount <= options.networkIdleThreshold && networkIdleForMs >= options.networkIdleTimeMs
        let domStable = domStableForMs >= options.domStableTimeMs || elapsedMs >= options.timeoutMs / 2
        return minElapsed && networkIdle && domStable
    }
}
