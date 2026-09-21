import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

// MARK: - Bringing the app up for `alohajet -p`
//
// `-p` hands the prompt to an agent loop that runs INSIDE the Aloha browser. When the
// binary ships as `<App>.app/Contents/Helpers/alohajet` the app it must talk to is the
// one it sits inside, so "the endpoint is not answering" almost always means "the app
// is not running yet" — and launching it is the whole of the fix.
//
// The launcher lives HERE, next to `RemoteAutomationDriver` and `AutomationToken`,
// because every part of it that is not `open(1)` speaks to the app's loopback
// `AutomationServer`: the readiness probe is one `GET /state` over the driver's own
// transport, which is what presents the bearer credential and picks up a rotation.
// `BrowserTools.AlohaBrowser` — the CDP lane's launcher — cannot host it: that target
// does not link this one, and its wire is Chromium's `/json/version`, which knows
// nothing about windows or headlessness.
//
// The two things a fixed sleep cannot do, and this does:
//
//   * WAIT ON THE REAL CONDITION. A cold start has to finish launching, mount its
//     chrome and bind the listener; the only honest signal that it did is `/state`
//     answering 200.
//   * REFUSE THE FOUR SHAPES THAT CANNOT WORK, by name. Each of them otherwise costs
//     the user the full 30s budget and then reports a timeout that names no cause.

/// Why `alohajet -p` could not get to a running browser.
public enum AlohaAppLaunchError: Error, Equatable, CustomStringConvertible {
    /// LaunchServices refused to launch or activate the app.
    case launchFailed(String)
    /// The app is (or should be) up, but its automation listener never answered.
    case notReachable(endpoint: String, seconds: Int)
    /// `--headless` found an app running in windowed mode.
    case alreadyRunningVisible
    /// `--headless` reached a `/state` that does not say whether it is headless — a
    /// browser predating the two booleans. Absence is never read as "windowed".
    case headlessStateUnknown
    /// A run that did NOT ask for `--headless` found a headless instance.
    case alreadyRunningHeadless
    /// The app is up but its automation server is not answering, and no launch can
    /// change that.
    case automationOff

    public var description: String {
        switch self {
        case let .launchFailed(detail):
            return "could not launch the Aloha browser: \(detail)"
        case let .notReachable(endpoint, seconds):
            return """
                no automation server answered at \(endpoint) after \(seconds)s — if the \
                browser is running, its automation server is off: turn it on in \
                Settings → AlohaJet ("Allow CLI and MCP clients").
                """
        case .alreadyRunningVisible:
            return "app already running with a visible window — quit it, or drop --headless"
        case .headlessStateUnknown:
            return "the automation server did not report its headless state; update the browser or drop --headless"
        case .alreadyRunningHeadless:
            // Deliberately does not name `alohajet quit`: that closes the shared Chromium
            // of the tool lane, so naming it would send the user at the wrong browser.
            return """
                app already running headless — it has no window on screen, so add \
                --headless to drive it, or quit that instance first.
                """
        case .automationOff:
            return """
                the browser is running but its automation server is off: turn it on in \
                Settings → AlohaJet ("Allow CLI and MCP clients").
                """
        }
    }
}

/// What `GET /state` says about the app's window situation: the launch-mode fact
/// and the live one. Either being `nil` means the browser never answered.
public nonisolated struct AlohaAppState: Sendable, Equatable {
    public let headless: Bool?
    public let visibleWindow: Bool?

    public init(headless: Bool?, visibleWindow: Bool?) {
        self.headless = headless
        self.visibleWindow = visibleWindow
    }

    /// The only shape a `--headless` run may drive.
    public var isHeadless: Bool { headless == true && visibleWindow == false }
}

/// Launches — or reuses — the Aloha browser behind a `-p` turn, and waits until its
/// loopback automation server actually answers.
///
/// The launch itself is one `open(1)` of `alohajet://attach`: LaunchServices starts the
/// app when it is not running and hands the URL to the EXISTING instance when it is —
/// one app, never a second copy. Claiming that URL is what marks the app as CLI-driven,
/// which is what puts the prompt, the tool trace and the answer in its own AI pane.
public struct AlohaAppLauncher: Sendable {
    /// Is the automation server at this endpoint answering, and in what window mode?
    /// Injected so the tests are hermetic; production is ``liveProbe``.
    public typealias Probe = @Sendable (URL) async -> AlohaAppState?
    /// Hands a URL to LaunchServices. Injected for the same reason; production is
    /// ``liveOpen``.
    public typealias Opener = @Sendable (_ url: String, _ headless: Bool) throws -> Void
    /// The pids of the host app running right now, empty when this CLI cannot tell.
    /// Production is ``liveInstances``.
    public typealias Instances = @Sendable () -> Set<Int32>
    /// Production is ``liveTerminate``.
    public typealias Terminator = @Sendable (Set<Int32>) -> Void

    /// The URL the app recognizes.
    public nonisolated static let attachURL = "alohajet://attach"

    /// The one fixed port the app's `AutomationServer` binds; it is not configurable on
    /// either side, so a different port is a different server.
    public nonisolated static let defaultPort = 8765
    /// What `-p --endpoint` defaults to. The binary ships inside the app it drives, so
    /// the loopback server beside it is the common case and the flag is the exception.
    public nonisolated static let defaultEndpoint = "http://127.0.0.1:\(defaultPort)"

    /// Points the launcher at a specific `.app` — a dev build, or a copy outside
    /// /Applications. The same variable the CDP lane reads
    /// (`BrowserTools.AlohaBrowser.appPathEnvKey`), so one export moves both lanes.
    public nonisolated static let appPathEnvKey = "ALOHA_BROWSER_APP"

    /// Tried in order when this executable does not ship inside an `.app`: a machine has
    /// either product installed, not both. Same list, same order as the CDP lane's.
    nonisolated static let bundleIdentifiers = [
        "com.alohabrowser.alohabrowser", "com.alohabrowser.alohajet",
    ]

    private let probe: Probe
    private let open: Opener
    private let instances: Instances
    private let terminate: Terminator
    private let pollInterval: Duration
    private let attempts: Int
    private let launchTokenPath: String

    public init(
        probe: @escaping Probe = AlohaAppLauncher.liveProbe,
        open: @escaping Opener = AlohaAppLauncher.liveOpen,
        instances: @escaping Instances = AlohaAppLauncher.liveInstances,
        terminate: @escaping Terminator = AlohaAppLauncher.liveTerminate,
        pollInterval: Duration = .milliseconds(200),
        attempts: Int = 150,
        launchTokenPath: String = AlohaAppLauncher.headlessLaunchTokenPath
    ) {
        self.probe = probe
        self.open = open
        self.instances = instances
        self.terminate = terminate
        self.pollInterval = pollInterval
        self.attempts = attempts
        self.launchTokenPath = launchTokenPath
    }

    /// Launch-or-activate the app, then block until its automation server answers.
    /// Throws rather than letting the turn fail later with a bare "connection refused"
    /// from the first `/agent/lane` call.
    ///
    /// With `headless`, EVERY reachable `/state` must be `isHeadless` or the run dies
    /// loud, and an instance that is RUNNING but unreachable fails before the launch:
    /// `--args` cannot reach it, so waiting would only add an invisible process.
    public func ensureRunning(
        endpoint: URL, headless: Bool = false, log: (String) -> Void
    ) async throws {
        // Nothing here can start — or stop — a server that is not this machine's app,
        // and the wait is only ever a wait for a launch. An endpoint somewhere else is
        // left to the driver, which fails in one round trip instead of 30 seconds.
        // Silent, except for the one case where silence would mislead: `--headless`
        // asked for a launch mode that only a launch can set.
        guard Self.servesLocalApp(endpoint) else {
            if headless {
                log("--headless configures the app on this machine at launch;"
                    + " \(endpoint.absoluteString) is not it, so nothing was launched")
            }
            return
        }

        var launchedHeadless = false
        var launched: Set<Int32> = []
        var reachable = false
        // The cleanup below exists for an INVISIBLE process the user can neither see
        // nor close. A launch that ended up windowed is neither, and the usual way it
        // happens is a person clicking it — so it is left running.
        var endedUpWindowed = false
        defer {
            if launchedHeadless {
                clearLaunchToken()
                if !reachable, !endedUpWindowed, !launched.isEmpty {
                    terminate(launched)
                    log("stopped the headless instance this run launched")
                }
            }
        }

        if headless {
            if let state = await probe(endpoint) {
                try Self.requireWindowMode(state, headless: true)
            } else {
                guard instances().isEmpty else { throw AlohaAppLaunchError.automationOff }
                writeLaunchToken()
                launchedHeadless = true
            }
        }

        do {
            try open(Self.attachURL, headless)
            log("launched or activated \(Self.hostName)")
        } catch let error as AlohaAppLaunchError {
            throw error
        } catch {
            throw AlohaAppLaunchError.launchFailed("\(error)")
        }
        if launchedHeadless { launched = instances() }

        for attempt in 0..<attempts {
            if let state = await probe(endpoint) {
                do {
                    try Self.requireWindowMode(state, headless: headless)
                } catch {
                    if launchedHeadless, state.visibleWindow == true { endedUpWindowed = true }
                    throw error
                }
                reachable = true
                // Only when the wait was real. An app that answered the FIRST probe was
                // already up, and a line saying so on every single turn is noise on the
                // stderr the answer's chat id has to be findable in.
                if attempt > 0 { log("automation server reachable at \(endpoint.absoluteString)") }
                return
            }
            // The pre-flight proved nothing was running, so the first pids to appear
            // are this launch's — latched once, so an instance the user starts during
            // the wait is never mistaken for ours and killed.
            if launchedHeadless, launched.isEmpty { launched = instances() }
            try await Task.sleep(for: pollInterval)
        }
        let seconds = Int((pollInterval * attempts).components.seconds)
        throw AlohaAppLaunchError.notReachable(endpoint: endpoint.absoluteString, seconds: seconds)
    }

    /// Is this endpoint the automation server of the app on THIS machine — the only one
    /// `open(1)` can start? Loopback is not enough: the app binds one fixed port, so a
    /// different loopback port is somebody else's server and launching the app would
    /// bring up something that never answers there.
    public nonisolated static func servesLocalApp(_ endpoint: URL) -> Bool {
        AutomationToken.isLoopback(endpoint) && endpoint.port == defaultPort
    }

    /// Both directions, because `open --args` only reaches a COLD launch: a windowed
    /// instance silently swallows `--headless`, and a headless one silently swallows
    /// its absence. A browser too old to answer either boolean is unknown, never
    /// assumed — which only fails a run that asked for `--headless`.
    private static func requireWindowMode(_ state: AlohaAppState, headless: Bool) throws {
        guard state.headless != nil, state.visibleWindow != nil else {
            guard headless else { return }
            throw AlohaAppLaunchError.headlessStateUnknown
        }
        guard state.isHeadless == headless else {
            throw headless
                ? AlohaAppLaunchError.alreadyRunningVisible
                : AlohaAppLaunchError.alreadyRunningHeadless
        }
    }

    // MARK: - The one-shot launch token

    /// The file a `--headless` launch is authorized by, consumed by the app at startup
    /// (`HeadlessMode.configure`, which reads this exact path and deletes it).
    ///
    /// argv cannot authorize the run on its own: it outlives the launch that carried
    /// it, so a `--headless` argv with no CLI behind it — replayed by the window server,
    /// or typed by hand — would bring the browser up with nothing on screen and nothing
    /// saying why. This file exists only between `open` and the app reading it.
    ///
    /// It is the ONE thing this package writes into `~/.alohajet`, the app's own home:
    /// the path is not a choice, it is the handshake the app defines.
    public nonisolated static var headlessLaunchTokenPath: String {
        (FileManager.default.homeDirectoryForCurrentUser.path as NSString)
            .appendingPathComponent(".alohajet/headless-launch")
    }

    private func writeLaunchToken() {
        try? FileManager.default.createDirectory(
            atPath: (launchTokenPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: launchTokenPath, contents: Data())
    }

    private func clearLaunchToken() {
        try? FileManager.default.removeItem(atPath: launchTokenPath)
    }

    // MARK: - The readiness probe

    /// The production probe: one real `GET /state`.
    public static let liveProbe: Probe = { await probe(endpoint: $0) }

    /// One `GET /state` against the automation server, through the SAME transport the
    /// driver uses — so the same bearer token is presented and a rotation is picked up.
    /// Only a 200 counts: a 401 means the listener is up but this CLI cannot drive it,
    /// and reporting "ready" then would just move the failure one step later. `nil` is
    /// "not reachable"; a 200 whose body carries neither boolean is reachable with an
    /// UNKNOWN state, never an assumed one.
    static func probe(
        endpoint: URL,
        transport: RemoteAutomationDriver.Transport = RemoteAutomationDriver.liveTransport
    ) async -> AlohaAppState? {
        guard let response = try? await transport("GET", endpoint.appendingPathComponent("state"), nil),
              response.statusCode == 200
        else { return nil }
        let object = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any]
        return AlohaAppState(
            headless: object?["headless"] as? Bool,
            visibleWindow: object?["visibleWindow"] as? Bool)
    }

    // MARK: - Which app, and how it is launched

    /// What to CALL the host in a log line: the bundle this executable ships inside. A
    /// `swift build` product has no host to name and says so generically.
    static var hostName: String {
        guard let bundle = appBundlePath() else { return "the Aloha browser" }
        return ((bundle as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    /// The `.app` this run drives: `ALOHA_BROWSER_APP` when it names one, else the
    /// bundle this executable ships inside, else `nil` — which is the signal to let
    /// LaunchServices pick by bundle identifier.
    nonisolated static func appBundlePath(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if let path = environment[appPathEnvKey], !path.isEmpty { return path }
        let executable = Bundle.main.executableURL?.resolvingSymlinksInPath().path
        return executable.flatMap(appBundlePath(forExecutable:))
    }

    /// The `.app` an executable at this path ships inside
    /// (`<X>.app/Contents/Helpers/alohajet`), or `nil` when it does not — a
    /// `swift build` product, or a copy someone moved out of the bundle.
    ///
    /// `MacOS` is accepted alongside `Helpers` for builds made before the helper moved:
    /// on case-insensitive APFS `Contents/MacOS/alohajet` collides with the AlohaJet
    /// variant's own `Contents/MacOS/AlohaJet` executable.
    nonisolated static func appBundlePath(forExecutable path: String) -> String? {
        let directory = (path as NSString).deletingLastPathComponent
        let name = (directory as NSString).lastPathComponent
        guard name == "Helpers" || name == "MacOS" else { return nil }
        let contents = (directory as NSString).deletingLastPathComponent
        guard (contents as NSString).lastPathComponent == "Contents" else { return nil }
        let bundle = (contents as NSString).deletingLastPathComponent
        guard (bundle as NSString).pathExtension == "app" else { return nil }
        return bundle
    }

    /// `open(1)`'s argument list. `app` names WHICH copy — `["-a", <path>]` when we know
    /// our own bundle (the CLI must drive the app it shipped inside, not whichever
    /// registered copy LaunchServices would pick for the scheme), `["-b", <id>]` when it
    /// has to pick, `[]` for neither.
    ///
    /// Options precede the URL operand and `--args` is last — everything after it lands
    /// in the launched app's argv. `-g` only keeps the launch out of the foreground; the
    /// app's own `--headless` handling is what hides it.
    nonisolated static func openArguments(url: String, app: [String], headless: Bool) -> [String] {
        (headless ? ["-g"] : []) + app + [url] + (headless ? ["--args", "--headless"] : [])
    }

    /// The production opener. `open(1)` — not NSWorkspace — so this stays a plain
    /// Foundation CLI with no AppKit link.
    public static let liveOpen: Opener = { url, headless in
        try openApp(url: url, headless: headless, run: run)
    }

    /// With a known bundle there is exactly one attempt and its failure is final;
    /// without one, every registered identifier is tried IN TURN and the failure names
    /// each with its own reason — "could not launch" without that list leaves the user
    /// guessing which product this binary was even looking for, on a machine where the
    /// answer is usually "the one I did not install".
    ///
    /// The child process is injected so this ladder can be proven without handing
    /// LaunchServices a real deep link.
    nonisolated static func openApp(
        url: String, headless: Bool,
        app: String? = appBundlePath(),
        run: (String, [String]) throws -> Void
    ) throws {
        if let app {
            try run("/usr/bin/open", openArguments(url: url, app: ["-a", app], headless: headless))
            return
        }
        var failures: [String] = []
        for identifier in bundleIdentifiers {
            do {
                try run("/usr/bin/open", openArguments(url: url, app: ["-b", identifier], headless: headless))
                return
            } catch AlohaAppLaunchError.launchFailed(let detail) {
                failures.append("\(identifier): \(detail)")
            } catch {
                failures.append("\(identifier): \(error)")
            }
        }
        throw AlohaAppLaunchError.launchFailed("tried " + failures.joined(separator: "; "))
    }

    // MARK: - The instance this run is allowed to stop

    /// The pids of the `.app` this run drives — empty when there is none to name (a
    /// `swift build` product), which leaves the launcher as it was.
    public static let liveInstances: Instances = {
        guard let bundle = appBundlePath() else { return [] }
        return pids(matching: bundle + "/Contents/MacOS/")
    }

    public static let liveTerminate: Terminator = { pids in
        for pid in pids { _ = kill(pid, SIGTERM) }
    }

    /// A pgrep that cannot run reports nothing, which the caller reads as "no instance"
    /// — falling through to the launch-and-wait it would have done anyway.
    nonisolated static func pids(matching pattern: String) -> Set<Int32> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", pattern]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return [] }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Set(
            String(decoding: data, as: UTF8.self)
                .split(separator: "\n")
                .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) })
    }

    /// Run a child process to completion; a non-zero exit is a `launchFailed` carrying
    /// its stderr. A near-twin of `BrowserTools.AlohaBrowser.run` — the two lanes do not
    /// link each other, and their `open(1)` invocations differ (a deep link and a
    /// headless argv here, a bare activation there).
    nonisolated static func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let errorPipe = Pipe()
        process.standardError = errorPipe
        do {
            try process.run()
        } catch {
            throw AlohaAppLaunchError.launchFailed("\(executable): \(error)")
        }
        let stderr = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: stderr, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw AlohaAppLaunchError.launchFailed(
                "\(executable) exited \(process.terminationStatus): \(detail)")
        }
    }
}
