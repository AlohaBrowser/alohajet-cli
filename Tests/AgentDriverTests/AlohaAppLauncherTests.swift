import Testing
import Foundation
@testable import AgentDriver

// MARK: - Launching the app `alohajet -p` drives
//
// Hermetic: the LaunchServices call, the `GET /state` probe and the pid lookup are all
// injected, so nothing here spawns `open(1)`, opens a socket or signals a process.
//
// What is pinned is the part a 20-second timeout cannot say: the FOUR shapes that can
// never work are refused by name, before the wait rather than after it. `open --args`
// reaches a cold launch only, so a `--headless` run handed to a live windowed instance
// would silently drive a browser the user can see while reporting itself headless — and
// the reverse leaves a turn talking to a browser nobody can see.

@Suite("AlohaAppLauncher")
struct AlohaAppLauncherTests {

    /// Records every `(url, headless)` open; optionally fails like a broken
    /// LaunchServices.
    nonisolated final class OpenSpy: @unchecked Sendable {
        private(set) var opened: [(url: String, headless: Bool)] = []
        var error: Error?
        func open(_ url: String, _ headless: Bool) throws {
            opened.append((url, headless))
            if let error { throw error }
        }
        var urls: [String] { opened.map(\.url) }
    }

    /// Answers `nil` for the first `nilAnswers` probes, then `state` forever — a cold
    /// start: connection refused until the listener binds.
    nonisolated final class ProbeSpy: @unchecked Sendable {
        private(set) var calls = 0
        var nilAnswers: Int
        var alwaysNil = false
        var state = AlohaAppState(headless: false, visibleWindow: true)
        init(nilAnswers: Int = 0) { self.nilAnswers = nilAnswers }
        func probe(_ url: URL) async -> AlohaAppState? {
            calls += 1
            if alwaysNil { return nil }
            return calls > nilAnswers ? state : nil
        }
    }

    /// The app's pids as this run sees them, and what it stopped.
    nonisolated final class ProcessSpy: @unchecked Sendable {
        var running: Set<Int32> = []
        /// Pids the open makes appear, i.e. the instance THIS run launched.
        var launches: Set<Int32> = []
        private(set) var terminated: [Set<Int32>] = []
        func didOpen() { running.formUnion(launches) }
        func terminate(_ pids: Set<Int32>) {
            terminated.append(pids)
            running.subtract(pids)
        }
    }

    private func launcher(
        open: OpenSpy, probe: ProbeSpy, attempts: Int = 5,
        processes: ProcessSpy = ProcessSpy(),
        tokenPath: String = AlohaAppLauncherTests.scratchTokenPath()
    ) -> AlohaAppLauncher {
        AlohaAppLauncher(
            probe: { await probe.probe($0) },
            open: { try open.open($0, $1); processes.didOpen() },
            instances: { processes.running },
            terminate: { processes.terminate($0) },
            pollInterval: .zero,
            attempts: attempts,
            launchTokenPath: tokenPath)
    }

    /// The real token lives at one fixed path, so every test that touches one gets its
    /// own instead of racing the rest of the suite for it.
    private static func scratchTokenPath() -> String {
        NSTemporaryDirectory() + "aloha-launch-token-\(UUID().uuidString)"
    }

    private let endpoint = URL(string: AlohaAppLauncher.defaultEndpoint)!

    // MARK: - The four refusals

    // Refused BEFORE the open: activating that instance drops the argv and drives a
    // windowed browser while claiming to be headless.
    @Test("--headless against a visible window is refused, and nothing is opened")
    func headlessRefusesAWindowedApp() async throws {
        for state in [
            AlohaAppState(headless: false, visibleWindow: true),
            AlohaAppState(headless: true, visibleWindow: true),
            AlohaAppState(headless: false, visibleWindow: false),
        ] {
            let open = OpenSpy()
            let probe = ProbeSpy()
            probe.state = state

            await #expect(throws: AlohaAppLaunchError.alreadyRunningVisible) {
                try await launcher(open: open, probe: probe)
                    .ensureRunning(endpoint: endpoint, headless: true) { _ in }
            }
            #expect(open.opened.isEmpty)
        }
        #expect(AlohaAppLaunchError.alreadyRunningVisible.description
            == "app already running with a visible window — quit it, or drop --headless")
    }

    // The mirror image: a run that did NOT ask for headless must never drive an
    // instance the user cannot see.
    @Test("a plain run refuses a headless instance rather than driving an invisible browser")
    func plainRunRefusesAHeadlessInstance() async throws {
        let probe = ProbeSpy()
        probe.state = AlohaAppState(headless: true, visibleWindow: false)

        await #expect(throws: AlohaAppLaunchError.alreadyRunningHeadless) {
            try await launcher(open: OpenSpy(), probe: probe).ensureRunning(endpoint: endpoint) { _ in }
        }
        #expect(probe.calls == 1, "the refusal is immediate, not after the wait budget")
        let message = AlohaAppLaunchError.alreadyRunningHeadless.description
        #expect(message.contains("no window on screen"))
        #expect(message.contains("add --headless to drive it"))
    }

    // Absence is loud: a browser too old to report either boolean is not read as
    // "windowed", it is refused for not answering the question — and only a run that
    // asked for `--headless` needs the answer.
    @Test("a /state missing either boolean is unknown, not false")
    func headlessRefusesAnUnknownState() async throws {
        for state in [
            AlohaAppState(headless: nil, visibleWindow: false),
            AlohaAppState(headless: true, visibleWindow: nil),
            AlohaAppState(headless: nil, visibleWindow: nil),
        ] {
            let open = OpenSpy()
            let probe = ProbeSpy()
            probe.state = state

            await #expect(throws: AlohaAppLaunchError.headlessStateUnknown) {
                try await launcher(open: open, probe: probe)
                    .ensureRunning(endpoint: endpoint, headless: true) { _ in }
            }
            #expect(open.opened.isEmpty)
        }
        #expect(AlohaAppLaunchError.headlessStateUnknown.description
            == "the automation server did not report its headless state; update the browser or drop --headless")

        // The same browser is fine for a run that never asked the question.
        let plain = ProbeSpy()
        plain.state = AlohaAppState(headless: nil, visibleWindow: nil)
        try await launcher(open: OpenSpy(), probe: plain).ensureRunning(endpoint: endpoint) { _ in }
    }

    @Test("a refused launch names every bundle identifier it tried, with its reason")
    func launchFailureNamesTheBundleIdentifiers() throws {
        var attempted: [[String]] = []
        #expect(throws: AlohaAppLaunchError.self) {
            try AlohaAppLauncher.openApp(url: AlohaAppLauncher.attachURL, headless: false, app: nil) {
                attempted.append($1)
                throw AlohaAppLaunchError.launchFailed("/usr/bin/open exited 1: no app")
            }
        }
        #expect(attempted.map { $0[1] } == AlohaAppLauncher.bundleIdentifiers, "both, in order")

        do {
            try AlohaAppLauncher.openApp(url: AlohaAppLauncher.attachURL, headless: false, app: nil) { _, _ in
                throw AlohaAppLaunchError.launchFailed("/usr/bin/open exited 1: no app")
            }
        } catch {
            let message = (error as? AlohaAppLaunchError)?.description ?? "\(error)"
            for identifier in AlohaAppLauncher.bundleIdentifiers { #expect(message.contains(identifier)) }
            #expect(message.contains("could not launch the Aloha browser"))
            #expect(message.contains("no app"), "and the reason each one gave")
        }

        // A known bundle is the only candidate there is: one attempt, and its failure
        // is final rather than a fall-through to somebody else's copy.
        var single: [[String]] = []
        #expect(throws: AlohaAppLaunchError.self) {
            try AlohaAppLauncher.openApp(
                url: AlohaAppLauncher.attachURL, headless: false, app: "/Volumes/dev/Aloha.app"
            ) {
                single.append($1)
                throw AlohaAppLaunchError.launchFailed("nope")
            }
        }
        #expect(single == [["-a", "/Volumes/dev/Aloha.app", AlohaAppLauncher.attachURL]])
    }

    // MARK: - The happy path

    @Test("nothing running: the app is opened once and the wait is on the listener, not a sleep")
    func coldStartLaunchesAndWaitsForTheListener() async throws {
        let open = OpenSpy()
        let probe = ProbeSpy(nilAnswers: 3)
        var log: [String] = []

        try await launcher(open: open, probe: probe, attempts: 10)
            .ensureRunning(endpoint: endpoint) { log.append($0) }

        #expect(open.urls == [AlohaAppLauncher.attachURL], "the deep link, exactly once")
        #expect(open.opened.map(\.headless) == [false])
        #expect(probe.calls == 4, "three refusals then the bind — no fixed delay")
        #expect(log.contains { $0.contains("reachable") }, "the wait was real, so it is reported")

        // An app that was already up is the quiet case: one probe, no wait, and nothing
        // on the stderr the answer's chat id has to be findable in.
        let warm = ProbeSpy()
        var warmLog: [String] = []
        try await launcher(open: OpenSpy(), probe: warm)
            .ensureRunning(endpoint: endpoint) { warmLog.append($0) }
        #expect(warm.calls == 1)
        #expect(!warmLog.contains { $0.contains("reachable") })
    }

    @Test("nothing running, --headless: the launch is headless and the app it brings up is gated too")
    func headlessColdStart() async throws {
        let open = OpenSpy()
        let probe = ProbeSpy(nilAnswers: 2)
        probe.state = AlohaAppState(headless: true, visibleWindow: false)

        try await launcher(open: open, probe: probe, attempts: 10)
            .ensureRunning(endpoint: endpoint, headless: true) { _ in }
        #expect(open.opened.map(\.headless) == [true])

        // The same launch, but what came up has a window: refused after the fact, on
        // exactly the same rule as before it.
        let windowed = ProbeSpy(nilAnswers: 1)
        windowed.state = AlohaAppState(headless: false, visibleWindow: true)
        await #expect(throws: AlohaAppLaunchError.alreadyRunningVisible) {
            try await launcher(open: OpenSpy(), probe: windowed)
                .ensureRunning(endpoint: endpoint, headless: true) { _ in }
        }
    }

    @Test("an app that never answers fails loud, naming the endpoint and the toggle")
    func neverReachable() async throws {
        let probe = ProbeSpy()
        probe.alwaysNil = true

        await #expect(throws: AlohaAppLaunchError.self) {
            try await launcher(open: OpenSpy(), probe: probe, attempts: 4)
                .ensureRunning(endpoint: endpoint) { _ in }
        }
        #expect(probe.calls == 4, "the budget is spent, then it stops")

        let message = AlohaAppLaunchError
            .notReachable(endpoint: endpoint.absoluteString, seconds: 30).description
        #expect(message.contains("http://127.0.0.1:8765"))
        #expect(message.contains("after 30s"))
        #expect(message.contains("Settings"))
    }

    // MARK: - Which endpoints are this machine's app

    // Loopback is not enough: the app binds ONE port, so a launch cannot make it answer
    // on another one — and a turn against a stub, a tunnel or a second instance must not
    // pay a 30s wait for an app that was never going to serve it.
    @Test("only the local app's own endpoint is launched; anything else is left alone")
    func onlyTheLocalAppIsLaunched() async throws {
        #expect(AlohaAppLauncher.defaultEndpoint == "http://127.0.0.1:8765")
        #expect(AlohaAppLauncher.servesLocalApp(endpoint))
        #expect(AlohaAppLauncher.servesLocalApp(URL(string: "http://localhost:8765")!))
        #expect(AlohaAppLauncher.servesLocalApp(URL(string: "http://[::1]:8765")!))
        #expect(!AlohaAppLauncher.servesLocalApp(URL(string: "http://127.0.0.1:49152")!))
        #expect(!AlohaAppLauncher.servesLocalApp(URL(string: "https://agents.example.com:8765")!))

        let open = OpenSpy()
        let probe = ProbeSpy()
        var log: [String] = []
        try await launcher(open: open, probe: probe)
            .ensureRunning(endpoint: URL(string: "http://127.0.0.1:49152")!) { log.append($0) }
        #expect(open.opened.isEmpty)
        #expect(probe.calls == 0, "not even a probe — the driver's own round trip is the report")
        #expect(log.isEmpty)

        // …except that `--headless` asked for something only a launch can set, so its
        // silence would be a lie.
        try await launcher(open: OpenSpy(), probe: ProbeSpy())
            .ensureRunning(endpoint: URL(string: "http://127.0.0.1:49152")!, headless: true) {
                log.append($0)
            }
        #expect(log.contains { $0.contains("--headless") })
    }

    // MARK: - The readiness probe

    @Test("the probe reads GET /state over the driver's own (token-carrying) transport")
    func probeReadsState() async {
        nonisolated final class Recorder: @unchecked Sendable {
            var requests: [String] = []
        }
        func transport(status: Int?, body: String = "", into recorder: Recorder)
            -> RemoteAutomationDriver.Transport
        {
            { method, url, _ in
                recorder.requests.append("\(method) \(url.absoluteString)")
                guard let status else { throw URLError(.cannotConnectToHost) }
                return RemoteAutomationHTTPResponse(statusCode: status, body: Data(body.utf8))
            }
        }

        let recorder = Recorder()
        let state = await AlohaAppLauncher.probe(
            endpoint: endpoint,
            transport: transport(
                status: 200, body: #"{"headless":true,"visibleWindow":false}"#, into: recorder))
        #expect(state == AlohaAppState(headless: true, visibleWindow: false))
        #expect(recorder.requests == ["GET http://127.0.0.1:8765/state"])

        // Reachable, but the body says nothing about the launch mode: absent, not guessed.
        #expect(await AlohaAppLauncher.probe(
            endpoint: endpoint, transport: transport(status: 200, body: "not json", into: Recorder()))
            == AlohaAppState(headless: nil, visibleWindow: nil))

        // A 401 is a listener this CLI cannot drive, and a refused socket is no listener
        // at all: both are "not reachable", never a ready report that fails one step later.
        #expect(await AlohaAppLauncher.probe(
            endpoint: endpoint, transport: transport(status: 401, into: Recorder())) == nil)
        #expect(await AlohaAppLauncher.probe(
            endpoint: endpoint, transport: transport(status: nil, into: Recorder())) == nil)
    }

    // MARK: - The one-shot launch token

    // What makes `--headless` govern exactly the launch that carried it: argv alone
    // outlives its launch, the token does not.
    @Test("the headless launch token exists for the launch and is gone after it")
    func launchTokenIsOneShot() async throws {
        #expect(AlohaAppLauncher.headlessLaunchTokenPath.hasSuffix("/.alohajet/headless-launch"))

        nonisolated final class Observed: @unchecked Sendable { var presentAtOpen = false }
        let path = Self.scratchTokenPath()
        let observed = Observed()
        let probe = ProbeSpy(nilAnswers: 1)
        probe.state = AlohaAppState(headless: true, visibleWindow: false)
        let subject = AlohaAppLauncher(
            probe: { await probe.probe($0) },
            open: { _, _ in observed.presentAtOpen = FileManager.default.fileExists(atPath: path) },
            instances: { [] }, terminate: { _ in },
            pollInterval: .zero, attempts: 5, launchTokenPath: path)

        try await subject.ensureRunning(endpoint: endpoint, headless: true) { _ in }

        #expect(observed.presentAtOpen, "the app has to find it at startup")
        #expect(!FileManager.default.fileExists(atPath: path), "and never after the run")

        // A plain run authorizes nothing, so it writes nothing.
        let plainPath = Self.scratchTokenPath()
        try await launcher(open: OpenSpy(), probe: ProbeSpy(), tokenPath: plainPath)
            .ensureRunning(endpoint: endpoint) { _ in }
        #expect(!FileManager.default.fileExists(atPath: plainPath))
    }

    // MARK: - A headless instance is never left behind

    @Test("a headless launch that never answers is stopped again before the failure")
    func headlessLaunchLeavesNoOrphan() async throws {
        let probe = ProbeSpy()
        probe.alwaysNil = true
        let processes = ProcessSpy()
        processes.launches = [777]
        let path = Self.scratchTokenPath()

        await #expect(throws: AlohaAppLaunchError.self) {
            try await launcher(open: OpenSpy(), probe: probe, attempts: 3, processes: processes,
                               tokenPath: path)
                .ensureRunning(endpoint: endpoint, headless: true) { _ in }
        }
        #expect(processes.terminated == [[777]], "an invisible process the user cannot close")
        #expect(!FileManager.default.fileExists(atPath: path), "and no token left to authorize a stray launch")
    }

    // The launch cannot help here: `--args` never reaches a running instance, so waiting
    // would only add a second, invisible process to the one already misbehaving.
    @Test("--headless against a running-but-silent app fails at once, naming the toggle")
    func headlessRefusesARunningAppWithNoAutomationServer() async throws {
        let open = OpenSpy()
        let probe = ProbeSpy()
        probe.alwaysNil = true
        let processes = ProcessSpy()
        processes.running = [4242]

        await #expect(throws: AlohaAppLaunchError.automationOff) {
            try await launcher(open: open, probe: probe, processes: processes)
                .ensureRunning(endpoint: endpoint, headless: true) { _ in }
        }
        #expect(open.opened.isEmpty, "nothing was launched")
        #expect(processes.terminated.isEmpty, "this run did not start that instance")
        #expect(AlohaAppLaunchError.automationOff.description.contains("Settings"))
    }

    // A launch that ended up WINDOWED is never stopped, whoever gave it the window: the
    // cleanup is for a process the user can neither see nor close, and one with a window
    // is neither — the usual way it happens is a person clicking it.
    @Test("a headless launch that ended up windowed is left running")
    func windowedLaunchIsLeftAlone() async throws {
        let probe = ProbeSpy(nilAnswers: 1)
        probe.state = AlohaAppState(headless: false, visibleWindow: true)
        let processes = ProcessSpy()
        processes.launches = [777]

        await #expect(throws: AlohaAppLaunchError.alreadyRunningVisible) {
            try await launcher(open: OpenSpy(), probe: probe, processes: processes)
                .ensureRunning(endpoint: endpoint, headless: true) { _ in }
        }
        #expect(processes.terminated.isEmpty)
        #expect(processes.running == [777])
    }

    // MARK: - How the app is opened

    // `open(1)`: options precede the URL operand and `--args` is last, so everything
    // after it lands in the launched app's argv.
    @Test("the open arguments carry the deep link, and --headless only through --args")
    func openArguments() {
        #expect(AlohaAppLauncher.openArguments(
            url: AlohaAppLauncher.attachURL, app: ["-a", "/Applications/AlohaJet.app"], headless: false)
            == ["-a", "/Applications/AlohaJet.app", "alohajet://attach"])
        #expect(AlohaAppLauncher.openArguments(
            url: AlohaAppLauncher.attachURL, app: ["-b", "com.alohabrowser.alohajet"], headless: true)
            == ["-g", "-b", "com.alohabrowser.alohajet", "alohajet://attach", "--args", "--headless"])
        #expect(AlohaAppLauncher.openArguments(url: AlohaAppLauncher.attachURL, app: [], headless: false)
            == ["alohajet://attach"])
    }

    @Test("the CLI drives the app bundle it ships inside, not whatever claims the scheme")
    func resolvesItsOwnBundle() {
        #expect(AlohaAppLauncher.appBundlePath(
            forExecutable: "/Applications/AlohaJet.app/Contents/Helpers/alohajet")
            == "/Applications/AlohaJet.app")
        // Where the helper shipped before it moved out of the case-insensitive collision
        // with the AlohaJet variant's own executable.
        #expect(AlohaAppLauncher.appBundlePath(
            forExecutable: "/Applications/AlohaJet.app/Contents/MacOS/alohajet")
            == "/Applications/AlohaJet.app")
        // A `swift build` product, or a copy moved out of the bundle: nothing to name,
        // so LaunchServices picks by identifier.
        #expect(AlohaAppLauncher.appBundlePath(forExecutable: "/usr/local/bin/alohajet") == nil)
        #expect(AlohaAppLauncher.appBundlePath(forExecutable: "/tmp/MacOS/alohajet") == nil)
        #expect(AlohaAppLauncher.appBundlePath(
            forExecutable: "/tmp/Some.bundle/Contents/MacOS/alohajet") == nil)

        // The env override wins over both — a dev build outside /Applications.
        #expect(AlohaAppLauncher.appBundlePath(
            environment: [AlohaAppLauncher.appPathEnvKey: "/Volumes/dev/Aloha.app"])
            == "/Volumes/dev/Aloha.app")
        #expect(AlohaAppLauncher.appBundlePath(
            environment: [AlohaAppLauncher.appPathEnvKey: ""]) == nil, "an empty value names nothing")
    }
}
