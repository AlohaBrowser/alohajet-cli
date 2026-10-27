import Foundation
import Testing

// `alohajet mcp` is one verb over two products, and `--endpoint` is the whole selector:
//
//   alohajet mcp                    this package's MCP server, its own tools and Chromium
//   alohajet mcp --endpoint <url>   a PIPE onto the MCP server a running Aloha browser
//                                   already mounts at <url>/mcp — no tools, no browser
//   alohajet mcp-stdio              the legacy relay entry, defaulting to loopback:8765
//
// A loopback fixture exercises the real subprocess and SDK transports. Its responses
// are synthetic; these tests do not launch the desktop app or use a user's browser.
//
// `.serialized` for the same reason as every other suite here: each case blocks its
// thread in `waitUntilExit`.
@Suite("MCP relay lane", .serialized)
struct MCPRelayLaneTests {

    /// One tools/call, the request both lanes are driven with below.
    private static let toolsCall =
        #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"manage_tabs","arguments":{"action":"list"}}}"#
        + "\n"

    /// `--endpoint` never reaches a real one: a token is pinned so the developer's own
    /// `~/Library/Application Support/Aloha/automation-token` is neither read nor sent.
    private static let pinnedToken = ["ALOHAJET_AGENT_TOKEN": "test-token"]

    // MARK: - Saved desktop entries

    /// The default case executes EXACTLY the already-saved args, with a listener we
    /// own on the legacy port. The other cases pin endpoint override and modern relay
    /// parity. A marker executable catches even an attempted Chromium launch. Off macOS
    /// the saved args are alohajet-agent's (AgentHandoffProcessTests), not a relay.
    #if os(macOS)
    static let savedEntries = ["legacy-default", "legacy-explicit", "modern"]
    #else
    static let savedEntries = ["legacy-explicit", "modern"]
    #endif

    @Test("authenticated MCP frames relay without launching Chromium", arguments: savedEntries)
    func savedEntriesRelayFramesWithoutLaunchingChromium(_ mode: String) throws {
        let sandbox = try RelaySandbox()
        defer { sandbox.remove() }
        let stub = AgentStubServer(port: mode == "legacy-default" ? 8765 : 0,
                                   mcpToken: sandbox.token)
        try stub.start() // If 8765 is busy, fail before contacting its existing owner.
        defer { stub.stop() }
        let arguments = mode == "legacy-default" ? ["mcp-stdio"]
            : [mode == "modern" ? "mcp" : "mcp-stdio", "--endpoint", stub.url]
        let frames = [
            #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"relay-regression","version":"1"}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"fixture_tabs","arguments":{"action":"list"}}}"#,
        ]
        let run = try runCLI(arguments, stdin: frames.joined(separator: "\n") + "\n",
                             environment: sandbox.environment, timeout: 30)

        let chromiumWasLaunched = sandbox.chromiumWasLaunched
        #expect(!chromiumWasLaunched, "the relay attempted to launch Chromium")
        #expect(run.status == 0, "\(run.combined)")
        #expect(run.stderr.isEmpty, "\(run.stderr)")
        let replies = try run.stdout.split(separator: "\n").map {
            try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        #expect(replies.compactMap { $0["id"] as? Int } == [0, 2, 3])
        #expect(replies.allSatisfy { $0["jsonrpc"] as? String == "2.0" && $0["error"] == nil })
        let initialized = try #require(replies.first?["result"] as? [String: Any])
        #expect((initialized["serverInfo"] as? [String: Any])?["name"] as? String == "relay-fixture")
        let listed = try #require(replies.first { $0["id"] as? Int == 2 }?["result"] as? [String: Any])
        #expect((listed["tools"] as? [[String: Any]])?.first?["name"] as? String == "fixture_tabs")
        let called = try #require(replies.first { $0["id"] as? Int == 3 }?["result"] as? [String: Any])
        #expect(called["isError"] as? Bool == false)
        #expect((called["content"] as? [[String: Any]])?.first?["text"] as? String == "fixture tab list")

        let requests = stub.requests
        try #require(requests.count == frames.count)
        #expect(requests.allSatisfy { $0.method == "POST" && $0.path == "/mcp" })
        // Assert only the comparison result so a failed test cannot print credentials.
        let authenticated = requests.allSatisfy { $0.authorization == "Bearer \(sandbox.token)" }
        #expect(authenticated)
        #expect(requests.allSatisfy { $0.contentType?.contains("application/json") == true })
        #expect(requests.allSatisfy {
            $0.accept?.contains("application/json") == true && $0.accept?.contains("text/event-stream") == true
        })
        #expect(requests.first?.mcpSession == nil)
        #expect(requests.dropFirst().allSatisfy { $0.mcpSession == AgentStubServer.mcpSession })
        #expect(requests.allSatisfy { $0.mcpProtocol?.isEmpty == false })
        for (request, frame) in zip(requests, frames) {
            let sent = try JSONSerialization.jsonObject(with: Data(request.body.utf8)) as? NSDictionary
            let expected = try JSONSerialization.jsonObject(with: Data(frame.utf8)) as? NSDictionary
            #expect(sent == expected, "a relay request changed the client's frame")
        }
    }

    @Test("an unauthorized relay never falls back to standalone MCP", arguments: ["mcp", "mcp-stdio"])
    func authenticationFailureDoesNotServeStandaloneTools(_ command: String) throws {
        let sandbox = try RelaySandbox()
        defer { sandbox.remove() }
        let stub = AgentStubServer(mcpToken: sandbox.token)
        try stub.start()
        defer { stub.stop() }
        var environment = sandbox.environment
        environment["ALOHAJET_AGENT_TOKEN"] = "incorrect-fixture-credential"
        let run = try runCLI([command, "--endpoint", stub.url], stdin: Self.toolsCall,
                             environment: environment)
        #expect(run.status == 3, "\(run.combined)")
        #expect(run.stdout.isEmpty, "the relay answered with its own tools")
        #expect(run.stderr.contains("Authentication required"), "\(run.stderr)")
        #expect(stub.requests.count == 1)
        let chromiumWasLaunched = sandbox.chromiumWasLaunched
        #expect(!chromiumWasLaunched)
    }

    #if os(macOS)
    @Test func legacyHelpDocumentsTheDefaultAndCompatibilityScope() throws {
        for flag in ["--help", "-h"] {
            let run = try runCLI(["mcp-stdio", flag])
            #expect(run.status == 0)
            #expect(run.stderr.isEmpty)
            #expect(run.stdout.contains("http://127.0.0.1:8765"))
            #expect(run.stdout.contains("mcp --endpoint"))
            #expect(run.stdout.contains("running"))
        }
        let usage = try runCLI(["--help"])
        #expect(usage.stdout.contains("mcp-stdio"))
    }
    #endif

    // MARK: - The flag picks the lane

    /// THE DIFFERENTIAL, and the one assertion that proves the relay builds no
    /// `BrowserToolSession`: the same request, the same browser flag, one lane apart.
    ///
    /// Without `--endpoint`, `--cdp 1` names a port that is privileged and unbound, so
    /// the server lane opens a connection, is refused, and answers the model with an
    /// `isError` result naming the browser (pinned in `MCPProtocolTests`). With
    /// `--endpoint`, that same `--cdp 1` is never acted on at all: no browser is
    /// contacted, no tool runs in this process, and stdout stays EMPTY — the only thing
    /// that can ever appear on it is a frame the upstream server sent back.
    @Test func theRelayServesNothingItselfAndContactsNoBrowser() throws {
        let relay = try runCLI(
            ["--cdp", "1", "mcp", "--endpoint", "http://127.0.0.1:1"],
            stdin: Self.toolsCall, environment: Self.pinnedToken, timeout: 60)

        #expect(relay.stdout.isEmpty, "the relay answered MCP itself: \(relay.stdout)")
        #expect(!relay.combined.contains("Could not reach a browser"),
                "the relay built a browser session: \(relay.combined)")
        // Port 1 refuses instantly, and the refusal is not recoverable from a pipe: it
        // ends the run under the same exit code an unreachable browser uses.
        #expect(relay.status == 3, "\(relay.combined)")
        #expect(relay.stderr.contains("127.0.0.1:1"), "the failure does not name the endpoint")
    }

    /// The other half of that differential, stated here rather than assumed: with no
    /// `--endpoint` the identical invocation IS this package's server, answering over its
    /// own tools.
    @Test func withoutTheFlagTheServerLaneAnswersAsBefore() throws {
        let server = try runCLI(
            ["--cdp", "1", "mcp"],
            stdin: Self.toolsCall, environment: Self.pinnedToken, timeout: 90)

        #expect(server.stdout.contains("\"id\":1"), "the server lane answered nothing: \(server.combined)")
        #expect(server.stdout.contains("Could not reach a browser"),
                "the server lane did not try to build one: \(server.stdout)")
        #expect(server.status == 0)
    }

    /// `--endpoint=` with nothing after it has still ASKED for the relay, and answering
    /// it by falling through to a launched Chromium is the failure mode this lane exists
    /// to avoid: the host believes it is driving the user's browser and nothing says
    /// otherwise. It is a usage error, and it names the flag.
    @Test(arguments: ["mcp", "mcp-stdio"])
    func anEmptyEndpointIsAUsageErrorRatherThanTheOtherLane(_ command: String) throws {
        let run = try runCLI([command, "--endpoint="], environment: Self.pinnedToken)
        #expect(run.status == 2)
        #expect(run.stderr.contains("--endpoint"), "\(run.combined)")
        #expect(run.stdout.isEmpty, "a usage error reached the protocol channel: \(run.stdout)")
    }

    // MARK: - Where the endpoint may point

    /// Plaintext to somewhere that is not this machine is refused at parse time, not
    /// downgraded to an unauthenticated attempt: every frame on this pipe drives the
    /// user's browser, and the bearer token that authorizes it grants the whole
    /// automation API. `127.0.0.1.evil.example` is the case a prefix match gets wrong —
    /// it is a remote name that resolves wherever its owner points it.
    ///
    /// The token rule underneath (ambient file to loopback only, remote served by
    /// `ALOHAJET_AGENT_TOKEN` alone) is `AutomationToken.read(for:)`'s and is pinned in
    /// `AutomationTokenTests`; this relay adds no second credential path.
    @Test("a non-loopback plaintext endpoint is refused", arguments: [
        "http://example.com",
        "http://127.0.0.1.evil.example:8765",
        "http://10.0.0.5:8765",
    ], ["mcp", "mcp-stdio"])
    func nonLoopbackPlaintextIsRefused(_ endpoint: String, _ command: String) throws {
        let run = try runCLI([command, "--endpoint", endpoint], environment: Self.pinnedToken)
        #expect(run.status == 2, "\(endpoint) was not refused: \(run.combined)")
        #expect(run.stderr.contains("loopback"), "\(run.combined)")
        #expect(run.stdout.isEmpty)
    }

    /// `URL(string: "localhost:8765")` parses happily with `localhost` as the SCHEME, so
    /// a missing `http://` must be caught here — otherwise the request fails somewhere
    /// far from the typo that caused it.
    @Test("an endpoint that is not an http(s) URL is a usage error", arguments: [
        "localhost:8765", "127.0.0.1:8765", "ws://127.0.0.1:8765", "not a url",
    ], ["mcp", "mcp-stdio"])
    func aMalformedEndpointIsAUsageError(_ endpoint: String, _ command: String) throws {
        let run = try runCLI([command, "--endpoint", endpoint], environment: Self.pinnedToken)
        #expect(run.status == 2, "\(endpoint) was accepted: \(run.combined)")
        #expect(run.stderr.contains("http(s) URL"), "\(run.combined)")
    }

    /// The counterpart to the refusals above, stated rather than assumed: https to a host
    /// that is NOT this machine is ALLOWED — it is the port-forward and second-machine
    /// case the flag exists for, and TLS covers the wire. `.invalid` is reserved by
    /// RFC 2606, so this reaches DNS and nothing else: the endpoint is accepted (the run
    /// gets as far as the transport and fails there, 3) rather than refused as usage (2).
    @Test(arguments: ["mcp", "mcp-stdio"])
    func aRemoteHttpsEndpointIsAllowed(_ command: String) throws {
        let run = try runCLI(
            [command, "--endpoint", "https://alohajet-no-such-host.invalid:8765"],
            stdin: Self.toolsCall, environment: Self.pinnedToken, timeout: 60)
        #expect(run.status == 3, "exited \(run.status): \(run.combined)")
        #expect(!run.stderr.contains("loopback"), "\(run.combined)")
    }

    /// The ambient token on disk is the browser's and never leaves this machine
    /// (`AutomationTokenTests` pins the reader). An endpoint somewhere else therefore
    /// gets no credential at all unless one was named, and a bare 401 reads as a broken
    /// token rather than as the rule it is — so the rule is stated once, on stderr,
    /// which is the only stream the JSON-RPC channel is not.
    @Test(arguments: ["mcp", "mcp-stdio"])
    func aRemoteEndpointWithNoNamedTokenSaysSo(_ command: String) throws {
        let run = try runCLI(
            [command, "--endpoint", "https://alohajet-no-such-host.invalid:8765"],
            stdin: Self.toolsCall, environment: ["ALOHAJET_AGENT_TOKEN": ""], timeout: 60)
        #expect(run.stderr.contains("ALOHAJET_AGENT_TOKEN"), "\(run.combined)")
        #expect(run.stdout.isEmpty, "a note reached the protocol channel: \(run.stdout)")
    }

    /// A tool call the browser takes minutes over is a normal tool call — a page that is
    /// slow to wake, a navigation that hangs — and the client's own deadline is the one
    /// that should end it. Under `URLSessionConfiguration.default`'s 60 s idle timer the
    /// relay instead dropped the WHOLE session, discarding work that had completed.
    @Test func aCallSlowerThanTheDefaultTimeoutDoesNotEndTheSession() throws {
        let stub = AgentStubServer(hold: 62)
        try stub.start()
        defer { stub.stop() }

        let run = try runCLI(
            ["mcp", "--endpoint", stub.url],
            stdin: Self.toolsCall, environment: Self.pinnedToken, timeout: 180)

        #expect(run.status == 0, "exited \(run.status): \(run.combined)")
        #expect(!run.stderr.contains("timed out"), "\(run.combined)")
    }

    /// The relay is the only reason a Claude Desktop user has a working entry at all, so
    /// its shape has to be discoverable from the CLI itself.
    @Test func theHelpPageDocumentsBothLanes() throws {
        let run = try runCLI(["mcp", "--help"])
        #expect(run.status == 0)
        #expect(run.stdout.contains("--endpoint"))
        #expect(run.stdout.contains("Claude Desktop"))
        #expect(run.stdout.contains("https"))
    }
}

/// A private home/token/browser marker for real relay subprocesses. No app or Chrome
/// can be launched even if the regression sends the legacy verb into `connect`.
private struct RelaySandbox {
    let root: URL
    let token = UUID().uuidString
    var environment: [String: String] {
        ["HOME": root.path, "CFFIXED_USER_HOME": root.path, "TMPDIR": root.path,
         "ALOHAJET_AGENT_TOKEN": token, "ALOHAJET_BROWSER": root.appendingPathComponent("chrome").path]
    }
    var chromiumWasLaunched: Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent("chromium-launched").path)
    }
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("alohajet-relay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let browser = root.appendingPathComponent("chrome")
        try "#!/bin/sh\n: > \"$TMPDIR/chromium-launched\"\nexit 0\n"
            .write(to: browser, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: browser.path)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
