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
// click …` needs a browser and nothing else, `alohajet -p …` needs an agent. The
// agent it reaches for by default is the one in the Aloha browser on this machine
// (`--endpoint` names another), and since this binary ships INSIDE that app, a turn
// that finds it not running launches it and waits — see `AlohaAppLauncher`.

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

        // Nothing can answer until the app is up, and when the endpoint is the one on
        // this machine, bringing it up is this process's job — the app is the agent.
        // The launcher is also where `--headless` is ADJUDICATED: `open --args` reaches
        // a cold launch only, so a `--headless` run against a live windowed instance
        // would otherwise drive a visible browser while claiming not to. A failure here
        // exits 3, the browser-unreachable code, because that is exactly what it is; an
        // endpoint that is NOT this machine's app launches nothing and waits on nothing,
        // so `-p` against one still never touches a browser.
        do {
            try await AlohaAppLauncher().ensureRunning(
                endpoint: endpointURL, headless: args.has("--headless"),
                // Notices go to stderr for the same reason the driver's do: a piped
                // `--json` stdout must stay one parseable object.
                log: { writeToStandardError("alohajet: note: \($0)\n") })
        } catch {
            writeToStandardError("alohajet: \((error as? AlohaAppLaunchError)?.description ?? "\(error)")\n")
            return exitUnreachable
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
            writeToStandardOutput(result.encodedJSON(sessionId: sessionId) + "\n")
            return result.isSuccess ? exitOK : exitToolError
        }
        if result.isSuccess, let finalText = result.finalText {
            writeToStandardOutput(finalText + "\n")
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

    /// The agent endpoint: `--endpoint <url>` when it names one, else the automation
    /// server of the Aloha browser on this machine.
    ///
    /// The default is not a convenience, it is the common case: the binary ships as
    /// `<App>.app/Contents/Helpers/alohajet` and the agent it drives is the app it sits
    /// inside. `--endpoint` is for the exception — a second instance, a port forward,
    /// a host somewhere else.
    ///
    /// `has` before `value`, because they differ on ONE input and it is the dangerous
    /// one: `--endpoint "$AGENT"` with `AGENT` unset has still NAMED a host, and
    /// answering that with the local default would run the prompt against a browser
    /// nobody asked for. Refused, exactly as `--resume ""` is.
    ///
    /// The scheme/host check is not ceremony: `URL(string: "localhost:8765")` succeeds
    /// with `localhost` as the SCHEME, and the request that follows fails somewhere far
    /// from the typo that caused it.
    private static func resolveEndpoint(_ args: Args) -> Result<URL, CLIError> {
        if args.has("--endpoint"), args.value("--endpoint") == nil {
            return .failure(CLIError(
                message: "--endpoint expects an http(s) URL — got an empty one"
                    + " (drop the flag to use \(AlohaAppLauncher.defaultEndpoint))",
                code: exitUsage))
        }
        let raw = args.value("--endpoint") ?? AlohaAppLauncher.defaultEndpoint
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
