import Foundation
import Testing

// The MCP stdio server, driven the way a host drives it: line-delimited JSON-RPC on the
// child's stdin, one JSON object per line back on its stdout.
//
// No browser is involved. `--cdp 1` names a port that is privileged and unbound, so the
// connection the server opens on the FIRST `tools/call` is refused immediately and the
// call comes back as a tool-level error — which is the contract worth pinning anyway: a
// browser that cannot be reached is an `isError` RESULT the model can read, never a
// JSON-RPC error and never a dead process. Everything before that first call —
// initialize, tools/list, ping, and every malformed-input case — never touches a browser
// at all.

/// One JSON-RPC exchange: the lines written to the server, and the objects it wrote back.
private struct MCPRun {
    var responses: [[String: Any]]
    var raw: String
    var status: Int32

    func response(id: Int) -> [String: Any]? {
        responses.first { ($0["id"] as? Int) == id }
    }
    func result(id: Int) -> [String: Any]? {
        response(id: id)?["result"] as? [String: Any]
    }
    func errorCode(id: Int) -> Int? {
        ((response(id: id)?["error"] as? [String: Any])?["code"] as? Int)
    }
}

/// Sends `requests` (already-encoded JSON-RPC lines) and decodes stdout.
private func mcp(_ requests: [String], extraArguments: [String] = ["--cdp", "1"]) throws -> MCPRun {
    let run = try runCLI(extraArguments + ["mcp"], stdin: requests.joined(separator: "\n") + "\n", timeout: 90)
    var responses: [[String: Any]] = []
    for line in run.stdout.split(separator: "\n", omittingEmptySubsequences: true) {
        guard let data = line.data(using: .utf8) else { continue }
        // THE ONE RULE OF THE TRANSPORT: stdout carries protocol traffic and nothing
        // else. A line that is not a JSON object is a diagnostic that escaped to the
        // wrong stream, and it breaks every host.
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Issue.record("non-JSON line on stdout: \(line)")
            continue
        }
        #expect(object["jsonrpc"] as? String == "2.0")
        responses.append(object)
    }
    return MCPRun(responses: responses, raw: run.stdout, status: run.status)
}

@Suite("MCP protocol", .serialized)
struct MCPProtocolTests {

    // MARK: - Handshake

    @Test func initializeEchoesASupportedProtocolVersion() throws {
        let run = try mcp([
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}"#
        ])
        let result = try #require(run.result(id: 1))
        #expect(result["protocolVersion"] as? String == "2024-11-05")
        let serverInfo = try #require(result["serverInfo"] as? [String: Any])
        #expect(serverInfo["name"] as? String == "alohajet")
        #expect((serverInfo["version"] as? String)?.isEmpty == false)
        // `tools` must be present (even empty) or a host will not call tools/list.
        let capabilities = try #require(result["capabilities"] as? [String: Any])
        #expect(capabilities["tools"] != nil)
        #expect(run.status == 0)
    }

    /// A client asking for a revision this server does not speak gets the newest one it
    /// does, which is what the spec asks of a server that cannot meet the request.
    @Test func initializeWithAnUnknownVersionAnswersWithTheNewestKnown() throws {
        let run = try mcp([
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#
        ])
        let version = try #require(run.result(id: 1)?["protocolVersion"] as? String)
        #expect(version != "1999-01-01")
        #expect(version.hasPrefix("20"))
    }

    @Test func pingIsAnsweredWithAnEmptyResult() throws {
        let run = try mcp([#"{"jsonrpc":"2.0","id":7,"method":"ping"}"#])
        let result = try #require(run.result(id: 7))
        #expect(result.isEmpty)
    }

    /// A notification has no `id`, and the spec forbids answering it. `initialized` is the
    /// one every host sends immediately after the handshake, so answering it would break
    /// the very first exchange of every session.
    @Test func notificationsAreNeverAnswered() throws {
        let run = try mcp([
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1}}"#,
            #"{"jsonrpc":"2.0","method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":9,"method":"ping"}"#,
        ])
        #expect(run.responses.count == 1, "answered a notification: \(run.raw)")
        #expect(run.response(id: 9) != nil)
    }

    // MARK: - tools/list

    @Test func toolsListIsTheNinePageToolsWithSchemasAndAnnotations() throws {
        let run = try mcp([#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#])
        let tools = try #require(run.result(id: 2)?["tools"] as? [[String: Any]])
        let names = tools.compactMap { $0["name"] as? String }
        #expect(names.sorted() == [
            "get_text", "manage_tabs", "page_click", "page_navigate",
            "page_press_keys", "page_select", "page_type", "page_upload", "page_wait_for",
        ])
        for tool in tools {
            let name = tool["name"] as? String ?? "?"
            #expect((tool["description"] as? String)?.isEmpty == false, "\(name) has no description")
            let schema = try #require(tool["inputSchema"] as? [String: Any], "\(name) has no inputSchema")
            #expect(schema["type"] as? String == "object", "\(name) inputSchema is not an object schema")
            #expect(schema["properties"] != nil, "\(name) inputSchema has no properties")
            let annotations = try #require(tool["annotations"] as? [String: Any], "\(name) has no annotations")
            let readOnly = try #require(annotations["readOnlyHint"] as? Bool, "\(name) has no readOnlyHint")
            // Anything that drives a live page can submit, delete or pay, so the two
            // hints are each other's negation. A tool claiming both would be lying once.
            #expect(annotations["destructiveHint"] as? Bool == !readOnly, "\(name) hints disagree")
            #expect(annotations["openWorldHint"] as? Bool == true, "\(name) is not open-world")
        }
        // The two pure readers. `manage_tabs` is NOT one of them even though its `list`
        // and `read` actions only observe: the hint is per TOOL, and the same tool opens
        // and closes tabs.
        let readOnly = tools.filter { (($0["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool) == true }
        #expect(readOnly.compactMap { $0["name"] as? String }.sorted() == ["get_text", "page_wait_for"])
    }

    /// Listing tools must not build a browser. A host that starts this server at boot and
    /// only ever enumerates it should never pay for a Chromium — and must exit 0 at EOF.
    @Test func listingToolsLaunchesNoBrowserAndExitsCleanly() throws {
        let run = try mcp([#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#], extraArguments: [])
        #expect(run.result(id: 2) != nil)
        #expect(run.status == 0)
    }

    // MARK: - Error codes

    @Test func malformedJsonIsAParseError() throws {
        let run = try mcp(["{not json"])
        let response = try #require(run.responses.first)
        #expect((response["error"] as? [String: Any])?["code"] as? Int == -32700)
        #expect(response["id"] is NSNull)
    }

    /// MCP removed JSON-RPC batching in 2025-06-18. A batch is refused plainly rather
    /// than half-implemented.
    @Test func aBatchArrayIsAnInvalidRequest() throws {
        let run = try mcp([#"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#])
        let response = try #require(run.responses.first)
        #expect((response["error"] as? [String: Any])?["code"] as? Int == -32600)
    }

    @Test func aRequestWithNoMethodIsAnInvalidRequest() throws {
        let run = try mcp([#"{"jsonrpc":"2.0","id":3}"#])
        #expect(run.errorCode(id: 3) == -32600)
    }

    @Test func anUnknownMethodIsMethodNotFound() throws {
        let run = try mcp([#"{"jsonrpc":"2.0","id":4,"method":"resources/list"}"#])
        #expect(run.errorCode(id: 4) == -32601)
        let message = try #require((run.response(id: 4)?["error"] as? [String: Any])?["message"] as? String)
        #expect(message.contains("resources/list"), "the error does not name the method")
    }

    @Test func aToolCallWithNoNameIsInvalidParams() throws {
        let run = try mcp([#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"arguments":{}}}"#])
        #expect(run.errorCode(id: 5) == -32602)
    }

    // MARK: - tools/call

    /// The line between a PROTOCOL error and a TOOL error. An unreachable browser and an
    /// unknown tool name are both things the model can act on, so both come back as a
    /// normal result carrying `isError: true` — never as a JSON-RPC error, which the
    /// model never sees.
    @Test func anUnreachableBrowserIsAToolErrorNotAProtocolError() throws {
        let run = try mcp([
            #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"manage_tabs","arguments":{"action":"list"}}}"#
        ])
        #expect(run.errorCode(id: 6) == nil, "an unreachable browser was reported as a protocol error")
        let result = try #require(run.result(id: 6))
        #expect(result["isError"] as? Bool == true)
        let content = try #require(result["content"] as? [[String: Any]])
        #expect(content.first?["type"] as? String == "text")
        let text = try #require(content.first?["text"] as? String)
        #expect(text.contains("browser"), "the failure does not say what went wrong: \(text)")
        // A failed connection is latched, so a second call must answer just as fast and
        // must not re-run the timeout.
        #expect(run.status == 0)
    }

    @Test func anUnknownToolNameIsAToolErrorNotAProtocolError() throws {
        let run = try mcp([
            #"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"rm_rf","arguments":{}}}"#
        ])
        #expect(run.errorCode(id: 8) == nil)
        #expect(run.result(id: 8)?["isError"] as? Bool == true)
    }

    // MARK: - The lane selector reaches the MCP server too

    // `--browser` used to be read only by the CLI's own parser. `alohajet mcp --browser
    // aloha` therefore parsed clean and quietly launched a THROWAWAY HEADLESS CHROMIUM:
    // the host believed it was driving the user's browser, the model answered about tabs
    // nobody could see, and nothing anywhere said so. These two cases are the ones that
    // are settled before a browser is contacted, so they are safe to run — nothing here
    // may probe 9222 or open the developer's real browser.

    @Test func mcpRejectsAnUnknownBrowserRatherThanLaunchingOne() throws {
        let run = try mcp([
            #"{"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"manage_tabs","arguments":{"action":"list"}}}"#
        ], extraArguments: ["--browser", "frotz"])
        #expect(run.errorCode(id: 12) == nil)
        let result = try #require(run.result(id: 12))
        #expect(result["isError"] as? Bool == true)
        let text = try #require((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        #expect(text.contains("--browser expects chromium or aloha"),
                "the MCP server swallowed the flag instead of reporting it: \(text)")
    }

    @Test func mcpRefusesAlohaAndCdpTogether() throws {
        let run = try mcp([
            #"{"jsonrpc":"2.0","id":13,"method":"tools/call","params":{"name":"manage_tabs","arguments":{"action":"list"}}}"#
        ], extraArguments: ["--browser", "aloha", "--cdp", "9222"])
        let result = try #require(run.result(id: 13))
        #expect(result["isError"] as? Bool == true)
        let text = try #require((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        #expect(text.contains("two different browsers"), "\(text)")
    }

    @Test func mcpLaunchesTheBrowserTheEnvironmentNames() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("alohajet-mcp-browser-env-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let marker = sandbox.appendingPathComponent("argv")
        let wrapper = sandbox.appendingPathComponent("chrome")
        try "#!/bin/sh\necho \"$@\" > '\(marker.path)'\nexit 0\n"
            .write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)

        let run = try runCLI(
            ["mcp"],
            stdin: #"{"jsonrpc":"2.0","id":14,"method":"tools/call","params":{"name":"manage_tabs","arguments":{"action":"list"}}}"# + "\n",
            environment: ["ALOHAJET_BROWSER": wrapper.path],
            timeout: 90)
        #expect(FileManager.default.fileExists(atPath: marker.path),
                "mcp launched a browser other than ALOHAJET_BROWSER: \(run.combined)")
        #expect(run.stdout.contains("Could not reach a browser"), "\(run.combined)")
    }

    /// Blank lines are ignored, not answered — a host that flushes an extra newline must
    /// not receive a parse error for it.
    @Test func blankLinesAreIgnored() throws {
        let run = try mcp(["", "   ", #"{"jsonrpc":"2.0","id":10,"method":"ping"}"#, ""])
        #expect(run.responses.count == 1)
        #expect(run.result(id: 10) != nil)
    }
}
