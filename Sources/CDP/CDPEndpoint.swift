import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Describes how to obtain a CDP (Chrome DevTools Protocol) WebSocket endpoint:
/// the seam through which any CDP-speaking application, not only a Chrome this
/// process launched, can be driven.
public enum CDPEndpoint: Sendable, CustomStringConvertible {
    /// Launch a fresh local Google Chrome (via `ChromeLauncher`) with the
    /// remote-debugging port enabled, then attach to it.
    case launchChrome(headless: Bool)

    /// Attach to an already-running CDP endpoint reachable at
    /// `http://host:port/json/version` (the browser-level WebSocket is
    /// discovered from there).
    case attach(host: String, port: Int)

    /// Attach to an explicit `webSocketDebuggerUrl` string.
    case attachWebSocket(String)

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

public struct BrowserDemo: Sendable {

    /// Open a tab per URL, returning the opened `targetId`s in the order of `urls`.
    ///
    /// For `.launchChrome`, a Chrome instance is launched and kept alive for
    /// the duration of the call, then verified and terminated before returning.
    /// For `.attach`/`.attachWebSocket`, an existing endpoint is used and left
    /// running (only the client connection is closed).
    public static func openTabs(
        cdpEndpoint: CDPEndpoint,
        urls: [String]
    ) async throws -> [String] {
        switch cdpEndpoint {
        case .launchChrome(let headless):
            return try await openTabsLaunchingChrome(headless: headless, urls: urls)
        case .attach(let host, let port):
            let client = try await CDPClient.connecting(host: host, port: port)
            return try await openTabs(using: client, urls: urls)
        case .attachWebSocket(let wsURLString):
            let client = try CDPClient(webSocketURLString: wsURLString)
            try await client.connect()
            return try await openTabs(using: client, urls: urls)
        }
    }

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

        let wsURL = try await launcher.discoverWebSocketURL(port: port, handle: handle)
        let client = CDPClient(webSocketURL: wsURL)
        try await client.connect()

        let targetIds = try await openTabs(using: client, urls: urls)
        try await verifyTargets(host: "127.0.0.1", port: port, targetIds: targetIds)
        return targetIds
    }

    private static func openTabs(
        using client: CDPClient,
        urls: [String]
    ) async throws -> [String] {
        var targetIds: [String] = []
        do {
            for url in urls {
                let targetId = try await client.openTab(url: url)
                targetIds.append(targetId)
            }
        } catch {
            await client.close()
            throw error
        }
        await client.close()
        return targetIds
    }

    /// Confirm, via `GET http://host:port/json`, that every `targetId` exists in
    /// the browser's live target list. Polls to tolerate the async gap between
    /// `Target.createTarget` returning and the target appearing in the listing.
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
            if let targets = try? await CDPClient.listTargets(host: host, port: port) {
                present.formUnion(targets.map(\.id))
                if present.isSuperset(of: targetIds) { return }
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        let missing = targetIds.filter { !present.contains($0) }
        throw CDPError.discoveryFailed(
            "Opened target(s) \(missing) did not appear in /json target list on \(host):\(port)"
        )
    }
}
