import Foundation
import AgentDriver
import ToolABI

// MARK: - `alohajet -p "<prompt>"` — one agent turn
//
// The turn does NOT run here. This package ships the tool surface — `open`, `read`,
// `click` and the rest — and no agent loop, deliberately: an agent loop needs a
// model, a key, a system prompt and a transcript, none of which belong in a browser
// -control tool. So `-p` hands the prompt to a loop that ALREADY runs behind an
// HTTP endpoint (`--endpoint <url>`, serving `POST /agent/task`) and reports what
// comes back.
//
// That is the one real difference between `-p` and every other command: `alohajet
// click …` needs a browser and nothing else, `alohajet -p …` needs an agent. With
// no endpoint there is nothing to run the turn, and this says so and exits 2 —
// rather than pretending, which is what a stub loop would be.

enum AgentTurn {

    /// Run one turn and return the process exit code. Mirrors the exit contract every
    /// other command uses: 0 only on a clean end-of-turn WITH assistant text, 1 on any
    /// other outcome, 2 when the invocation itself is unusable.
    static func run(_ args: Args) async -> Int32 {
        let json = args.has("--json")

        guard let prompt = args.value("-p") else {
            writeToStandardError("alohajet: -p needs a prompt, e.g. alohajet -p \"book me a table\"\n")
            return exitUsage
        }

        let endpointURL: URL
        switch resolveEndpoint(args) {
        case let .success(url): endpointURL = url
        case let .failure(error):
            writeToStandardError("alohajet: \(error.message)\n")
            return error.code
        }

        let session: AgentSession
        switch resolveSession(args) {
        case let .success(value): session = value
        case let .failure(error):
            writeToStandardError("alohajet: \(error.message)\n")
            return error.code
        }

        // Every failure the driver can meet — no socket, a 409 busy, a rejected task,
        // an unreadable envelope — comes back INSIDE the result as `.failed`, so this
        // one call covers the lot.
        let (result, sessionId) = await RemoteAutomationDriver(
            endpoint: endpointURL, session: session,
            // Notices — a host that speaks only the legacy protocol, a resumed id that
            // names no conversation yet — go to stderr, never stdout: a piped `--json`
            // must stay one parseable object.
            warn: { writeToStandardError("alohajet: note: \($0)\n") }
        ).runTurn(prompt: prompt)

        // The headless eval surface: the whole result as ONE JSON object on stdout
        // (success and failure alike), with the exit code preserved.
        if json {
            print(result.encodedJSON(sessionId: sessionId))
            return result.isSuccess ? exitOK : exitToolError
        }
        if result.isSuccess, let finalText = result.finalText {
            print(finalText)
            // The id goes to stderr, not stdout: piping the answer somewhere must not
            // pick this up. It is only useful when there IS something to resume.
            // Printed whenever the host named one — including under `--continue`, which
            // against a protocol-2 host resolves to a concrete id that can be resumed by
            // id from then on. A legacy `--continue` names nothing and prints nothing.
            if let sessionId {
                writeToStandardError("\nchat \(sessionId) — continue it with: --resume \(sessionId)\n")
            }
            return exitOK
        }
        let reasonSuffix = result.failureReason.map { ": \($0)" } ?? ""
        switch result.completion {
        case .maxTurns:
            writeToStandardError(
                "alohajet: the turn hit the max-turns cap before producing a final answer\(reasonSuffix)\n")
        case .stuckRepeat:
            writeToStandardError(
                "alohajet: the same tool call kept producing the same result, so the turn was stopped"
                + " before producing a final answer\(reasonSuffix)\n")
        case .failed:
            writeToStandardError("alohajet: the turn failed before producing a final answer\(reasonSuffix)\n")
        case .interrupted:
            writeToStandardError("alohajet: the turn was interrupted before producing a final answer\(reasonSuffix)\n")
        case .endTurn:
            writeToStandardError("alohajet: the turn ended without any assistant text\n")
        }
        return exitToolError
    }

    /// Which conversation the turn runs in — the rule itself is `AgentSession.resolve`,
    /// in the library, where a test can reach it; this only reads argv and maps the
    /// refusal onto the usage exit code.
    ///
    /// A fresh conversation by default. Before that, every `-p` appended to whatever
    /// conversation the app was last on, so two unrelated turns from two terminals landed
    /// in one transcript and neither could be addressed afterwards.
    private static func resolveSession(_ args: Args) -> Result<AgentSession, CLIError> {
        AgentSession.resolve(
            resume: args.value("--resume"),
            hasResume: args.has("--resume"),
            continueLast: args.has("--continue")
        ).mapError { CLIError(message: $0.message, code: exitUsage) }
    }

    /// The agent endpoint, or the message that names exactly what is missing.
    ///
    /// The scheme/host check is not ceremony: `URL(string: "localhost:8765")` succeeds
    /// with `localhost` as the SCHEME, and the request that follows fails somewhere far
    /// from the typo that caused it.
    private static func resolveEndpoint(_ args: Args) -> Result<URL, CLIError> {
        guard let raw = args.value("--endpoint") else {
            return .failure(CLIError(message: """
                -p needs an agent endpoint: pass --endpoint <url>.
                  `alohajet -p` does not run an agent loop — it hands the prompt to one already
                  running behind that URL (POST /agent/task, e.g. the Aloha browser's automation
                  server on http://127.0.0.1:8765). Its bearer token is read as described under
                  ENVIRONMENT in `alohajet --help`.
                  The tool commands (open, read, click, type, …) need no endpoint and no agent.
                """, code: exitUsage))
        }
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else {
            return .failure(CLIError(message: "--endpoint expects an http(s) URL — got \"\(raw)\"", code: exitUsage))
        }
        // Plaintext to somewhere that is not this machine is refused outright rather
        // than downgraded to an unauthenticated request: the bearer token this sends
        // grants /agent/task, /agent/config — which rewrites the user's LLM provider
        // key — and /quit, and dropping the header would still ship the PROMPT off the
        // machine in the clear, then misreport the resulting 401 as a token problem.
        // https is allowed anywhere (TLS covers the wire); what such a host does NOT
        // get is the ambient token off disk — see `AutomationToken.read(for:)`.
        guard scheme == "https" || AutomationToken.isLoopback(url) else {
            return .failure(CLIError(message: """
                --endpoint must be loopback http or https — got \"\(raw)\".
                  The bearer token this sends grants full control of the browser and rewrites
                  the user's provider API key; it is not sent over plaintext to a remote host.
                """, code: exitUsage))
        }
        return .success(url)
    }
}
