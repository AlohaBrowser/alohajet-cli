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
/// running one in this process. `runTask`:
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
/// The lane is SERVER-side state — `POST /agent/task` writes to whatever conversation
/// the host is currently on, and carries no conversation of its own — so choosing one
/// means moving the host's lane first via `POST /agent/new`.
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

public struct RemoteAutomationDriver: AlohaJetDriver {
    /// The transport seam: issue ONE HTTP request (method + absolute URL + optional
    /// body) and yield its status + body. Injected so tests are hermetic (a stub, no
    /// socket); defaults to `liveTransport` (a real `URLSession`).
    public typealias Transport =
        @Sendable (_ method: String, _ url: URL, _ body: Data?) async throws -> RemoteAutomationHTTPResponse

    /// The agent endpoint's base URL (e.g. `http://127.0.0.1:8765`); the agent
    /// routes are resolved against it.
    public let endpoint: URL
    /// What this run grants the page. A property of the RUN, not of the prompt, so
    /// it rides on `init` rather than on the shared `AlohaJetDriver.runTask` signature.
    public let permissions: [CLIPermission]
    private let transport: Transport
    private let pollInterval: Duration
    /// The maximum number of `running` polls before the wait is abandoned as a
    /// `.failed` timeout — bounds the loop so it never busy-spins forever.
    private let maxPollAttempts: Int

    /// - Parameters:
    ///   - endpoint: the agent endpoint's base URL.
    ///   - permissions: what the page may use; empty (the default) denies everything.
    ///   - transport: the HTTP seam; defaults to the real `URLSession` transport.
    ///   - pollInterval: delay between `running` polls (default 250 ms).
    ///   - maxPollAttempts: cap on `running` polls (default 2400 ≈ 10 min at 250 ms).
    ///   - session: which conversation the turn runs in. `.fresh` by default.
    public init(
        endpoint: URL,
        permissions: [CLIPermission] = [],
        session: AgentSession = .fresh,
        transport: @escaping Transport = RemoteAutomationDriver.liveTransport,
        pollInterval: Duration = .milliseconds(250),
        maxPollAttempts: Int = 2400
    ) {
        self.endpoint = endpoint
        self.permissions = permissions
        self.session = session
        self.transport = transport
        self.pollInterval = pollInterval
        self.maxPollAttempts = maxPollAttempts
    }

    /// The conversation the turn ran in, reported so a caller can resume it. Filled by
    /// `runTask(prompt:reportingSession:)`; `nil` when the host answered without one.
    public let session: AgentSession

    public func runTask(prompt: String) async throws -> CLIRunResult {
        await runTurn(prompt: prompt).result
    }

    /// The turn, plus the conversation it ran in so the caller can resume it.
    ///
    /// The id comes back from `POST /agent/new`; under `.current` the host is never
    /// asked to move, so there is nothing to report and the id is `nil`.
    public func runTurn(prompt: String) async -> (result: CLIRunResult, sessionId: String?) {
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
        var attempt = 0
        while attempt < maxPollAttempts {
            let response = try await transport("GET", agentURL(path: "/agent/result", queryItems: [URLQueryItem(name: "taskId", value: taskId)]), nil)
            guard response.statusCode == 200 else {
                return Self.failed("automation server /agent/result returned HTTP \(response.statusCode)")
            }
            guard let envelope = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
                  let state = envelope["state"] as? String else {
                return Self.failed("automation server /agent/result returned an unreadable envelope")
            }
            switch state {
            case "running":
                attempt += 1
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

    private static func stringValue(_ data: Data, key: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object[key] as? String
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

    /// The production transport: a real `URLSession` request/response. The agent
    /// endpoint reads only the request line + `Content-Length` body, so no
    /// content-type header is required (the `/agent/task` body is a raw prompt, not
    /// JSON).
    public static let liveTransport: Transport = { method, url, body in
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body { request.httpBody = body }
        // Every agent route is bearer-token gated (401 otherwise). See
        // `AutomationToken` for where the shared secret is read from and why this
        // reads it per request.
        if let token = AutomationToken.read() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return RemoteAutomationHTTPResponse(statusCode: status, body: data)
    }
}
