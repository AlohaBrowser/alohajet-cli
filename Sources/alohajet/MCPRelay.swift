import Foundation
// `URLRequest` — the type the SDK hands the request modifier below — is in
// FoundationNetworking off Apple, exactly as `RemoteAutomationDriver` finds it.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import AgentDriver
import MCP
import ToolABI

// MARK: - `alohajet mcp --endpoint <url>` — stdio ⇄ Streamable-HTTP relay
//
// ON THIS LANE THE MCP SERVER IS THE BROWSER'S, NOT THIS PROCESS'S. A running Aloha
// browser mounts its own MCP server at `POST /mcp` on the loopback automation port
// (`http://127.0.0.1:8765` by default), and `claude mcp add --transport http …` already
// talks to it directly. Nothing in this file implements MCP: no tools, no schemas, no
// protocol handling — and no `BrowserToolSession`, which is the whole difference from
// `MCPServer.swift` next door. That one IS a server: it serves this package's own nine
// tools against a Chromium it launches itself. This is a pipe.
//
// It exists for exactly one client: Claude Desktop, whose `claude_desktop_config` parser
// accepts `{command, args, env}` and NOTHING else — an entry carrying `type`/`url`/
// `headers` is dropped with a "not valid MCP server configurations" dialog. (An .mcpb
// bundle would not help: a bundle wraps a stdio server too.) So a stdio front end is the
// only shape that client can be handed, and one flag apart from the server lane is
// cheaper than a second verb nobody can remember which half of.
//
// Both halves are the official SDK's own transports, deliberately — this file is the
// only reason the package has a dependency at all. The app's `StatefulHTTPServerTransport`
// validates `Accept: application/json, text/event-stream`, answers over SSE, issues a
// session id that must be replayed as `Mcp-Session-Id`, and checks the protocol-version
// header. `HTTPClientTransport` does all four already; hand-rolling them is the one way
// to get this wrong.
//
// The user pastes NO secret: the port comes from `--endpoint` and the bearer token is
// read per run by `AutomationToken` — the same reader `-p` uses, and the only one.

enum MCPRelay {

    /// Relay this process's stdin/stdout to `<endpoint>/mcp` until either side ends.
    /// Returns the process exit code.
    static func main(_ args: Args) async -> Int32 {
        let endpoint: URL
        switch resolveEndpoint(args) {
        case let .success(url): endpoint = url
        case let .failure(error):
            writeToStandardError("alohajet: \(error.message)\n")
            return error.code
        }

        noteEndpointWithoutToken(endpoint)

        // The server lane's rule holds here too: a host that closes the pipe must end
        // this at EOF, not kill us mid-write.
        signal(SIGPIPE, SIG_IGN)

        do {
            try await run(endpoint: endpoint)
            return exitOK
        } catch {
            // stdout is the JSON-RPC channel and carries nothing else, so the report of a
            // dead upstream goes to stderr — where the host's MCP log picks it up. A
            // refused connection is the common case (the browser is not running) and its
            // bridged `NSError` description is 700+ bytes of URLSession bookkeeping;
            // `URLError` carries the one readable sentence of it. Anything else prints
            // whole rather than be summarised into uselessness.
            let detail = (error as? URLError)?.localizedDescription ?? "\(error)"
            writeToStandardError("alohajet mcp: relay to \(endpoint.absoluteString) ended: \(detail)\n")
            return exitUnreachable
        }
    }

    /// Pumps frames between stdio and the browser's `/mcp` until either side ends or
    /// fails. Frames move verbatim, in both directions, with no inspection — a
    /// notification the client sends and an SSE-delivered response the server pushes are
    /// the same thing to this loop.
    ///
    /// `nonisolated` so the `requestModifier` closure handed to the transport actor is a
    /// disconnected value rather than a main-actor-isolated one (this target's default
    /// isolation), which the compiler refuses to send across actors.
    static nonisolated func run(endpoint: URL) async throws {
        // `URLSessionConfiguration.default`'s 60 s idle timer is a deadline nobody here
        // chose, and the app holds the POST open for the WHOLE tool call without a
        // keepalive — so a page that takes a minute to wake killed the session and threw
        // away work that had already happened. This process is a PIPE: the honest
        // deadline is the MCP host's own, and every host has one. A refused connection
        // is not a timeout, so "the browser is not running" still fails instantly.
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 600
        let upstream = HTTPClientTransport(
            endpoint: endpoint.appendingPathComponent("mcp"),
            configuration: configuration,
            // Request/response only: the browser-control tools never push
            // server-initiated messages, so the standing GET SSE stream the streaming
            // mode opens would be a connection held open for nothing.
            streaming: false,
            requestModifier: { request in
                // `read(for:)`, not a bare read of the file: the ambient token is the
                // browser's and `--endpoint` can name a host that is not this machine, so
                // a remote endpoint is served from `ALOHAJET_AGENT_TOKEN` or not at all.
                // An absent token is NOT substituted with an unauthenticated attempt —
                // the server answers 401 and the client sees that verbatim, which is the
                // honest report that the automation server was never enabled.
                guard let token = AutomationToken.read(for: endpoint) else { return request }
                var authorized = request
                authorized.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                return authorized
            })
        let downstream = StdioTransport()

        try await downstream.connect()
        try await upstream.connect()
        defer { Task { await upstream.disconnect(); await downstream.disconnect() } }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for try await frame in await downstream.receive() {
                    try await upstream.send(frame)
                }
            }
            group.addTask {
                for try await frame in await upstream.receive() {
                    try await downstream.send(frame)
                }
            }
            // The first half to finish ends the session: a closed stdin means the client
            // is gone, and a failed upstream is not recoverable from here.
            _ = try await group.next()
            group.cancelAll()
        }
    }

    /// The app's automation endpoint, or the message that names exactly what is missing.
    ///
    /// The rule is `-p`'s, to the letter, and it is written out a second time rather than
    /// shared: `AgentTurn` owns its copy and the two front ends must never drift into one
    /// being laxer than the other — so this is the copy to change when that one changes.
    /// What both enforce: an http(s) URL WITH a host (`URL(string: "localhost:8765")`
    /// parses happily with `localhost` as the SCHEME, and the failure then surfaces far
    /// from the typo), and plaintext only to this machine. The payload is not innocuous:
    /// every frame on this pipe drives the user's browser, and the header authorizing it
    /// grants the whole automation API.
    private static func resolveEndpoint(_ args: Args) -> Result<URL, CLIError> {
        guard let raw = args.value("--endpoint") else {
            return .failure(CLIError(message: """
                mcp --endpoint needs a URL, e.g. --endpoint http://127.0.0.1:8765.
                  With it, `alohajet mcp` relays stdio to the MCP server the Aloha browser
                  already runs at that URL (POST /mcp) — it serves no tools of its own and
                  launches no browser. Without it, `alohajet mcp` is this package's own MCP
                  server over this package's own tools.
                """, code: exitUsage))
        }
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else {
            return .failure(CLIError(message: "--endpoint expects an http(s) URL — got \"\(raw)\"", code: exitUsage))
        }
        guard scheme == "https" || AutomationToken.isLoopback(url) else {
            return .failure(CLIError(message: """
                --endpoint must be http to a loopback address, or https to anywhere — got \"\(raw)\".
                  Every frame this relays drives the browser, and the bearer token it sends
                  grants full control of it; neither goes over plaintext to a remote host.
                """, code: exitUsage))
        }
        return .success(url)
    }
}
