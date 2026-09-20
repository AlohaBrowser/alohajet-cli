import Foundation
import CDP

// MARK: - The `--browser aloha` lane
//
// The Aloha browser runs its OWN CDP server over its webviews and publishes
// `/json/version` on port 9222 (`ALOHA_CDP_PORT` overrides it), so this lane is not a
// second backend: it is a different CDP endpoint reached by the same `CDPClient`. All
// this type does is decide WHICH endpoint, bring the app up when it is not running, and
// wait until the listener actually answers.
//
// Shaped like the app's own launcher — the injected
// probe/opener seams, the "wait on the real condition, never a fixed sleep" loop, and the
// loud failure that names the endpoint and the setting to turn on. What is NOT here is
// everything that speaks to the app's loopback `AutomationServer`: the `GET /state`
// readiness probe and its headless/visibleWindow booleans, the `alohajet://attach` deep
// link, the one-shot headless launch token, the bearer credential. None of that exists on
// the CDP wire this lane rides, and none of it is reachable from here: it lives in
// `AgentDriver.AlohaAppLauncher`, beside the HTTP client and the token reader it is built
// on, and `BrowserTools` does not link `AgentDriver`. `alohajet -p` goes through that one;
// the tool commands come through this one, which needs to know only that a CDP listener
// answers.
//
// The poll loop itself is NOT re-implemented here: `ChromeLauncher.discoverWebSocketURL`
// already is one, tested, and is what the chromium lane uses.

/// Why `--browser aloha` could not reach a browser.
public enum AlohaBrowserError: Error, Equatable, CustomStringConvertible {
    /// LaunchServices refused to launch or activate the app.
    case launchFailed(String)
    /// Nothing answered `/json/version` at the port, launch or no launch.
    case notReachable(port: Int, seconds: Int)

    public var description: String {
        switch self {
        case let .launchFailed(detail):
            return "could not launch the Aloha browser: \(detail)"
        case let .notReachable(port, seconds):
            return """
                no CDP endpoint answered on 127.0.0.1:\(port) after \(seconds)s — if the \
                browser is running, its CDP listener is off: it is disabled by \
                ALOHA_CDP_DISABLED=1, or it relocated off a taken \(port) \
                (pass --cdp <port> to name the port yourself)
                """
        }
    }
}

/// Finds — and, when it is not running, starts — the Aloha browser, and resolves the CDP
/// endpoint to attach to.
public struct AlohaBrowser: Sendable {
    /// Does a CDP listener answer on this port? `nil` is "not reachable". Injected so the
    /// tests are hermetic; production is ``liveProbe``.
    public typealias Probe = @Sendable (Int) async -> URL?
    /// Hands the app to LaunchServices. Injected for the same reason; production is
    /// ``liveOpen``.
    public typealias Opener = @Sendable () throws -> Void

    /// The port the browser prefers. A relocated listener (9222 already taken) advertises
    /// its number only on itself, so it cannot be discovered from outside — `--cdp <port>`
    /// is the way in when that happens.
    public nonisolated static let defaultPort = 9222
    /// The browser's own override, read here under the SAME name so one export points
    /// both ends at the same port.
    public nonisolated static let portEnvKey = "ALOHA_CDP_PORT"
    /// Points the launcher at a specific `.app` — a dev build, or a copy outside
    /// /Applications. Without it LaunchServices picks by bundle identifier.
    public nonisolated static let appPathEnvKey = "ALOHA_BROWSER_APP"

    private let probe: Probe
    private let open: Opener
    private let pollInterval: Duration
    private let attempts: Int

    public init(
        probe: @escaping Probe = AlohaBrowser.liveProbe,
        open: @escaping Opener = AlohaBrowser.liveOpen,
        pollInterval: Duration = .milliseconds(250),
        attempts: Int = 80
    ) {
        self.probe = probe
        self.open = open
        self.pollInterval = pollInterval
        self.attempts = attempts
    }

    /// The port to look on: `ALOHA_CDP_PORT` when it names a real one, else 9222.
    /// Anything missing, non-numeric or out of range falls back rather than failing —
    /// the same rule the browser applies to the same variable, so the two agree.
    public nonisolated static func port(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int {
        guard let raw = environment[portEnvKey], let value = Int(raw),
              (1...65535).contains(value)
        else { return defaultPort }
        return value
    }

    /// The CDP WebSocket URL of the running Aloha browser, launching it first when
    /// nothing answers yet.
    ///
    /// The wait is on the REAL condition — `/json/version` answering — not a fixed sleep:
    /// a cold start has to finish launching, mount its chrome and bind the listener, and
    /// the only honest signal that it did is the listener answering.
    public func endpoint(port: Int = AlohaBrowser.port()) async throws -> URL {
        if let url = await probe(port) { return Self.keepingTabs(url) }
        do {
            try open()
        } catch let error as AlohaBrowserError {
            throw error
        } catch {
            throw AlohaBrowserError.launchFailed("\(error)")
        }
        for _ in 0..<attempts {
            try await Task.sleep(for: pollInterval)
            if let url = await probe(port) { return Self.keepingTabs(url) }
        }
        let seconds = Int((pollInterval * attempts).components.seconds)
        throw AlohaBrowserError.notReachable(port: port, seconds: seconds)
    }

    /// Declares this client a keep-tabs client to the Aloha browser: `?alohaKeepTabs=1`
    /// on the websocket URL. One `alohajet` verb is one process is one connection, and
    /// the browser reaps every target a dropping connection created — so without this the
    /// tab `open` printed is gone before `read` can address it. Carried on the URL, not
    /// on the CDP wire, so the protocol stays Chromium-shaped; the chromium lane never
    /// goes through here (browser side: `CDPWebSocketServer.keepsTabs(fromPath:)`).
    nonisolated static func keepingTabs(_ url: URL) -> URL {
        let separator = (url.query?.isEmpty == false) ? "&" : "?"
        return URL(string: url.absoluteString + separator + "alohaKeepTabs=1") ?? url
    }

    // MARK: - The production seams

    /// One real `/json/version` read, through the same discovery this package's chromium
    /// lane uses. Anything but a well-formed answer is "not reachable".
    public static let liveProbe: Probe = { port in
        try? await CDPClient.discoverWebSocketURL(host: "127.0.0.1", port: port)
    }

    /// `open(1)` — not NSWorkspace — so this stays a plain Foundation CLI with no AppKit
    /// link. `-g` keeps the launch out of the foreground.
    ///
    /// WHICH copy is `appPath`'s decision, and getting it wrong starts a SECOND instance:
    /// LaunchServices hands the app to the existing instance only when the bundle it
    /// resolves IS the running one, and a bundle IDENTIFIER resolves to whichever
    /// registered copy the machine prefers. The bundle identifiers are the last resort,
    /// for a helper that ships inside no app at all.
    public static let liveOpen: Opener = {
        let path = appPath()
        var failures: [String] = []
        for arguments in openArguments(appPath: path) {
            do {
                try run("/usr/bin/open", arguments)
                return
            } catch let error as AlohaBrowserError {
                failures.append(error.description)
            }
        }
        throw AlohaBrowserError.launchFailed(failures.joined(separator: "; "))
    }

    /// The `.app` this run drives: `ALOHA_BROWSER_APP` when it names one, else the
    /// bundle this executable ships inside (`<X>.app/Contents/{Helpers,MacOS}/alohajet`),
    /// else `nil` — the signal to let LaunchServices pick by bundle identifier.
    ///
    /// The same rule as the agent lane's `AlohaAppLauncher.appBundlePath`, written out a
    /// second time because `BrowserTools` does not link `AgentDriver`. `MacOS` is
    /// accepted beside `Helpers` for builds made before the helper moved.
    nonisolated static func appPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        executable: String? = Bundle.main.executableURL?.resolvingSymlinksInPath().path
    ) -> String? {
        if let path = environment[appPathEnvKey], !path.isEmpty { return path }
        guard let executable else { return nil }
        let directory = (executable as NSString).deletingLastPathComponent
        let name = (directory as NSString).lastPathComponent
        guard name == "Helpers" || name == "MacOS" else { return nil }
        let contents = (directory as NSString).deletingLastPathComponent
        guard (contents as NSString).lastPathComponent == "Contents" else { return nil }
        let bundle = (contents as NSString).deletingLastPathComponent
        guard (bundle as NSString).pathExtension == "app" else { return nil }
        return bundle
    }

    /// The `open(1)` argument lists to try, in order. With an explicit path there is
    /// exactly one and a failure is final; without one, each registered bundle identifier
    /// is tried, because a machine has either product installed, not both.
    nonisolated static func openArguments(appPath: String?) -> [[String]] {
        if let appPath { return [["-g", "-a", appPath]] }
        return ["com.alohabrowser.alohabrowser", "com.alohabrowser.alohajet"]
            .map { ["-g", "-b", $0] }
    }

    /// Run a child process to completion; a non-zero exit is a `launchFailed` carrying its
    /// stderr.
    nonisolated static func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let errorPipe = Pipe()
        process.standardError = errorPipe
        do {
            try process.run()
        } catch {
            throw AlohaBrowserError.launchFailed("\(executable): \(error)")
        }
        let stderr = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: stderr, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw AlohaBrowserError.launchFailed(
                "\(executable) exited \(process.terminationStatus): \(detail)")
        }
    }
}
