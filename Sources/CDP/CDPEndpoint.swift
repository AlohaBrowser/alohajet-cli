import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - CDPEndpoint
//
// The "attach ANY CDP app" seam. A `CDPEndpoint` describes *where* to get a CDP
// WebSocket from. `launchChrome` boots a local Chrome via `ChromeLauncher`; the
// `attach`/`attachWebSocket` cases connect a `CDPClient` to an already-running
// CDP-speaking application (Chrome, Edge, any browser exposing the protocol).

/// Describes how to obtain a CDP (Chrome DevTools Protocol) WebSocket endpoint.
public enum CDPEndpoint: Sendable {
    /// Launch a fresh local Google Chrome (via `ChromeLauncher`) with the
    /// remote-debugging port enabled, then attach to it.
    case launchChrome(headless: Bool)

    /// Attach to an already-running CDP endpoint reachable at
    /// `http://host:port/json/version` (the browser-level WebSocket is
    /// discovered from there).
    case attach(host: String, port: Int)

    /// Attach to an explicit `webSocketDebuggerUrl` string.
    case attachWebSocket(String)

    /// A short human-readable description of the resolved endpoint, useful for
    /// printing alongside results.
    public var description: String {
        switch self {
        case .launchChrome(let headless):
            return "launchChrome(headless: \(headless))"
        case .attach(let host, let port):
            return "attach(\(host):\(port))"
        case .attachWebSocket(let url):
            return "attachWebSocket(\(url))"
        }
    }
}

// MARK: - BrowserDemo

/// A small, reusable, testable driver that opens one or more tabs in a
/// CDP-speaking browser and returns the opened `targetId`s.
///
/// The same code path drives a freshly-launched headless Chrome and an
/// already-running CDP application — the only difference is the `CDPEndpoint`.
public struct BrowserDemo: Sendable {

    /// Open a tab per URL in the browser described by `cdpEndpoint`, returning
    /// the opened `targetId`s in the same order as `urls`.
    ///
    /// For `.launchChrome`, a Chrome instance is launched and kept alive for
    /// the duration of the call, then verified and terminated before returning.
    /// For `.attach`/`.attachWebSocket`, an existing endpoint is used and left
    /// running (only the client connection is closed).
    ///
    /// - Parameters:
    ///   - cdpEndpoint: Where to obtain the CDP WebSocket from.
    ///   - urls: The URLs to open, one tab each.
    /// - Returns: The opened `targetId`s, in input order.
    public static func openTabs(
        cdpEndpoint: CDPEndpoint,
        urls: [String]
    ) async throws -> [String] {
        switch cdpEndpoint {
        case .launchChrome(let headless):
            return try await openTabsLaunchingChrome(headless: headless, urls: urls)
        case .attach(let host, let port):
            let client = try await CDPClient.connecting(host: host, port: port)
            return try await openTabs(using: client, urls: urls, closeClient: true)
        case .attachWebSocket(let wsURLString):
            let client = try CDPClient(webSocketURLString: wsURLString)
            try await client.connect()
            return try await openTabs(using: client, urls: urls, closeClient: true)
        }
    }

    // MARK: - launchChrome path

    private static func openTabsLaunchingChrome(
        headless: Bool,
        urls: [String]
    ) async throws -> [String] {
        let launcher = ChromeLauncher()
        guard launcher.isAvailable else {
            throw CDPError.discoveryFailed(
                "Google Chrome is not installed at \(ChromeLauncher.defaultExecutablePath)"
            )
        }

        let port = Int.random(in: 9300...9899)
        let handle = try launcher.launch(port: port, headless: headless)
        defer { handle.terminate() }

        // Poll until the CDP endpoint is up, then connect a client to it.
        let wsURL = try await launcher.discoverWebSocketURL(port: port, handle: handle)
        let client = CDPClient(webSocketURL: wsURL)
        try await client.connect()

        // Open the tabs, then verify each opened target is really present in the
        // browser's live target list before we tear Chrome down.
        let targetIds = try await openTabs(using: client, urls: urls, closeClient: true)
        try await verifyTargets(host: "127.0.0.1", port: port, targetIds: targetIds)
        return targetIds
    }

    // MARK: - Shared open path

    /// Open one tab per URL through an already-connected client.
    private static func openTabs(
        using client: CDPClient,
        urls: [String],
        closeClient: Bool
    ) async throws -> [String] {
        var targetIds: [String] = []
        do {
            for url in urls {
                let targetId = try await client.openTab(url: url)
                targetIds.append(targetId)
            }
        } catch {
            if closeClient { await client.close() }
            throw error
        }
        if closeClient { await client.close() }
        return targetIds
    }

    // MARK: - Verification

    /// Confirm, via `GET http://host:port/json`, that every `targetId` exists in
    /// the browser's live target list. Polls briefly to tolerate the async gap
    /// between `Target.createTarget` returning and the target appearing in the
    /// HTTP listing.
    private static func verifyTargets(
        host: String,
        port: Int,
        targetIds: [String],
        timeout: TimeInterval = 10
    ) async throws {
        guard !targetIds.isEmpty else { return }
        let deadline = Date().addingTimeInterval(timeout)
        var present: Set<String> = []
        while Date() < deadline {
            // Read the live target list through the public `listTargets()` seam;
            // the `try?` keeps a transiently-unreadable `/json` a no-op poll,
            // identical to the previous inline `try?`-guarded read.
            if let targets = try? await CDPClient.listTargets(host: host, port: port) {
                for target in targets {
                    present.insert(target.id)
                }
                if targetIds.allSatisfy({ present.contains($0) }) {
                    return
                }
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        let missing = targetIds.filter { !present.contains($0) }
        throw CDPError.discoveryFailed(
            "Opened target(s) \(missing) did not appear in /json target list on \(host):\(port)"
        )
    }
}
