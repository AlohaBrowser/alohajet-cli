import Foundation
import Testing

// Everything here is reachable WITHOUT a browser: the CLI connects before it dispatches a
// command, so a case that has to reach `toolCall` needs a live Chromium and lives in the
// end-to-end suite instead. What is left is the argument grammar, the help surface, and
// the exit-code contract — which is exactly the part a release can break silently.
//
// Exit codes: 0 ok · 1 tool error · 2 usage · 3 browser unreachable.

// `.serialized`: every case here BLOCKS its thread in `waitUntilExit`. Run in parallel,
// two dozen of them plus their pipe readers drain the cooperative thread pool and the
// whole test process wedges — the tests do not fail, they stop.
@Suite("CLI argument parsing", .serialized)
struct CLIArgumentTests {

    @Test func noArgumentsPrintsUsageAndFailsAsUsage() throws {
        let run = try runCLI([])
        #expect(run.status == 2)
        #expect(run.stdout.contains("USAGE"))
        #expect(run.stdout.contains("alohajet mcp") || run.stdout.contains("mcp"))
    }

    static let commands = [
        "open", "read", "tabs", "close", "quit", "click", "type",
        "select", "text", "goto", "back", "keys", "wait", "upload", "mcp",
    ]

    @Test func helpAloneSucceeds() throws {
        let run = try runCLI(["--help"])
        #expect(run.status == 0)
        #expect(run.stdout.contains("COMMANDS"))
        #expect(run.stdout.contains("EXIT CODES"))
        let agent = try #require(run.stdout.range(of: "\nAGENT\n"))
        let commands = try #require(run.stdout.range(of: "\nCOMMANDS\n"))
        #expect(agent.lowerBound < commands.lowerBound)
        #expect(!run.stdout.contains("/agent/task"))
    }

    @Test("every help page fits 80 columns with one description column",
          arguments: [["--help"]] + commands.map { [$0, "--help"] })
    func helpFitsATerminal(_ arguments: [String]) throws {
        let run = try runCLI(arguments)
        #expect(run.status == 0, "exited \(run.status): \(run.combined)")
        var columns = Set<Int>()
        for line in run.stdout.split(separator: "\n", omittingEmptySubsequences: false) {
            #expect(line.count <= 80, "\(line.count) columns: \(line)")
            #expect(!line.contains("\t") && line.last?.isWhitespace != true, "\(line.debugDescription)")
            if line.hasPrefix("   ") {
                columns.insert(line.prefix { $0 == " " }.count)
            } else if line.hasPrefix("  "), let gap = line.dropFirst(2).range(of: "  ") {
                columns.insert(line.distance(from: line.startIndex, to: gap.lowerBound)
                    + line[gap.lowerBound...].prefix { $0 == " " }.count)
            }
        }
        #expect(columns.count <= 1, "description columns \(columns.sorted())")
    }

    /// Every command the usage block advertises must have a `<command> --help` page.
    /// A command documented only in the summary line is how `click --double` ended up
    /// undiscoverable.
    @Test("every command has its own help page", arguments: commands)
    func perCommandHelp(_ command: String) throws {
        let run = try runCLI([command, "--help"])
        #expect(run.status == 0, "\(command) --help exited \(run.status)")
        #expect(run.stdout.contains("alohajet \(command)") || run.stdout.contains(command),
                "\(command) --help printed nothing about itself")
    }

    /// `upload` is the one verb whose arguments are VARIADIC — a ref then any number of
    /// paths — so the summary line has to say so or the shape is undiscoverable, which is
    /// how `click --double` went unused.
    @Test func uploadAdvertisesItsVariadicShape() throws {
        let usage = try runCLI(["--help"])
        #expect(usage.stdout.contains("upload <ref> <path>"))

        let help = try runCLI(["upload", "--help"])
        #expect(help.status == 0)
        #expect(help.stdout.contains("alohajet [--tab <id>] upload <ref> <path> [<path>...]"))
    }

    @Test func helpForAnUnknownCommandIsAUsageError() throws {
        let run = try runCLI(["frobnicate", "--help"])
        #expect(run.status == 2)
        #expect(run.stderr.contains("unknown command"))
    }

    // MARK: - Value flags

    /// THE MALFORMED-PORT CASE. `--port` used to be parsed inside the launch closure,
    /// which meant two bugs at once: with a shared browser already recorded the flag was
    /// silently ignored, and without one the `CLIError` it throws fell through the launch
    /// path's catch-all and was printed as the STRUCT — `CLIError(message: "--port
    /// expects a number, got \"frotz\"", code: 2)` — under exit code 3 rather than 2.
    @Test("a non-numeric --port is a usage error on every lane", arguments: [
        ["--port", "frotz", "tabs"],
        ["--port=frotz", "tabs"],
        ["--launch", "--port", "frotz", "tabs"],
    ])
    func malformedPortIsAUsageError(_ arguments: [String]) throws {
        let run = try runCLI(arguments)
        #expect(run.status == 2, "exited \(run.status): \(run.combined)")
        #expect(run.stderr.contains("--port expects a number"))
        #expect(!run.stderr.contains("CLIError("), "the error struct leaked into the message")
    }

    @Test func aValueFlagWithNoValueIsAUsageError() throws {
        for flag in ["--cdp", "--browser", "--port", "--tab", "--text", "--index", "--timeout-ms", "--max-chars"] {
            let run = try runCLI([flag])
            #expect(run.status == 2, "\(flag) exited \(run.status)")
            #expect(run.stderr.contains("expects a value"), "\(flag): \(run.combined)")
        }
    }

    /// `--cdp` takes a ws:// url, a port, or host:port. Anything else is the caller's
    /// mistake (2), not an unreachable browser (3) — the two are different problems and
    /// the exit code is how a script tells them apart.
    @Test("an unparseable --cdp endpoint is a usage error", arguments: [
        "not-an-endpoint", "example.com:not-a-port", "a:b:c",
    ])
    func unparseableCdpEndpoint(_ endpoint: String) throws {
        let run = try runCLI(["--cdp", endpoint, "tabs"])
        #expect(run.status == 2, "exited \(run.status): \(run.combined)")
        #expect(run.stderr.contains("--cdp expects"))
    }

    /// A well-formed endpoint pointing at nothing is the OTHER answer: unreachable (3).
    /// Port 1 is privileged and unbound, so the connection is refused immediately.
    @Test func aDeadCdpEndpointIsUnreachableNotUsage() throws {
        let run = try runCLI(["--cdp", "1", "tabs"], timeout: 60)
        #expect(run.status == 3, "exited \(run.status): \(run.combined)")
    }

    /// `alohajet type <ref> -- -50%` — everything after `--` is a positional, so a value
    /// that looks like a flag can still be typed into a page.
    @Test func doubleDashEndsFlagParsing() throws {
        // `--port` after `--` must be a positional, so it can no longer be a bad port.
        // If the terminator were ignored this would exit 2 with "--port expects a number".
        let run = try runCLI(["--cdp", "1", "type", "ref", "--", "--port", "frotz"], timeout: 60)
        #expect(run.status == 3, "exited \(run.status): \(run.combined)")
        #expect(!run.stderr.contains("--port expects a number"))
    }

    // MARK: - `--browser`, the lane selector

    // Nothing here names `--browser aloha` on its own: that lane probes 127.0.0.1:9222 and
    // then LAUNCHES the Aloha browser, and a test suite must not open the developer's real
    // browser. What is left is every case answered before a probe is made.

    @Test("an unknown --browser is a usage error naming both lanes", arguments: [
        ["--browser", "frotz", "tabs"],
        ["--browser=frotz", "tabs"],
    ])
    func unknownBrowserIsAUsageError(_ arguments: [String]) throws {
        let run = try runCLI(arguments)
        #expect(run.status == 2, "exited \(run.status): \(run.combined)")
        #expect(run.stderr.contains("--browser expects chromium or aloha"))
    }

    /// `--browser aloha --cdp <x>` names two different browsers. Silently preferring one
    /// would drive a browser the caller did not ask for, so it is refused BEFORE either is
    /// contacted — which is also why this case is safe to run: no probe, no launch.
    @Test func alohaAndCdpTogetherAreRefusedBeforeEitherIsContacted() throws {
        let run = try runCLI(["--browser", "aloha", "--cdp", "9222", "tabs"])
        #expect(run.status == 2, "exited \(run.status): \(run.combined)")
        #expect(run.stderr.contains("two different browsers"))
    }

    /// `--browser chromium` is the default spelled out: it must behave exactly like no
    /// flag at all, which here means falling through to `--cdp` and its dead endpoint (3),
    /// not tripping the selector's own usage error (2).
    @Test func chromiumIsTheDefaultSpelledOut() throws {
        let run = try runCLI(["--browser", "chromium", "--cdp", "1", "tabs"], timeout: 60)
        #expect(run.status == 3, "exited \(run.status): \(run.combined)")
        #expect(!run.stderr.contains("--browser expects"))
    }

    /// `ALOHAJET_BROWSER` naming something that is not an executable used to fall through
    /// to whatever Chrome the machine happens to have — so a typo'd path ran a browser
    /// with a different profile, different extensions and a different user agent, and
    /// said nothing. It fails, and it names the variable and the path.
    @Test func anUnusableBrowserPathFailsInsteadOfLaunchingAnotherBrowser() throws {
        let run = try runCLI(
            ["--launch", "tabs"],
            environment: ["ALOHAJET_BROWSER": "/nonexistent/chrome"], timeout: 60)
        #expect(run.status == 3, "exited \(run.status): \(run.combined)")
        #expect(run.stderr.contains("ALOHAJET_BROWSER"), "\(run.combined)")
        #expect(run.stderr.contains("/nonexistent/chrome"), "\(run.combined)")
        #expect(!run.stderr.contains("downloading"), "\(run.combined)")
    }

    // MARK: - The one command that never opens a browser

    /// `quit` goes to the recorded browser, not through `connect`. With a private TMPDIR
    /// there is no record, so it must say so and succeed — not launch a browser in order
    /// to close it.
    @Test func quitWithNoSharedBrowserSucceedsQuietly() throws {
        let run = try runCLI(["quit"])
        #expect(run.status == 0, "exited \(run.status): \(run.combined)")
        #expect(run.stdout.contains("No shared browser"))
    }

    // MARK: - `-p`, the agent entry

#if canImport(Darwin)
    /// No `--endpoint` is no longer a usage error: the binary ships inside the app whose
    /// agent it drives, so the loopback automation server beside it is the default and
    /// the flag is the exception. Proven without launching anything by pointing
    /// `ALOHA_BROWSER_APP` at a bundle that does not exist — `open -a` then fails
    /// outright rather than falling back to whatever claims the scheme — which also
    /// pins the OTHER half: the default lane goes through the app launcher, so its
    /// failure is exit 3 (browser unreachable), not 2.
    @Test func promptWithoutAnEndpointDrivesTheAppOnThisMachine() throws {
        let run = try runCLI(
            ["-p", "book me a table"],
            environment: ["ALOHA_BROWSER_APP": "/nonexistent/NoSuch.app"])
        #expect(run.status == 3, "exited \(run.status): \(run.combined)")
        #expect(run.stderr.contains("could not launch the Aloha browser"))
        #expect(run.stderr.contains("/nonexistent/NoSuch.app"))
    }
#endif

    /// `--endpoint "$VAR"` with the variable unset has still NAMED a host; answering it
    /// with the local default would run the prompt against a browser nobody asked for.
    @Test func anEmptyEndpointIsAUsageError() throws {
        let run = try runCLI(["-p", "hi", "--endpoint="])
        #expect(run.status == 2, "exited \(run.status): \(run.combined)")
        #expect(run.stderr.contains("--endpoint expects an http(s) URL"))
    }

    /// `-p ""` is a typo, not a turn.
    @Test func anEmptyPromptIsAUsageError() throws {
        let run = try runCLI(["-p", ""])
        #expect(run.status == 2, "exited \(run.status): \(run.combined)")
        #expect(run.stderr.contains("needs a prompt"))
    }

    /// `URL(string: "localhost:8765")` PARSES — with `localhost` as the scheme — so a
    /// bare host:port would otherwise reach the transport and fail far from the typo.
    @Test("a schemeless or non-http --endpoint is a usage error", arguments: [
        "localhost:8765", "127.0.0.1:8765", "ftp://127.0.0.1:8765", "http://",
    ])
    func aMalformedEndpointIsAUsageError(_ endpoint: String) throws {
        let run = try runCLI(["-p", "hi", "--endpoint", endpoint])
        #expect(run.status == 2, "exited \(run.status): \(run.combined)")
        #expect(run.stderr.contains("--endpoint expects an http(s) URL"))
    }

    /// A well-formed endpoint pointing at nothing is a failed TURN (1), not a usage
    /// error and not the browser-unreachable code — `-p` never touches a browser.
    @Test func aDeadAgentEndpointIsAFailedTurn() throws {
        let run = try runCLI(["-p", "hi", "--endpoint", "http://127.0.0.1:1", "--json"], timeout: 60)
        #expect(run.status == 1, "exited \(run.status): \(run.combined)")
        #expect(run.stdout.contains(#""isSuccess":false"#))
        #expect(run.stdout.contains("transport error"))
    }
}
