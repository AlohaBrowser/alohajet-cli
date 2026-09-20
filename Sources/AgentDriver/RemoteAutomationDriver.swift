import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One HTTP exchange's outcome as the `RemoteAutomationDriver` transport seam
/// yields it: the numeric status code plus the raw body bytes. A pure value type
/// (`nonisolated`) so the off-main `URLSession` transport — and a hermetic test
/// stub — can construct it from any isolation.
public nonisolated struct RemoteAutomationHTTPResponse: Sendable {
    public let statusCode: Int
    public let body: Data

    public init(statusCode: Int, body: Data) {
        self.statusCode = statusCode
        self.body = body
    }
}

/// The remote `AlohaJetDriver`, and the whole of `alohajet -p`: it drives an agent
/// loop that already exists behind an HTTP endpoint (`--endpoint <url>`) instead of
/// running one in this process.
///
/// It speaks TWO protocols and picks between them with one read-only probe,
/// `GET /agent/lane`:
///
/// * **protocol 2** (`{"protocol":2,…}`) — ONE `POST /agent/run` carrying the prompt,
///   the conversation and the permission set in a single JSON body. The turn therefore
///   NAMES the conversation it runs in, so two terminals cannot write into each other's
///   chats, and the grant write is no longer a separate request another turn can
///   overwrite. `--continue` pins the probe's conversation once and is thereafter
///   identical to `--resume`.
/// * **protocol 1** (any other answer, including the `404` a pre-v2 host gives) — the
///   legacy three-request handshake below, byte-for-byte unchanged. It cannot bind a
///   task to a conversation, so concurrent turns against such a host are unsafe; the
///   driver says so through `warn` and runs anyway, because the SERIAL flow works and
///   refusing it would break every host that has not been updated yet.
///
/// The legacy sequence, retained for protocol 1:
///
/// 1. writes the run's permission set via `POST /agent/permissions` — ALWAYS,
///    including the empty deny list, so a run never inherits the grants of the one
///    before it;
/// 2. starts ONE turn via `POST /agent/task` (body = the raw prompt) and reads the
///    freshly minted `taskId`;
/// 3. polls `GET /agent/result?taskId=<id>` on a bounded loop until the state is no
///    longer `running`, then decodes the terminal `CLIRunResult` from the `result`
///    object through `JSONDecoder().decode(CLIRunResult.self, from:)` — the mirror
///    of the ONE wire encoder the server emits (`CLIRunResult.encodedWireData()`),
///    so `isSuccess` is re-derived here and never trusted from the wire.
///
/// Any transport / HTTP / decode failure, a `409` busy, or a `rejected` / `displaced`
/// terminal maps to a `.failed` `CLIRunResult` (this NEVER throws for those) — so the
/// executable's `encodedJSON()` / exit-code contract is identical whichever driver
/// ran (proven byte-for-byte by `DriverParityTests`).
/// Which conversation a turn runs in, mirroring what a print-mode agent CLI offers:
/// a fresh one unless the caller names one to continue.
///
/// Under protocol 2 the choice rides ON the turn (`POST /agent/run`'s `conversation`).
/// Under protocol 1 there is nowhere on the turn to put it — `POST /agent/task` writes
/// to whatever conversation the host is currently on — so choosing one means moving the
/// host's lane first via `POST /agent/new`, and two overlapping turns race for it.
public enum AgentSession: Equatable, Sendable {
    /// Mint a conversation for this turn. The default, because a turn that silently
    /// appends to whatever the user last typed in the app is a surprise, and because
    /// an id you were given back is the only thing you can resume.
    case fresh
    /// Continue the conversation with this id.
    case resume(String)
    /// Run in whatever conversation the host is already on, appending to it. This is
    /// what every turn did before the default changed.
    case current
}

public extension AgentSession {
    /// Why the flags name no conversation. A type only because `Result` needs an
    /// `Error`; the message is the whole of it, and the caller owns the exit code.
    struct FlagError: Error, Equatable {
        public let message: String
    }

    /// Which conversation the `--resume` / `--continue` flags name, or the usage message
    /// that says why they name none.
    ///
    /// It lives here, beside the type it produces, rather than in the executable that
    /// reads argv — an executable target cannot be imported by a test, and this rule had
    /// NO test at all while it silently reported `.fresh` for every flag combination.
    ///
    /// - Parameters:
    ///   - resume: `--resume`'s VALUE, or `nil` when it has none.
    ///   - hasResume: whether `--resume` was PRESENT. Distinct from its value on purpose:
    ///     an argument reader that treats an empty value as absent turns
    ///     `--resume "$CHAT_ID"` with an unset variable into a brand-new conversation
    ///     reported as a successful resume — the exact bug `--resume` exists to end.
    ///   - continueLast: whether `--continue` was present.
    static func resolve(
        resume: String?, hasResume: Bool, continueLast: Bool
    ) -> Result<AgentSession, FlagError> {
        if hasResume, continueLast {
            return .failure(FlagError(message: "--resume <id> and --continue both name a conversation; pass one"))
        }
        guard hasResume else { return .success(continueLast ? .current : .fresh) }

        // Trimmed ONCE, here, and the trimmed value is what goes on the wire: the server
        // trims what it receives and echoes that back, so sending the padded id makes the
        // resume guard refuse an id the host resumed correctly.
        let raw = resume?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { return .failure(FlagError(message: "--resume expects a chat id")) }
        // A chat id IS a UUID, and a non-UUID is refused HERE rather than on the wire: a
        // host that cannot parse one falls back to the user's most recent chat, so the
        // turn lands in a conversation nobody named and is reported as a resume.
        // Uppercased because that is the canonical spelling the host files chats under
        // and echoes back; send the other one and the resume guard refuses a conversation
        // that was in fact resumed correctly.
        guard let id = UUID(uuidString: raw) else {
            return .failure(FlagError(message: "--resume expects a chat id (a UUID) — got \"\(raw)\""))
        }
        return .success(.resume(id.uuidString))
    }
}

public nonisolated struct TermsQuestion: Sendable, Equatable {
    public let id: String
    public let termsUrl: String
    public let privacyUrl: String
    public let answerableInApp: Bool
}

public struct RemoteAutomationDriver: AlohaJetDriver {
    /// The transport seam: issue ONE HTTP request (method + absolute URL + optional
    /// body) and yield its status + body. Injected so tests are hermetic (a stub, no
    /// socket); defaults to `liveTransport` (a real `URLSession`).
    public typealias Transport =
        @Sendable (_ method: String, _ url: URL, _ body: Data?) async throws -> RemoteAutomationHTTPResponse
    public typealias TermsResponder = @Sendable (TermsQuestion) async -> Bool?

    /// The agent endpoint's base URL (e.g. `http://127.0.0.1:8765`); the agent
    /// routes are resolved against it.
    public let endpoint: URL
    /// What this run grants the page. A property of the RUN, not of the prompt, so
    /// it rides on `init` rather than on the shared `AlohaJetDriver.runTask` signature.
    public let permissions: [CLIPermission]
    private let transport: Transport
    /// Where a non-fatal notice goes — a legacy host, or a resumed id that named no
    /// existing conversation. The CLI sends these to stderr so a piped `--json` stdout
    /// stays clean; the default drops them, because a library must not print.
    private let warn: @Sendable (String) -> Void
    private let pollInterval: Duration
    /// The maximum number of `running` polls before the wait is abandoned as a
    /// `.failed` timeout — bounds the loop so it never busy-spins forever.
    private let maxPollAttempts: Int
    private let terms: TermsResponder?

    /// How many `/agent/result` polls in a row may fail on the transport before the wait
    /// is abandoned. At the default 250 ms interval that is ~5 s of a browser answering
    /// nothing — long enough to ride out one blocked main thread, short enough that a
    /// browser which has genuinely gone away is reported rather than waited on.
    public static let maxConsecutivePollFailures = 20

    /// - Parameters:
    ///   - endpoint: the agent endpoint's base URL.
    ///   - permissions: what the page may use; empty (the default) denies everything.
    ///   - transport: the HTTP seam; defaults to the real `URLSession` transport.
    ///   - pollInterval: delay between `running` polls (default 250 ms).
    ///   - maxPollAttempts: cap on `running` polls (default 2400 ≈ 10 min at 250 ms).
    ///   - session: which conversation the turn runs in. `.fresh` by default.
    ///   - warn: sink for non-fatal notices; dropped by default.
    public init(
        endpoint: URL,
        permissions: [CLIPermission] = [],
        session: AgentSession = .fresh,
        warn: @escaping @Sendable (String) -> Void = { _ in },
        transport: @escaping Transport = RemoteAutomationDriver.liveTransport,
        pollInterval: Duration = .milliseconds(250),
        maxPollAttempts: Int = 2400,
        terms: TermsResponder? = nil
    ) {
        self.endpoint = endpoint
        self.permissions = permissions
        self.session = session
        self.warn = warn
        self.transport = transport
        self.pollInterval = pollInterval
        self.maxPollAttempts = maxPollAttempts
        self.terms = terms
    }

    /// The conversation the turn ran in, reported so a caller can resume it. Filled by
    /// `runTask(prompt:reportingSession:)`; `nil` when the host answered without one.
    public let session: AgentSession

    public func runTask(prompt: String) async throws -> CLIRunResult {
        await runTurn(prompt: prompt).result
    }

    /// The turn, plus the conversation it ran in so the caller can resume it.
    ///
    /// The id is the one the SERVER answered with, never the one this asked for: under
    /// protocol 2 it is the canonical (uppercase) spelling the store files the chat
    /// under, which is what `--resume` must be given back. `nil` only when the host
    /// answered without one — which under protocol 1 is every `--continue`, since
    /// nothing is asked and nothing is told.
    public func runTurn(prompt: String) async -> (result: CLIRunResult, sessionId: String?) {
        // Which protocol this host speaks, from the one route that is safe to call
        // before anything is decided: `/agent/lane` is a pure read, and a pre-v2 host
        // answers it 404 from its default arm. That 404 IS the protocol-1 signal — no
        // version header, no capability negotiation, one GET the client needed anyway
        // (it is also `--continue`'s resolver).
        let lane: [String: Any]?
        do {
            let probe = try await transport("GET", agentURL(path: "/agent/lane"), nil)
            let object = probe.statusCode == 200 ? Self.jsonObject(probe.body) : nil
            lane = (object?["protocol"] as? Int) == 2 ? object : nil
        } catch {
            return (Self.failed("automation transport error: \(error)"), nil)
        }

        guard let lane else {
            warn("this browser speaks the legacy agent protocol; concurrent alohajet"
                 + " turns against it are not safe.")
            return await runProtocol1(prompt: prompt)
        }
        return await runProtocol2(prompt: prompt, lane: lane)
    }

    // MARK: - Protocol 2

    /// ONE request carries prompt + conversation + permissions, so there is no window
    /// between naming a conversation and running in it, and no separate grant write for
    /// another terminal's turn to overwrite.
    private func runProtocol2(prompt: String, lane: [String: Any]) async -> (result: CLIRunResult, sessionId: String?) {
        // Outside the `do`: a throw from the poll is exactly when the id is needed, and
        // declared inside it the catch could only ever report `nil`.
        var ran: String?
        do {
            // `.fresh` names nothing and the server mints one; `.current` PINS the lane
            // read by the probe, so it stops meaning "wherever the app is when the POST
            // lands" and becomes an ordinary id — which is why it can be printed and
            // resumed like one.
            let requested: String?
            switch session {
            case .fresh:
                requested = nil
            case let .resume(id):
                requested = id
            case .current:
                guard let current = lane["conversation"] as? String else {
                    return (Self.failed(
                        "automation server did not name the conversation it is on, so there"
                        + " is nothing for --continue to continue"), nil)
                }
                requested = current
            }

            var body: [String: Any] = ["prompt": prompt, "permissions": permissions.map(\.rawValue)]
            if let requested { body["conversation"] = requested }
            let response = try await transport("POST", agentURL(path: "/agent/run"), Self.jsonBody(body))
            guard response.statusCode == 200, let object = Self.jsonObject(response.body) else {
                return (Self.failed(Self.runFailure(response)), nil)
            }
            guard let taskId = object["taskId"] as? String else {
                return (Self.failed("automation server /agent/run returned no taskId"), nil)
            }
            // The conversation the server says it ran in. It is the answer that is
            // reported and resumed — the request only ASKED.
            ran = object["conversation"] as? String

            if let requested {
                // The guard that was load-bearing under protocol 1 (where the binding was
                // implicit in a lane a later request read) is a tautology here: the turn
                // named its own conversation. It stays as the cheap assertion it now is —
                // against a server that lies or a route that silently changed shape — and
                // the ONE thing it still genuinely catches is a missing field.
                guard let ran else {
                    return (Self.failed(
                        "automation server did not name the conversation it ran in, so it cannot"
                        + " be confirmed the turn ran in \(requested)."), nil)
                }
                // Case-insensitively: the server answers the canonical uppercase spelling,
                // and a caller that sent lowercase asked for the same chat.
                guard ran.caseInsensitiveCompare(requested) == .orderedSame else {
                    return (Self.failed(
                        "automation server did not run in \(requested): it answered with \(ran)."), ran)
                }
            }

            // An id that named no existing conversation is a NOTE, not a refusal: an id
            // printed by a turn that then failed before committing names nothing yet, and
            // refusing it would make the printed id dead forever instead of retryable.
            if case .resume = session, object["known"] as? Bool == false, let ran {
                warn("\(ran) named no existing conversation; starting a new one there.")
            }

            return (try await pollToTerminal(taskId: taskId), ran)
        } catch {
            return (Self.failed("automation transport error: \(error)"), ran)
        }
    }

    /// The refusals `/agent/run` can answer with, in the words the user needs. The
    /// server writes `message` for the two it can explain better than this side can
    /// (which conversation is busy with what grants, which id was malformed); the rest
    /// are fixed texts, and anything unrecognised falls back to the raw status + body
    /// rather than being smoothed into a lie.
    private static func runFailure(_ response: RemoteAutomationHTTPResponse) -> String {
        let object = jsonObject(response.body)
        let message = object?["message"] as? String
        let generic = "automation server refused /agent/run" + detail(response)
        switch (response.statusCode, object?["error"] as? String) {
        case (409, "permissions_conflict"), (400, "bad_conversation_id"):
            return message ?? generic
        case (409, _):
            return "that conversation already has a turn running;"
                + " wait for it or use a different --resume id"
        case (400, "empty_prompt"):
            return "-p needs a non-empty prompt"
        case (415, _):
            return "automation server rejected the request body (expected application/json)"
                + " — this browser is likely too old for this alohajet; update it"
        default:
            return generic
        }
    }

    // MARK: - Protocol 1 (legacy, frozen)

    /// The three-request handshake, unchanged: move the lane, write the grants
    /// process-globally, then post a prompt that carries no conversation of its own.
    /// Safe serially — which is how it is proven to work — and racy under overlap, which
    /// no client-side change can fix because the wire has nowhere to put the binding.
    private func runProtocol1(prompt: String) async -> (result: CLIRunResult, sessionId: String?) {
        var reportedSession: String?
        do {
            // 0) Choose the conversation BEFORE the turn, because `/agent/task` has no
            //    conversation of its own — it writes to whichever lane the host is on.
            switch session {
            case .current:
                break
            case .fresh, .resume:
                let body: Data?
                if case let .resume(id) = session {
                    body = Self.jsonBody(["sessionId": id])
                } else {
                    body = nil
                }
                let newResponse = try await transport("POST", agentURL(path: "/agent/new"), body)
                guard newResponse.statusCode == 200 else {
                    return (Self.failed("automation server refused /agent/new" + Self.detail(newResponse)), nil)
                }
                reportedSession = Self.stringValue(newResponse.body, key: "sessionId")
                if case let .resume(id) = session {
                    // A host that ignores the requested id silently would append the turn
                    // to the wrong conversation — the exact failure `--resume` exists to
                    // prevent — so refuse rather than run somewhere the caller did not ask for.
                    //
                    // A MISSING id is refused too, not waved through: `let got = reported`
                    // in the condition made a host that answers 200 without the key skip the
                    // whole check, which is the one response shape the guard cannot see past.
                    guard let got = reportedSession else {
                        return (Self.failed(
                            "automation server did not name the conversation it moved to, so "
                            + "it cannot be confirmed the turn would run in \(id). "
                            + "That host predates per-id resume; --continue is the only flag "
                            + "it can continue a conversation with."), nil)
                    }
                    guard got == id else {
                        return (Self.failed(
                            "automation server did not resume \(id): it answered with \(got). "
                            + "That host predates per-id resume; --continue is the only flag "
                            + "it can continue a conversation with."), got)
                    }
                }
            }

            // 1) The permission set, on EVERY run including the empty deny list, so a
            //    run never inherits the previous one's grants.
            let permissionsResponse = try await transport(
                "POST", agentURL(path: "/agent/permissions"), Self.permissionsBody(permissions))
            guard permissionsResponse.statusCode == 200 else {
                return (Self.failed("automation server rejected /agent/permissions" + Self.detail(permissionsResponse)), reportedSession)
            }

            // 2) Start ONE turn; the server mints a FRESH taskId (raw prompt body).
            let taskResponse = try await transport("POST", agentURL(path: "/agent/task"), Data(prompt.utf8))
            guard taskResponse.statusCode == 200 else {
                return (Self.failed("automation server refused /agent/task" + Self.detail(taskResponse)), reportedSession)
            }
            guard let taskId = Self.stringValue(taskResponse.body, key: "taskId") else {
                return (Self.failed("automation server /agent/task returned no taskId"), reportedSession)
            }

            // 3) Poll the task's result to a terminal state.
            return (try await pollToTerminal(taskId: taskId), reportedSession)
        } catch {
            // Any transport/URL/sleep-cancellation error is a turn failure, not a
            // thrown error — the exit-code contract stays identical whichever driver
            // ran, since every driver surfaces its failures inside the CLIRunResult.
            return (Self.failed("automation transport error: \(error)"), reportedSession)
        }
    }

    /// `POST /quit`: stop the instance at `endpoint`. Returns `nil` when it accepted
    /// and the stderr-ready message otherwise. Never throws, like `runTask`.
    public func quit() async -> String? {
        do {
            let response = try await transport("POST", agentURL(path: "/quit"), nil)
            guard response.statusCode == 200 else {
                return "error: automation server refused /quit" + Self.detail(response)
            }
            return nil
        } catch {
            return "error: automation transport error: \(error)"
        }
    }

    /// Poll `GET /agent/result?taskId=<id>` until the state is no longer `running`,
    /// bounded by `maxPollAttempts`. `done` decodes the terminal result;
    /// `rejected` / `displaced` / an unknown state / a non-200 / an exhausted budget
    /// all map to a `.failed` result.
    private func pollToTerminal(taskId: String) async throws -> CLIRunResult {
        var answering: (id: String, task: Task<Void, Never>)?
        let outcome: Result<CLIRunResult, any Error>
        do {
            outcome = .success(try await poll(taskId: taskId, answering: &answering))
        } catch {
            outcome = .failure(error)
        }
        answering?.task.cancel()
        await answering?.task.value
        return try outcome.get()
    }

    private func poll(taskId: String, answering: inout (id: String, task: Task<Void, Never>)?) async throws -> CLIRunResult {
        var asked: Set<String> = []
        var attempt = 0
        var termsPolls = 0
        var failures = 0
        while attempt < maxPollAttempts {
            let response: RemoteAutomationHTTPResponse
            do {
                response = try await transport("GET", agentURL(path: "/agent/result", queryItems: [URLQueryItem(name: "taskId", value: taskId)]), nil)
            } catch {
                // The poll is a liveness read against a server on the app's main thread,
                // which AppKit can block for seconds at a time. One dropped poll is not
                // the turn failing — the turn is running in the app either way — so it
                // costs an attempt out of the budget, not the whole run.
                failures += 1
                guard failures < Self.maxConsecutivePollFailures else {
                    return Self.failed(
                        "the browser stopped answering: \(failures) polls in a row failed"
                        + " (\((error as? URLError)?.localizedDescription ?? "\(error)"))")
                }
                attempt += 1
                try await Task.sleep(for: pollInterval)
                continue
            }
            failures = 0
            guard response.statusCode == 200 else {
                return Self.failed("automation server /agent/result returned HTTP \(response.statusCode)")
            }
            guard let envelope = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
                  let state = envelope["state"] as? String else {
                return Self.failed("automation server /agent/result returned an unreadable envelope")
            }
            switch state {
            case "running":
                let question = Self.termsQuestion(envelope["pendingTerms"])
                if let open = answering, open.id != question?.id {
                    open.task.cancel()
                }
                if let terms, let question, asked.insert(question.id).inserted {
                    answering = (question.id, Task { await answer(question, with: terms) })
                }
                if question != nil, termsPolls < maxPollAttempts { termsPolls += 1 } else { attempt += 1 }
                try await Task.sleep(for: pollInterval)
            case "done":
                return Self.decodeTerminal(envelope["result"])
            case "rejected":
                return Self.failed("automation task rejected (empty prompt — nothing to run)")
            case "displaced":
                return Self.failed("automation task displaced (unknown, evicted, or superseded task id)")
            default:
                return Self.failed("automation task returned an unknown state '\(state)'")
            }
        }
        return Self.failed("timed out waiting for the automation task after \(maxPollAttempts) polls")
    }

    private func answer(_ question: TermsQuestion, with terms: TermsResponder) async {
        guard let accept = await terms(question), !Task.isCancelled else { return }
        do {
            let response = try await transport(
                "POST", agentURL(path: "/agent/terms"), Self.jsonBody(["id": question.id, "accept": accept]))
            if response.statusCode != 200, response.statusCode != 409 {
                warn("automation server refused /agent/terms" + Self.detail(response))
            }
        } catch {
            if !Task.isCancelled { warn("automation transport error on /agent/terms: \(error)") }
        }
    }

    private static func termsQuestion(_ value: Any?) -> TermsQuestion? {
        guard let object = value as? [String: Any],
              let id = object["id"] as? String,
              let termsUrl = object["termsUrl"] as? String,
              let privacyUrl = object["privacyUrl"] as? String,
              let answerableInApp = object["answerableInApp"] as? Bool else { return nil }
        return TermsQuestion(id: id, termsUrl: termsUrl, privacyUrl: privacyUrl, answerableInApp: answerableInApp)
    }

    // MARK: - Wire helpers

    /// Decode the terminal `CLIRunResult` from the envelope's `result` object via
    /// `JSONDecoder().decode(CLIRunResult.self, from:)` — the exact mirror of the
    /// server's `encodedWireData()` producer, so `isSuccess` is re-derived here and
    /// never carried on the wire. A missing / null result on a `done` state is
    /// itself a failure.
    private static func decodeTerminal(_ resultObject: Any?) -> CLIRunResult {
        guard let resultObject, !(resultObject is NSNull),
              let data = try? JSONSerialization.data(withJSONObject: resultObject),
              let result = try? JSONDecoder().decode(CLIRunResult.self, from: data) else {
            return failed("automation task reported done but carried no decodable result")
        }
        return result
    }

    /// `{ "permissions": [<raw name>…] }` — an object, not a bare array, like every
    /// other JSON route on the server.
    private static func jsonBody(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    }

    private static func permissionsBody(_ permissions: [CLIPermission]) -> Data {
        let object: [String: Any] = ["permissions": permissions.map(\.rawValue)]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    }

    private static func jsonObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func stringValue(_ data: Data, key: String) -> String? {
        jsonObject(data)?[key] as? String
    }

    private static func detail(_ response: RemoteAutomationHTTPResponse) -> String {
        " (HTTP \(response.statusCode): \(String(decoding: response.body, as: UTF8.self)))"
    }

    private static func failed(_ reason: String) -> CLIRunResult {
        CLIRunResult(finalText: nil, completion: .failed, failureReason: reason)
    }

    /// Resolve an agent route against `endpoint`, preserving any base path the
    /// endpoint carries and appending the `/agent/...` path (+ optional query).
    private func agentURL(path: String, queryItems: [URLQueryItem] = []) -> URL {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) ?? URLComponents()
        let basePath = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = basePath + path
        if !queryItems.isEmpty { components.queryItems = queryItems }
        return components.url ?? endpoint
    }

    // MARK: - Live transport

    /// The production transport: a real `URLSession` request/response.
    public static let liveTransport: Transport = { method, url, body in
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body { request.httpBody = body }
        // `/agent/run` REQUIRES it (415 otherwise). The legacy
        // `/agent/task` body is a raw prompt, and labelling that JSON would be a lie the
        // frozen handler happens not to read.
        if url.path.hasSuffix("/agent/run") || url.path.hasSuffix("/agent/terms") {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        // Every agent route is bearer-token gated (401 otherwise). The URL is passed
        // in because WHERE decides WHICH: see `AutomationToken` for where the shared
        // secret is read from, why this reads it per request, and why the ambient one
        // goes to a loopback host only.
        if let token = AutomationToken.read(for: url) {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        // A poll is retried, so it must be noticed quickly: the default 60 s costs a
        // minute of the user's turn for one blocked main thread. The turn-STARTING
        // requests keep the default, since retrying one of those would start two turns.
        if url.path.hasSuffix("/agent/result") { request.timeoutInterval = 10 }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return RemoteAutomationHTTPResponse(statusCode: status, body: data)
    }
}
