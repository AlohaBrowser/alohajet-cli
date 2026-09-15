import Foundation
import BrowserTools
import ToolABI

// MARK: - MCP stdio server
//
// Model Context Protocol over stdio: line-delimited JSON-RPC 2.0 on stdin/stdout,
// hand-rolled over `JSValue` (which already parses and serializes JSON, order
// preserving) so the package keeps its zero dependencies.
//
// THE ONE RULE OF THIS FILE: stdout carries protocol traffic and nothing else. Every
// diagnostic goes to stderr. The library's logging shim already writes to stderr and
// `ChromeLauncher` sends the launched browser's stdout to /dev/null, so the only way to
// break the transport from here is to `print()`. Don't.

enum MCPServer {
    static let serverName = "alohajet"
    static let serverVersion = alohajetVersion

    /// The protocol revisions this server speaks. An `initialize` naming one of them is
    /// answered in kind; anything else is answered with the newest we know, which is what
    /// the spec asks of a server that cannot meet the client's request.
    static let supportedProtocolVersions: Set<String> = ["2024-11-05", "2025-03-26", "2025-06-18"]
    static let latestProtocolVersion = "2025-06-18"

    /// Serve MCP over stdin/stdout until EOF. Returns the process exit code.
    ///
    /// `arguments` is argv after the `mcp` subcommand; connection flags may also precede
    /// it (`alohajet --cdp 9222 mcp`), so the full argv is what gets scanned.
    static func main(_ arguments: [String]) async -> Int32 {
        let connection = MCPConnection(arguments + Array(CommandLine.arguments.dropFirst()))

        // The browser is built on the FIRST tools/call, not at startup: a host that
        // launches this server at boot and only ever lists tools must not pay for a
        // Chromium, and a launch failure is worth reporting to the model in a tool result
        // rather than by dying before the handshake.
        var session: BrowserToolSession?
        var sessionFailure: String?

        // A host that closes the pipe must end this loop at EOF, not kill us mid-write.
        signal(SIGPIPE, SIG_IGN)

        for await line in stdinLines() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            guard let message = JSValue.parse(trimmed) else {
                write(errorResponse(id: .null, code: -32700, message: "Parse error: not valid JSON"))
                continue
            }
            guard case .object = message else {
                // JSON-RPC 2.0 allows a batch array; MCP removed batching in 2025-06-18.
                // Refuse it plainly rather than half-implement it.
                write(errorResponse(id: .null, code: -32600,
                                    message: "Invalid Request: expected a single JSON-RPC object"))
                continue
            }

            let id = message["id"]      // absent => a notification, which is never answered
            let params = message["params"]
            guard let method = message.string("method") else {
                if let id {
                    write(errorResponse(id: id, code: -32600, message: "Invalid Request: no method"))
                }
                continue
            }

            switch method {
            case "initialize":
                let requested = params?.string("protocolVersion")
                let version = requested.flatMap { supportedProtocolVersions.contains($0) ? $0 : nil }
                    ?? latestProtocolVersion
                respond(id: id, result: .object([
                    ("protocolVersion", .string(version)),
                    ("capabilities", .object([("tools", .object([]))])),
                    ("serverInfo", .object([
                        ("name", .string(serverName)),
                        ("version", .string(serverVersion))
                    ]))
                ]))

            case "notifications/initialized", "notifications/cancelled":
                continue

            case "ping":
                respond(id: id, result: .object([]))

            case "tools/list":
                respond(id: id, result: .object([("tools", .array(toolDescriptors()))]))

            case "tools/call":
                guard let id else { continue }  // a call with no id has nowhere to answer
                guard let name = params?.string("name") else {
                    write(errorResponse(id: id, code: -32602, message: "Invalid params: \"name\" is required"))
                    continue
                }
                if session == nil, sessionFailure == nil {
                    do {
                        session = try await connection.open()
                        // A host that kills the server instead of closing stdin must not
                        // leave the browser behind. No-op for an attached one.
                        session?.installSignalReaper()
                    } catch {
                        // Latched: retrying a connection that already failed once, on
                        // every tool call, only multiplies the timeout.
                        let detail = (error as? BrowserToolSessionError)?.description ?? "\(error)"
                        sessionFailure = "Could not reach a browser: \(detail)"
                        log(sessionFailure!)
                    }
                }
                if let sessionFailure {
                    write(callResult(text: sessionFailure, isError: true, id: id))
                    continue
                }
                // A tool that fails is not a protocol failure: it comes back as a normal
                // result carrying `isError`, which is what the model has to read. `run`
                // never throws, and an unknown tool name is one of those error results.
                let result = await session!.run(name, params?["arguments"].map(workflowValue))
                write(callResult(
                    text: result.output, isError: result.isError == true, id: id,
                    images: result.images))

            default:
                if let id {
                    write(errorResponse(id: id, code: -32601, message: "Method not found: \(method)"))
                }
            }
        }

        // EOF on stdin is the host hanging up: close a browser we launched and leave.
        await session?.shutdown()
        return 0
    }

    // MARK: - tools/list

    /// The eight tools, with name, description and `inputSchema` taken verbatim from the
    /// package's own registry — `Schemas.swift` is the single source of truth and nothing
    /// is re-authored here. Its `inputSchema` is already JSON Schema in `JSValue` form, so
    /// the adapter this was budgeted for turned out to be the identity function.
    static func toolDescriptors() -> [JSValue] {
        getNativeAgentToolSchemas().map { schema in
            var members: [(String, JSValue)] = [("name", .string(schema.name))]
            if let description = schema.description {
                members.append(("description", .string(description)))
            }
            // MCP requires `inputSchema`; an object schema with no properties is the
            // stand-in for a registry entry that carries none.
            members.append(("inputSchema", schema.inputSchema ?? .object([
                ("type", .string("object")), ("properties", .object([]))
            ])))

            // `readOnlyHint` comes from the package's hand-written table. It is per TOOL,
            // not per call, so `manage_tabs` is false even though its `list` and `read`
            // actions only observe — the same tool also opens and closes tabs. Everything
            // not read-only drives a live page, where a click can submit, delete or pay,
            // so `destructiveHint` is the honest answer for all six. `openWorldHint` is
            // true throughout: the subject is the open web.
            let readOnly = nativeAgentToolReadOnlyHints[schema.name] ?? false
            members.append(("annotations", .object([
                ("readOnlyHint", .bool(readOnly)),
                ("destructiveHint", .bool(!readOnly)),
                ("openWorldHint", .bool(true))
            ])))
            return .object(members)
        }
    }

    // MARK: - JSON-RPC framing

    static func respond(id: JSValue?, result: JSValue) {
        guard let id else { return }  // a notification: the spec forbids a reply
        write(.object([("jsonrpc", .string("2.0")), ("id", id), ("result", result)]))
    }

    /// One text block, then one MCP `image` block per screenshot the tool captured.
    ///
    /// `include_screenshot: true` used to cost a `Page.captureScreenshot` round-trip and
    /// return nothing: the pixels reached `RawToolResult.images` and stopped there,
    /// because this function only ever wrote the text. A schema that advertises a
    /// capability the transport drops is worse than one that never offered it.
    static func callResult(
        text: String, isError: Bool, id: JSValue, images: [ParsedDataUrlImage] = []
    ) -> JSValue {
        var content: [JSValue] = [.object([("type", .string("text")), ("text", .string(text))])]
        content.append(contentsOf: images.map { image in
            .object([
                ("type", .string("image")),
                ("data", .string(image.base64)),
                ("mimeType", .string(image.mediaType))
            ])
        })
        return .object([
            ("jsonrpc", .string("2.0")),
            ("id", id),
            ("result", .object([
                ("content", .array(content)),
                ("isError", .bool(isError))
            ]))
        ])
    }

    static func errorResponse(id: JSValue, code: Int, message: String) -> JSValue {
        .object([
            ("jsonrpc", .string("2.0")),
            ("id", id),
            ("error", .object([("code", .number(code)), ("message", .string(message))]))
        ])
    }

    /// One message, one line, flushed. `stringify()` escapes control characters, so a
    /// payload can never contain the raw newline the framing depends on.
    static func write(_ message: JSValue) {
        // Unbuffered and EINTR-safe; `StandardStreams.swift` explains why neither
        // `fputs(…, stdout)` nor `FileHandle.standardOutput.write` can be used here.
        writeToStandardOutput(message.stringify() + "\n")
    }

    static func log(_ message: String) {
        writeToStandardError("alohajet mcp: \(message)\n")
    }

    /// stdin, one line at a time, read on its own thread: `readLine` blocks, and the main
    /// actor it would block is the one the tools run on.
    static func stdinLines() -> AsyncStream<String> {
        AsyncStream { continuation in
            let thread = Thread {
                while let line = readLine(strippingNewline: true) {
                    continuation.yield(line)
                }
                continuation.finish()
            }
            thread.name = "alohajet.mcp.stdin"
            thread.start()
        }
    }

    /// `JSValue` -> `WorkflowValue`, directly rather than through Foundation: the
    /// `anyValue` bridge hands an object back as `NSMutableDictionary`, whose cast to
    /// `[String: Any]` is a Darwin-only convenience and this package builds on Linux.
    static func workflowValue(_ value: JSValue) -> WorkflowValue {
        switch value {
        case .null, .undefined: return .null
        case .bool(let flag): return .bool(flag)
        case .number(let number): return .number(number)
        case .string(let text): return .string(text)
        case .array(let elements): return .array(elements.map(workflowValue))
        case .object(let members):
            return .object(Dictionary(members.map { ($0.0, workflowValue($0.1)) },
                                      uniquingKeysWith: { _, last in last }))
        }
    }
}

// MARK: - Connection

/// Which browser this server drives, from the CLI's own connection flags: `--cdp
/// <ws-url|port|host:port>` attaches to a running one, `--browser aloha` attaches to the
/// Aloha browser's own CDP listener, and anything else launches a throwaway Chromium
/// (`--no-headless` to watch it, `--port` to fix the debug port).
///
/// Parsed here rather than shared with `main.swift` because the two front ends are
/// written by different hands and this file must not break when the CLI's parser moves.
/// What is NOT duplicated is the aloha lane: both front ends resolve it through the one
/// `AlohaBrowser`, and what comes back is an endpoint string that joins the `--cdp` path
/// below. An MCP host configured `--browser aloha` that silently got a throwaway headless
/// Chromium instead is worse than one that fails outright — the model then drives a
/// browser nobody is looking at and every answer is about the wrong tabs.
struct MCPConnection {
    private var endpoint: String?
    private var browser: String?
    private var headless = true
    private var port: Int?

    init(_ argv: [String]) {
        var index = 0
        while index < argv.count {
            let token = argv[index]
            // `--flag=value` and `--flag value` both work, matching the CLI.
            let (name, inlineValue): (String, String?) = {
                guard let equals = token.firstIndex(of: "=") else { return (token, nil) }
                return (String(token[token.startIndex..<equals]), String(token[token.index(after: equals)...]))
            }()
            func take() -> String? {
                if let inlineValue { return inlineValue }
                index += 1
                return index < argv.count ? argv[index] : nil
            }
            switch name {
            case "--cdp": endpoint = take()
            case "--browser": browser = take()
            case "--port": port = take().flatMap(Int.init)
            case "--no-headless", "--headed": headless = false
            default: break
            }
            index += 1
        }
    }

    func open() async throws -> BrowserToolSession {
        var endpoint = self.endpoint
        switch browser {
        case nil, "chromium":
            break
        case "aloha":
            guard endpoint == nil else {
                throw BrowserToolSessionError.connectFailed(
                    "--browser aloha and --cdp name two different browsers; pass one")
            }
            do {
                endpoint = try await AlohaBrowser().endpoint().absoluteString
            } catch let error as AlohaBrowserError {
                throw BrowserToolSessionError.connectFailed(error.description)
            }
        case let other?:
            throw BrowserToolSessionError.connectFailed(
                "--browser expects chromium or aloha, got \"\(other)\"")
        }

        guard let endpoint else {
            return try await BrowserToolSession.launch(headless: headless, port: port)
        }
        if endpoint.hasPrefix("ws://") || endpoint.hasPrefix("wss://") {
            return try await BrowserToolSession.attach(webSocketURL: endpoint)
        }
        if let port = Int(endpoint) {
            return try await BrowserToolSession.attach(port: port)
        }
        let parts = endpoint.split(separator: ":")
        guard parts.count == 2, let port = Int(parts[1]) else {
            throw BrowserToolSessionError.connectFailed(
                "--cdp expects a ws:// url, a port, or host:port — got \"\(endpoint)\"")
        }
        return try await BrowserToolSession.attach(host: String(parts[0]), port: port)
    }
}
