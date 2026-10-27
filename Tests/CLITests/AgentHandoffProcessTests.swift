#if os(Linux)
import Foundation
import Testing

// On Linux there is no Aloha app: the agent host is `alohajet-agent`, and `-p` and
// `mcp-stdio` without `--endpoint` replace this process with it. Every case runs the real
// binary against a stand-in agent that records what it was handed, so what is pinned is
// what a user's shell and a user's MCP host actually see: argv, stdin, the streams, the
// exit status and the signal state the agent starts with.

@Suite("handing -p and mcp-stdio to alohajet-agent", .serialized)
struct AgentHandoffProcessTests {

    static let chat = "33333333-3333-4333-8333-333333333333"

    @Test("-p hands the prompt and the flags it can honour to alohajet-agent", arguments: [
        (["-p", "two plus two"], ["-p", "two plus two"]),
        (["-p", "two plus two", "--json"], ["-p", "two plus two", "--json"]),
        (["--no-headless", "-p", "-50%"], ["-p", "-50%", "--no-headless"]),
        (["-p", "hi", "--accept-terms", "--json"], ["-p", "hi", "--json", "--accept-terms"]),
        (["-p", "hi", "--headless", "--grant-permissions", "none"], ["-p", "hi"]),
        (["-p", "hi", "--cdp", "9222", "--tab", "T1"], ["-p", "hi"]),
    ])
    func promptArguments(_ arguments: [String], _ expected: [String]) throws {
        let agent = try FakeAgent()
        defer { agent.remove() }
        let run = try runCLI(arguments, environment: agent.environment)
        #expect(run.status == 0, "\(run.combined)")
        #expect(agent.argv == expected)
    }

    @Test("the agent's exit status, stdout and stderr are the command's own", arguments: [0, 1, 7])
    func statusAndStreamsPassThrough(_ status: Int32) throws {
        let agent = try FakeAgent()
        defer { agent.remove() }
        var environment = agent.environment
        environment["FAKE_AGENT_EXIT"] = "\(status)"
        let run = try runCLI(["-p", "hi"], environment: environment)
        #expect(run.status == status)
        #expect(run.stdout == "agent stdout\n")
        #expect(run.stderr == "agent stderr\n")
    }

    @Test("mcp-stdio becomes alohajet-agent mcp, and the client's stdin is the agent's", arguments: [
        (["mcp-stdio"], ["mcp"]),
        (["mcp-stdio", "--no-headless"], ["mcp", "--no-headless"]),
        (["mcp-stdio", "--headless"], ["mcp"]),
    ])
    func mcpStdioHandsOverStdin(_ arguments: [String], _ expected: [String]) throws {
        let agent = try FakeAgent()
        defer { agent.remove() }
        let frames = """
            {"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}
            {"jsonrpc":"2.0","method":"notifications/initialized"}
            {"jsonrpc":"2.0","id":2,"method":"tools/list"}

            """
        var environment = agent.environment
        environment["FAKE_AGENT_EXIT"] = "5"
        let run = try runCLI(arguments, stdin: frames, environment: environment)
        #expect(run.status == 5)
        #expect(agent.argv == expected)
        #expect(agent.stdin == frames)
        #expect(run.stdout == "agent stdout\n")
    }

    @Test("mcp-stdio --accept-terms is refused: alohajet-agent mcp runs no turn and asks for no Terms")
    func mcpStdioRefusesAcceptTerms() throws {
        let agent = try FakeAgent()
        defer { agent.remove() }
        let run = try runCLI(["mcp-stdio", "--accept-terms"],
                             stdin: #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"# + "\n",
                             environment: agent.environment)
        #expect(run.status == 2, "\(run.combined)")
        #expect(run.stdout.isEmpty)
        #expect(run.stderr == "alohajet: an MCP session runs no turn and asks for no Terms of Service:"
            + " drop --accept-terms\n")
        #expect(agent.argv == nil, "the agent ran anyway")
    }

    /// This suite spawns the CLI the way a Swift MCP host would, through `Process` from a
    /// dispatch worker, so the CLI starts with nearly every signal blocked; it ignores
    /// SIGPIPE itself. Both survive an exec, and an agent started that way could not be
    /// stopped by its host.
    @Test("the agent starts with no signal blocked and SIGPIPE at its default", arguments: [
        ["-p", "hi"], ["mcp-stdio"],
    ])
    func signalStateIsTheAgentsOwn(_ arguments: [String]) throws {
        let agent = try FakeAgent()
        defer { agent.remove() }
        let run = try runCLI(arguments, environment: agent.environment)
        #expect(run.status == 0, "\(run.combined)")
        let blocked = try #require(agent.signalMask("SigBlk"))
        let ignored = try #require(agent.signalMask("SigIgn"))
        #expect(blocked == 0, "blocked: \(String(blocked, radix: 16))")
        #expect(ignored & (1 << (SIGPIPE - 1)) == 0, "ignored: \(String(ignored, radix: 16))")
    }

    @Test("the environment reaches the agent unchanged")
    func environmentPassesThrough() throws {
        let agent = try FakeAgent()
        defer { agent.remove() }
        var environment = agent.environment
        environment["FAKE_AGENT_PROBE"] = "carried over"
        _ = try runCLI(["-p", "hi"], environment: environment)
        #expect(agent.probe == "carried over")
    }

    // MARK: - Which alohajet-agent

    /// An install puts a symlink on PATH and the two binaries side by side somewhere
    /// else. The sibling is looked for beside the binary the link resolves to, never
    /// beside the link.
    @Test("without ALOHAJET_AGENT_BIN the agent is the one beside the CLI's resolved path")
    func siblingOfTheResolvedExecutable() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let install = try sandbox.directory("install")
        let cli = try sandbox.copyOfTheCLI(into: install)
        let agent = try FakeAgent(in: install)
        let onPath = try sandbox.directory("bin")
        let decoy = try FakeAgent(in: onPath)
        let link = onPath.appendingPathComponent("alohajet").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: cli)

        let run = try runCLI(["-p", "hi"], environment: ["ALOHAJET_AGENT_BIN": ""], binary: link)
        #expect(run.status == 0, "\(run.combined)")
        #expect(agent.argv == ["-p", "hi"])
        #expect(decoy.argv == nil, "the agent beside the symlink ran")
    }

    @Test("a missing alohajet-agent is named, with the variable that overrides it", arguments: [
        ["-p", "hi"], ["mcp-stdio"],
    ])
    func missingSiblingIsNamed(_ arguments: [String]) throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let cli = try sandbox.copyOfTheCLI(into: try sandbox.directory("lonely"))
        let expected = (cli as NSString).deletingLastPathComponent + "/alohajet-agent"

        let run = try runCLI(arguments, environment: ["ALOHAJET_AGENT_BIN": ""], binary: cli)
        #expect(run.status == 3, "\(run.combined)")
        #expect(run.stdout.isEmpty)
        #expect(run.stderr.contains(expected), "\(run.stderr)")
        #expect(run.stderr.contains("ALOHAJET_AGENT_BIN"), "\(run.stderr)")
        #expect(!run.stderr.contains("xdg-open") && !run.stderr.contains("could not launch"), "\(run.stderr)")
    }

    @Test("an ALOHAJET_AGENT_BIN that names no executable is refused by name", arguments: [
        "alohajet-agent", "./bin/alohajet-agent", "/nonexistent/alohajet-agent", "/tmp",
    ])
    func unusableOverrideIsNamed(_ value: String) throws {
        let run = try runCLI(["-p", "hi"], environment: ["ALOHAJET_AGENT_BIN": value])
        #expect(run.status == 3, "\(run.combined)")
        #expect(run.stderr.contains("ALOHAJET_AGENT_BIN"), "\(run.stderr)")
        #expect(run.stderr.contains(value), "\(run.stderr)")
    }

    // MARK: - What only the macOS app can do

    @Test("conversations and page permissions are refused before anything runs", arguments: [
        (["-p", "hi", "--resume", chat], "--resume"),
        (["-p", "hi", "--continue"], "--continue"),
        (["-p", "hi", "--grant-permissions", "camera"], "--grant-permissions camera"),
        (["-p", "hi", "--grant-permissions=all"], "--grant-permissions all"),
    ])
    func macOnlyFlagsAreRefused(_ arguments: [String], _ named: String) throws {
        let agent = try FakeAgent()
        defer { agent.remove() }
        let run = try runCLI(arguments, environment: agent.environment)
        #expect(run.status == 2, "\(run.combined)")
        #expect(run.stderr.contains(named), "\(run.stderr)")
        #expect(run.stderr.contains("the Aloha app on macOS"), "\(run.stderr)")
        #expect(agent.argv == nil, "the agent ran anyway")
    }

    @Test("--headless and --no-headless together are refused", arguments: [
        ["-p", "hi", "--headless", "--no-headless"], ["mcp-stdio", "--no-headless", "--headless"],
    ])
    func bothWindowModesAreRefused(_ arguments: [String]) throws {
        let agent = try FakeAgent()
        defer { agent.remove() }
        let run = try runCLI(arguments, environment: agent.environment)
        #expect(run.status == 2, "\(run.combined)")
        #expect(run.stderr.contains("--headless and --no-headless"), "\(run.stderr)")
        #expect(agent.argv == nil)
    }

    // MARK: - An explicit --endpoint is a host somewhere else

    @Test("-p with --endpoint drives that host, and hands nothing off")
    func promptWithAnEndpointIsDriven() throws {
        let agent = try FakeAgent()
        defer { agent.remove() }
        var environment = agent.environment
        environment["ALOHAJET_AGENT_TOKEN"] = "test-token"
        let run = try runCLI(["-p", "hi", "--endpoint", "http://127.0.0.1:1", "--json"],
                             environment: environment, timeout: 60)
        #expect(run.status == 1, "\(run.combined)")
        #expect(run.stdout.contains("transport error"), "\(run.stdout)")
        #expect(agent.argv == nil, "the turn was handed to alohajet-agent")
    }

    @Test("mcp-stdio with --endpoint relays, and hands nothing off")
    func mcpStdioWithAnEndpointRelays() throws {
        let agent = try FakeAgent()
        defer { agent.remove() }
        var environment = agent.environment
        environment["ALOHAJET_AGENT_TOKEN"] = "test-token"
        let run = try runCLI(["mcp-stdio", "--endpoint", "http://127.0.0.1:1"],
                             stdin: #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"# + "\n",
                             environment: environment, timeout: 60)
        #expect(run.status == 3, "\(run.combined)")
        #expect(run.stderr.contains("relay to http://127.0.0.1:1"), "\(run.stderr)")
        #expect(agent.argv == nil)
    }

    // MARK: - What the help says

    @Test("the help says where -p and mcp-stdio go on this platform")
    func helpNamesTheAgentHost() throws {
        let usage = try runCLI(["--help"])
        #expect(usage.status == 0)
        for phrase in ["alohajet-agent", "--accept-terms", "--no-headless", "ALOHAJET_AGENT_BIN"] {
            #expect(usage.stdout.contains(phrase), "--help does not mention \(phrase)")
        }
        #expect(!usage.stdout.contains("launched if needed"))
        #expect(!usage.stdout.contains("ALOHA_BROWSER_APP"))

        let relay = try runCLI(["mcp-stdio", "--help"])
        #expect(relay.status == 0)
        #expect(relay.stdout.contains("alohajet-agent mcp"), "\(relay.stdout)")
        #expect(!relay.stdout.contains("--accept-terms"), "\(relay.stdout)")
        #expect(relay.stdout.contains("mcp --endpoint"), "\(relay.stdout)")
    }
}

/// A stand-in `alohajet-agent`: records its argv (NUL-separated), stdin, signal state and
/// one environment variable into the directory it lives in, prints one line on each
/// stream and exits `$FAKE_AGENT_EXIT`. The record is read through builtins only, so no
/// child's wait can change the mask being read.
private struct FakeAgent {
    let directory: URL
    private let ownsDirectory: Bool

    var path: String { directory.appendingPathComponent("alohajet-agent").path }
    var environment: [String: String] { ["ALOHAJET_AGENT_BIN": path] }

    init(in directory: URL? = nil) throws {
        if let directory {
            self.directory = directory
            ownsDirectory = false
        } else {
            self.directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("alohajet-fake-agent-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
            ownsDirectory = true
        }
        let record = self.directory.path
        let script = """
            #!/bin/sh
            : > '\(record)/argv'
            for argument in "$@"; do printf '%s\\0' "$argument" >> '\(record)/argv'; done
            while IFS= read -r line; do
              case $line in SigBlk*|SigIgn*) printf '%s\\n' "$line";; esac
            done < /proc/$$/status > '\(record)/signals'
            printf '%s' "$FAKE_AGENT_PROBE" > '\(record)/probe'
            cat > '\(record)/stdin'
            echo "agent stdout"
            echo "agent stderr" >&2
            exit "${FAKE_AGENT_EXIT:-0}"

            """
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    private func read(_ name: String) -> String? {
        try? String(contentsOfFile: directory.appendingPathComponent(name).path, encoding: .utf8)
    }

    var argv: [String]? {
        read("argv").map { $0.split(separator: "\0", omittingEmptySubsequences: false).dropLast().map(String.init) }
    }
    var stdin: String? { read("stdin") }
    var probe: String? { read("probe") }

    func signalMask(_ field: String) -> UInt64? {
        guard let line = read("signals")?.split(separator: "\n").first(where: { $0.hasPrefix(field + ":") })
        else { return nil }
        return UInt64(line.dropFirst(field.count + 1).trimmingCharacters(in: .whitespaces), radix: 16)
    }

    func remove() {
        if ownsDirectory { try? FileManager.default.removeItem(at: directory) }
    }
}

/// A scratch tree for the cases that need the CLI somewhere other than the build: a copy
/// of the binary under test, alone or with a stand-in agent beside it.
private struct Sandbox {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("alohajet-handoff-\(UUID().uuidString)")

    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func directory(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func copyOfTheCLI(into directory: URL) throws -> String {
        let binary = try #require(alohajetBinary)
        let copy = directory.appendingPathComponent("alohajet").path
        try FileManager.default.copyItem(atPath: binary, toPath: copy)
        return copy
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
#endif
