import Testing
import Foundation
@testable import BrowserTools

// The `--browser aloha` lane, on injected seams: no app is launched and no socket is
// opened. Ported in shape from the shipping CLI's `AlohaAppLauncherTests` — the cases
// about `GET /state`, headless/visibleWindow and the one-shot launch token did not
// travel, because none of that exists on the CDP wire (see AlohaBrowser.swift).

@Suite("AlohaBrowser")
struct AlohaBrowserTests {

    /// Answers `nil` until `readyAfter` probes have been made, then a URL. Counts both,
    /// so "did we launch?" and "did we wait?" are separate assertions.
    nonisolated final class Seams: @unchecked Sendable {
        var probes = 0
        var opens = 0
        var openError: Error?
        let readyAfter: Int

        init(readyAfter: Int) { self.readyAfter = readyAfter }

        func probe() -> AlohaBrowser.Probe {
            { [self] port in
                probes += 1
                guard probes > readyAfter else { return nil }
                return URL(string: "ws://127.0.0.1:\(port)/devtools/browser/abc")
            }
        }

        func open() -> AlohaBrowser.Opener {
            { [self] in
                opens += 1
                if let openError { throw openError }
            }
        }
    }

    private func launcher(_ seams: Seams, attempts: Int = 4) -> AlohaBrowser {
        AlohaBrowser(
            probe: seams.probe(), open: seams.open(),
            pollInterval: .milliseconds(1), attempts: attempts)
    }

    // MARK: - Reuse, wait, fail

    @Test("a browser already answering is reused: one probe, no launch")
    func reusesRunningBrowser() async throws {
        let seams = Seams(readyAfter: 0)
        let url = try await launcher(seams).endpoint(port: 9222)
        // The lane declares itself a keep-tabs client on the URL: without it the browser
        // reaps the tab this process opened the moment the process exits.
        #expect(url.absoluteString == "ws://127.0.0.1:9222/devtools/browser/abc?alohaKeepTabs=1")
        #expect(seams.probes == 1)
        #expect(seams.opens == 0)
    }

    @Test("a cold start launches once and waits for the listener, not for a fixed delay")
    func coldStartWaitsOnTheRealCondition() async throws {
        let seams = Seams(readyAfter: 3)
        let url = try await launcher(seams).endpoint(port: 9222)
        #expect(url.absoluteString.hasPrefix("ws://127.0.0.1:9222/"))
        #expect(url.absoluteString.hasSuffix("?alohaKeepTabs=1"))
        #expect(seams.opens == 1)
        // One pre-flight probe plus the polls it took to answer — never more.
        #expect(seams.probes == 4)
    }

    @Test("a browser that never answers is a loud failure naming the port and the reason")
    func neverAnswersFailsLoudly() async {
        let seams = Seams(readyAfter: .max)
        await #expect(throws: AlohaBrowserError.notReachable(port: 9222, seconds: 0)) {
            _ = try await launcher(seams).endpoint(port: 9222)
        }
        // One pre-flight, one launch, then every poll in the budget — and then it stops.
        #expect(seams.opens == 1)
        #expect(seams.probes == 5)

        let message = AlohaBrowserError.notReachable(port: 9222, seconds: 20).description
        #expect(message.contains("127.0.0.1:9222"))
        #expect(message.contains("after 20s"))
        #expect(message.contains("ALOHA_CDP_DISABLED"))
        #expect(message.contains("--cdp"))
    }

    @Test("the wait is bounded and the failure reports the real elapsed budget")
    func boundedWait() async {
        let seams = Seams(readyAfter: .max)
        let launcher = AlohaBrowser(
            probe: seams.probe(), open: seams.open(),
            pollInterval: .milliseconds(500), attempts: 4)
        await #expect(throws: AlohaBrowserError.notReachable(port: 7777, seconds: 2)) {
            _ = try await launcher.endpoint(port: 7777)
        }
        #expect(seams.probes == 5)
    }

    @Test("a LaunchServices failure is reported as such, and nothing is waited on")
    func launchFailureIsReported() async {
        let seams = Seams(readyAfter: .max)
        seams.openError = AlohaBrowserError.launchFailed("/usr/bin/open exited 1: no app")
        await #expect(throws: AlohaBrowserError.launchFailed("/usr/bin/open exited 1: no app")) {
            _ = try await launcher(seams).endpoint(port: 9222)
        }
        #expect(seams.probes == 1)
    }

    @Test("the keep-tabs opt-out is appended whatever query the browser's URL already has")
    func keepTabsAppending() {
        #expect(AlohaBrowser.keepingTabs(URL(string: "ws://127.0.0.1:9222/devtools/browser/abc")!)
            .absoluteString == "ws://127.0.0.1:9222/devtools/browser/abc?alohaKeepTabs=1")
        #expect(AlohaBrowser.keepingTabs(URL(string: "ws://127.0.0.1:9222/devtools/browser/abc?x=1")!)
            .absoluteString == "ws://127.0.0.1:9222/devtools/browser/abc?x=1&alohaKeepTabs=1")
    }

    // MARK: - Which port

    @Test("the port is ALOHA_CDP_PORT when it names a real one, else 9222")
    func portResolution() {
        #expect(AlohaBrowser.port(environment: [:]) == 9222)
        #expect(AlohaBrowser.port(environment: ["ALOHA_CDP_PORT": "9333"]) == 9333)
        // Anything unusable falls back rather than failing — the same rule the browser
        // applies to the same variable, so the two ends agree on where to look.
        #expect(AlohaBrowser.port(environment: ["ALOHA_CDP_PORT": "frotz"]) == 9222)
        #expect(AlohaBrowser.port(environment: ["ALOHA_CDP_PORT": "0"]) == 9222)
        #expect(AlohaBrowser.port(environment: ["ALOHA_CDP_PORT": "70000"]) == 9222)
        #expect(AlohaBrowser.port(environment: ["ALOHA_CDP_PORT": ""]) == 9222)
    }

    // MARK: - How the app is opened

    @Test("an explicit app path is the only thing tried; otherwise both bundle ids are")
    func openArguments() {
        #expect(AlohaBrowser.openArguments(appPath: "/Volumes/dev/Aloha.app")
            == [["-g", "-a", "/Volumes/dev/Aloha.app"]])
        let byIdentifier = AlohaBrowser.openArguments(appPath: nil)
        #expect(byIdentifier == [
            ["-g", "-b", "com.alohabrowser.alohabrowser"],
            ["-g", "-b", "com.alohabrowser.alohajet"],
        ])
        // `-g` on every one: a CLI run must not steal the user's focus.
        #expect(byIdentifier.allSatisfy { $0.first == "-g" })
    }

    @Test("the child-process runner throws the exit code and stderr on failure")
    func runReportsExitCode() {
        #expect(throws: AlohaBrowserError.self) {
            try AlohaBrowser.run("/usr/bin/false", [])
        }
        #expect(throws: Never.self) {
            try AlohaBrowser.run("/usr/bin/true", [])
        }
    }
}
