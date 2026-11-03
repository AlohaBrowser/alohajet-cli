#if os(Linux) || os(macOS)
import Foundation
import Testing

// A bare `alohajet mcp` is alohajet-agent's MCP server whenever one is installed beside
// alohajet, and the CLI's own server otherwise. Driven as a process against a stand-in agent
// that records what it was handed, so what is pinned is what an MCP host actually sees.

@Suite("a bare mcp hands its session to alohajet-agent", .serialized)
struct MCPAgentHandoffTests {

    static let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#
        + "\n"

    @Test("mcp becomes alohajet-agent mcp, and the client's stdin is the agent's", arguments: [
        (["mcp"], ["mcp"]),
        (["mcp", "--no-headless"], ["mcp", "--no-headless"]),
        (["mcp", "--headless"], ["mcp"]),
        (["--browser", "chromium", "mcp"], ["mcp"]),
    ])
    func bareMCPBecomesTheAgent(_ arguments: [String], _ expected: [String]) throws {
        let agent = try StandInAgent()
        defer { agent.remove() }
        let frames = Self.initialize + #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"# + "\n"
        var environment = agent.environment
        environment["STAND_IN_EXIT"] = "5"
        let run = try runCLI(arguments, stdin: frames, environment: environment)
        #expect(run.status == 5, "\(run.combined)")
        #expect(agent.argv == expected)
        #expect(agent.stdin == frames)
        #expect(run.stdout == "agent stdout\n")
        #expect(run.stderr == "agent stderr\n")
    }

    @Test("the agent a bare mcp becomes is the one beside the CLI's resolved path")
    func siblingOfTheResolvedExecutable() throws {
        let sandbox = try HandoffSandbox()
        defer { sandbox.remove() }
        let install = try sandbox.directory("install")
        let cli = try sandbox.copyOfTheCLI(into: install)
        let agent = try StandInAgent(in: install)
        let onPath = try sandbox.directory("bin")
        let decoy = try StandInAgent(in: onPath)
        let link = onPath.appendingPathComponent("alohajet").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: cli)

        let run = try runCLI(["mcp"], stdin: Self.initialize, environment: ["ALOHAJET_AGENT_BIN": ""], binary: link)
        #expect(run.status == 0, "\(run.combined)")
        #expect(agent.argv == ["mcp"])
        #expect(decoy.argv == nil, "the agent beside the symlink ran")
    }

    @Test("--browser-only, or a browser option, keeps the CLI's own server and runs no agent", arguments: [
        ["--browser-only"], ["--cdp", "1"], ["--launch"], ["--port", "9"], ["--browser", "aloha"],
    ])
    func browserOptionsKeepTheOwnServer(_ extra: [String]) throws {
        let agent = try StandInAgent()
        defer { agent.remove() }
        let run = try runCLI(["mcp"] + extra, stdin: Self.initialize, environment: agent.environment)
        #expect(run.status == 0, "\(run.combined)")
        #expect(agent.argv == nil, "the agent ran")
        #expect(try serverName(run.stdout) == "alohajet", "\(run.stdout)")
        #expect(run.stderr.isEmpty, "\(run.stderr)")
    }

    @Test("with no alohajet-agent, mcp serves the CLI's own tools and says once what they cannot do")
    func noAgentServesTheOwnTools() throws {
        let sandbox = try HandoffSandbox()
        defer { sandbox.remove() }
        let cli = try sandbox.copyOfTheCLI(into: try sandbox.directory("lonely"))
        let frames = Self.initialize + #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"# + "\n"

        let run = try runCLI(["mcp"], stdin: frames, environment: ["ALOHAJET_AGENT_BIN": ""], binary: cli)
        #expect(run.status == 0, "\(run.combined)")
        #expect(try serverName(run.stdout) == "alohajet", "\(run.stdout)")
        #expect(run.stdout.contains(#""name":"manage_tabs""#), "\(run.stdout)")
        let lines = run.stderr.split(separator: "\n")
        #expect(lines.count == 1, "\(run.stderr)")
        #expect(run.stderr.hasPrefix("alohajet mcp: "), "\(run.stderr)")
        #expect(run.stderr.contains("complete no verification check"), "\(run.stderr)")
        #expect(run.stderr.contains("--browser-only"), "\(run.stderr)")
        #if os(Linux)
        let expected = (cli as NSString).deletingLastPathComponent + "/alohajet-agent"
        #expect(run.stderr.contains(expected), "\(run.stderr)")
        #else
        #expect(run.stderr.contains("mcp --endpoint"), "\(run.stderr)")
        #endif

        let chosen = try runCLI(["mcp", "--browser-only"], stdin: frames, environment: ["ALOHAJET_AGENT_BIN": ""],
                                binary: cli)
        #expect(chosen.status == 0, "\(chosen.combined)")
        #expect(chosen.stderr.isEmpty, "--browser-only chose these tools, and is told nothing: \(chosen.stderr)")
    }

    @Test("an ALOHAJET_AGENT_BIN that names no agent stops mcp rather than serving something else", arguments: [
        "bin/alohajet-agent", "/nonexistent/alohajet-agent",
    ])
    func unusableOverrideStops(_ value: String) throws {
        let run = try runCLI(["mcp"], stdin: Self.initialize, environment: ["ALOHAJET_AGENT_BIN": value])
        #expect(run.status == 3, "\(run.combined)")
        #expect(run.stdout.isEmpty, "\(run.stdout)")
        #expect(run.stderr.contains("ALOHAJET_AGENT_BIN") && run.stderr.contains(value), "\(run.stderr)")
    }

    @Test("an alohajet-agent beside alohajet that is alohajet itself stops mcp")
    func agentThatIsThisCLIStops() throws {
        let sandbox = try HandoffSandbox()
        defer { sandbox.remove() }
        let install = try sandbox.directory("install")
        let cli = try sandbox.copyOfTheCLI(into: install)
        let sibling = install.appendingPathComponent("alohajet-agent").path
        try FileManager.default.createSymbolicLink(atPath: sibling, withDestinationPath: "alohajet")

        let run = try runCLI(["mcp"], stdin: Self.initialize, environment: ["ALOHAJET_AGENT_BIN": ""],
                             timeout: 10, binary: cli)
        #expect(run.status == 3, "\(run.combined)")
        #expect(run.stdout.isEmpty, "\(run.stdout)")
        #expect(run.stderr.contains(sibling) && run.stderr.contains("alohajet itself"), "\(run.stderr)")
    }

    @Test("what the agent would refuse is refused before it runs", arguments: [
        (["mcp", "--accept-terms"], "alohajet: an MCP session runs no turn and asks for no Terms of Service: drop --accept-terms\n"),
        (["mcp", "--headless", "--no-headless"], "alohajet: --headless and --no-headless: pass one\n"),
    ])
    func refusedBeforeTheAgentRuns(_ arguments: [String], _ message: String) throws {
        let agent = try StandInAgent()
        defer { agent.remove() }
        let run = try runCLI(arguments, stdin: Self.initialize, environment: agent.environment)
        #expect(run.status == 2, "\(run.combined)")
        #expect(run.stdout.isEmpty)
        #expect(run.stderr == message, "\(run.stderr)")
        #expect(agent.argv == nil, "the agent ran anyway")
    }

    @Test("mcp --help says when it is alohajet-agent, how to keep these tools, and what they cannot do")
    func helpNamesTheHandoff() throws {
        let help = try runCLI(["mcp", "--help"])
        #expect(help.status == 0)
        for phrase in ["alohajet-agent mcp", "ALOHAJET_AGENT_BIN", "--browser-only", "verification check"] {
            #expect(help.stdout.contains(phrase), "mcp --help does not mention \(phrase): \(help.stdout)")
        }
    }

    private func serverName(_ stdout: String) throws -> String? {
        let line = try #require(stdout.split(separator: "\n").first)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        return ((object["result"] as? [String: Any])?["serverInfo"] as? [String: Any])?["name"] as? String
    }
}

private struct StandInAgent {
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
                .appendingPathComponent("alohajet-stand-in-agent-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
            ownsDirectory = true
        }
        let record = self.directory.path
        let script = """
            #!/bin/sh
            : > '\(record)/argv'
            for argument in "$@"; do printf '%s\\0' "$argument" >> '\(record)/argv'; done
            cat > '\(record)/stdin'
            echo "agent stdout"
            echo "agent stderr" >&2
            exit "${STAND_IN_EXIT:-0}"

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

    func remove() {
        if ownsDirectory { try? FileManager.default.removeItem(at: directory) }
    }
}

private struct HandoffSandbox {
    let root: URL

    init() throws {
        let created = FileManager.default.temporaryDirectory
            .appendingPathComponent("alohajet-mcp-handoff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: created, withIntermediateDirectories: true)
        let resolved = try #require(realpath(created.path, nil))
        defer { free(resolved) }
        root = URL(fileURLWithPath: String(cString: resolved))
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
