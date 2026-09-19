import Testing
import Foundation
@testable import AgentDriver

// MARK: - RemoteAutomationDriver unit coverage (hermetic, no socket)
//
// Exercises the remote `AlohaJetDriver` end to end over an INJECTED transport stub
// that speaks the EXACT agent wire (`/agent/permissions`, `/agent/task`,
// `/agent/result`) — no network. The stub records every request so the driver's
// contract can be pinned: the always-sent permission write, the raw-prompt task
// body, bounded polling, and the terminal decode through the ONE wire encoder. A
// SUCCESS fixture and a FAILURE fixture both flow through UNCHANGED (the driver
// never rewrites the outcome); a `409` busy, a `rejected`, and a `displaced`
// terminal each map to a `.failed` result.

// MARK: Shared hermetic-wire helpers (reused by DriverParityTests)

/// Build the EXACT `/agent/result` envelope an agent endpoint emits: the outer
/// `{ state, result }` object where `result` is the `CLIRunResult` run through the
/// ONE wire encoder (`encodedWireData()`) and re-parsed into a JSON object. A `nil`
/// result (a `running` / `rejected` / `displaced` poll) serializes as JSON `null`.
func remoteResultEnvelope(state: String, result: CLIRunResult?) throws -> Data {
    var envelope: [String: Any] = ["state": state]
    if let result {
        let wire = try result.encodedWireData()
        envelope["result"] = try JSONSerialization.jsonObject(with: wire)
    } else {
        envelope["result"] = NSNull()
    }
    return try JSONSerialization.data(withJSONObject: envelope)
}

/// A hermetic stand-in for the agent endpoint: records every request and returns
/// scripted responses. `resultBodies` is the ordered sequence of `/agent/result`
/// envelopes; once a single one remains it is returned for every further poll (so a
/// lone `running` envelope drives the bounded-timeout path).
actor RemoteStubServer {
    private(set) var requests: [(method: String, path: String, body: String)] = []
    private let taskId: String
    private let permissionsStatus: Int
    private let taskStatus: Int
    private let quitStatus: Int
    private var resultBodies: [Data]

    init(taskId: String = "11111111-1111-1111-1111-111111111111", permissionsStatus: Int = 200, taskStatus: Int = 200, quitStatus: Int = 200, resultBodies: [Data]) {
        self.taskId = taskId
        self.permissionsStatus = permissionsStatus
        self.taskStatus = taskStatus
        self.quitStatus = quitStatus
        self.resultBodies = resultBodies
    }

    /// `/agent/new` status, and an id that overrides what it answers with.
    var newStatus: Int = 200
    private(set) var newSessionOverride: String?
    func setNewSessionOverride(_ id: String?) { newSessionOverride = id }

    private var termsStatus = 200
    private var afterTerms: Data?
    func answerTerms(status: Int, then envelope: Data) {
        termsStatus = status
        afterTerms = envelope
    }
    func script(_ bodies: [Data]) { resultBodies = bodies }

    func handle(method: String, path: String, body: String) -> RemoteAutomationHTTPResponse {
        requests.append((method, path, body))
        switch path {
        case "/agent/new":
            // The host answers with the lane it moved to: the id it was handed, or a
            // minted one. `newSessionOverride` lets a test play a host that ignores the
            // request, which the driver must refuse rather than run in the wrong chat.
            let requested = (try? JSONSerialization.jsonObject(with: Data(body.utf8)))
                .flatMap { ($0 as? [String: Any])?["sessionId"] as? String }
            let lane = newSessionOverride ?? requested ?? "minted-0001"
            return RemoteAutomationHTTPResponse(
                statusCode: newStatus,
                body: Data(#"{"ok":true,"sessionId":"\#(lane)"}"#.utf8))
        case "/agent/permissions":
            let granted = permissionsStatus == 200
            let payload = granted ? #"{"ok":true}"# : #"{"ok":false,"error":"unknown permission"}"#
            return RemoteAutomationHTTPResponse(statusCode: permissionsStatus, body: Data(payload.utf8))
        case "/agent/task":
            if taskStatus == 200 {
                return RemoteAutomationHTTPResponse(
                    statusCode: 200, body: Data(#"{"ok":true,"taskId":"\#(taskId)"}"#.utf8))
            }
            return RemoteAutomationHTTPResponse(
                statusCode: taskStatus, body: Data(#"{"ok":false,"error":"busy"}"#.utf8))
        case "/quit":
            let accepted = quitStatus == 200
            let payload = accepted ? #"{"ok":true}"# : #"{"ok":false,"error":"not headless"}"#
            return RemoteAutomationHTTPResponse(statusCode: quitStatus, body: Data(payload.utf8))
        case "/agent/terms":
            if let afterTerms { resultBodies = [afterTerms] }
            let payload = termsStatus == 200 ? #"{"ok":true}"# : #"{"ok":false,"error":"stale"}"#
            return RemoteAutomationHTTPResponse(statusCode: termsStatus, body: Data(payload.utf8))
        case "/agent/result":
            let next = resultBodies.count > 1 ? resultBodies.removeFirst() : (resultBodies.first ?? Data("{}".utf8))
            return RemoteAutomationHTTPResponse(statusCode: 200, body: next)
        default:
            return RemoteAutomationHTTPResponse(statusCode: 404, body: Data(#"{"error":"not found"}"#.utf8))
        }
    }

    var paths: [String] { requests.map(\.path) }
    var newCount: Int { requests.filter { $0.path == "/agent/new" }.count }
    func firstNewBody() -> String? { requests.first { $0.path == "/agent/new" }?.body }
    var permissionsCount: Int { requests.filter { $0.path == "/agent/permissions" }.count }
    var taskCount: Int { requests.filter { $0.path == "/agent/task" }.count }
    var resultCount: Int { requests.filter { $0.path == "/agent/result" }.count }
    var quitMethods: [String] { requests.filter { $0.path == "/quit" }.map(\.method) }
    func firstTaskBody() -> String? { requests.first { $0.path == "/agent/task" }?.body }
    func firstPermissionsBody() -> String? { requests.first { $0.path == "/agent/permissions" }?.body }
    var termsRequests: [(method: String, body: String)] {
        requests.filter { $0.path == "/agent/terms" }.map { ($0.method, $0.body) }
    }
}

/// Wire a driver to a stub server with a near-zero poll interval (fast, still
/// bounded). The endpoint host is unreachable on purpose — every byte flows through
/// the injected transport, never a socket.
func makeRemoteDriver(
    stub: RemoteStubServer, permissions: [CLIPermission] = [],
    session: AgentSession = .fresh, maxPollAttempts: Int = 50,
    notes: NoteSink = NoteSink(), terms: RemoteAutomationDriver.TermsResponder? = nil
) -> RemoteAutomationDriver {
    let transport: RemoteAutomationDriver.Transport = { method, url, body in
        let bodyStr = body.map { String(decoding: $0, as: UTF8.self) } ?? ""
        return await stub.handle(method: method, path: url.path, body: bodyStr)
    }
    return RemoteAutomationDriver(
        endpoint: URL(string: "http://127.0.0.1:65535")!,
        permissions: permissions,
        session: session,
        warn: { notes.add($0) },
        transport: transport,
        pollInterval: .milliseconds(1),
        maxPollAttempts: maxPollAttempts,
        terms: terms)
}

// MARK: Fixtures

/// The frozen SUCCESS fixture (clean end-of-turn with text) — matches the wire
/// round-trip + parity oracles.
let remoteSuccessFixture = CLIRunResult(finalText: "Four.", completion: .endTurn, failureReason: nil)
/// The frozen FAILURE fixture (a failed turn, no text, carried reason).
let remoteFailureFixture = CLIRunResult(finalText: nil, completion: .failed, failureReason: "boom")

@Suite("RemoteAutomationDriver")
struct RemoteAutomationDriverTests {

    // (a) HAPPY PATH: permissions -> task -> one poll -> the SUCCESS fixture is
    // returned UNCHANGED; the request sequence is permissions, task (raw prompt
    // body), result.
    @Test("happy path: permissions+task+poll returns the success fixture unchanged")
    func happyPathReturnsSuccessFixture() async throws {
        let done = try remoteResultEnvelope(state: "done", result: remoteSuccessFixture)
        let stub = RemoteStubServer(resultBodies: [done])
        let driver = makeRemoteDriver(stub: stub)

        let result = try await driver.runTask(prompt: "what is 2+2?")

        #expect(result == remoteSuccessFixture)
        #expect(result.isSuccess)
        #expect(await stub.permissionsCount == 1)
        #expect(await stub.taskCount == 1)
        #expect(await stub.resultCount == 1)
        // The task body is the RAW prompt (not JSON-wrapped).
        #expect(await stub.firstTaskBody() == "what is 2+2?")
    }

    // (b) FAILURE fixture flows through as isSuccess=false, UNCHANGED — a `done`
    // terminal carrying a failed CLIRunResult is decoded verbatim, not rewritten.
    @Test("failure fixture flows through unchanged as isSuccess=false")
    func failureFixtureFlowsThroughUnchanged() async throws {
        let done = try remoteResultEnvelope(state: "done", result: remoteFailureFixture)
        let stub = RemoteStubServer(resultBodies: [done])
        let driver = makeRemoteDriver(stub: stub)

        let result = try await driver.runTask(prompt: "do the thing")

        #expect(result == remoteFailureFixture)
        #expect(!result.isSuccess)
        #expect(result.completion == .failed)
        #expect(result.failureReason == "boom")
    }

    // Polling is bounded but DOES loop: a `running` poll then a `done` poll returns
    // the terminal fixture (two result requests).
    @Test("a running-then-done poll sequence returns the terminal fixture")
    func runningThenDoneReturnsTerminal() async throws {
        let running = try remoteResultEnvelope(state: "running", result: nil)
        let done = try remoteResultEnvelope(state: "done", result: remoteSuccessFixture)
        let stub = RemoteStubServer(resultBodies: [running, done])
        let driver = makeRemoteDriver(stub: stub)

        let result = try await driver.runTask(prompt: "wait for it")

        #expect(result == remoteSuccessFixture)
        #expect(await stub.resultCount == 2)
    }

    // (c.1) A `409` busy `/agent/task` maps to a `.failed` result (no poll happens).
    @Test("a 409-busy task response maps to a failed result")
    func busyTaskMapsToFailed() async throws {
        let stub = RemoteStubServer(taskStatus: 409, resultBodies: [])
        let driver = makeRemoteDriver(stub: stub)

        let result = try await driver.runTask(prompt: "collide")

        #expect(!result.isSuccess)
        #expect(result.completion == .failed)
        #expect(result.failureReason?.contains("/agent/task") == true)
        #expect(await stub.resultCount == 0)
    }

    // (c.2) A `rejected` terminal maps to a `.failed` result.
    @Test("a rejected terminal maps to a failed result")
    func rejectedTerminalMapsToFailed() async throws {
        let rejected = try remoteResultEnvelope(state: "rejected", result: nil)
        let stub = RemoteStubServer(resultBodies: [rejected])
        let driver = makeRemoteDriver(stub: stub)

        let result = try await driver.runTask(prompt: "nothing")

        #expect(!result.isSuccess)
        #expect(result.completion == .failed)
        #expect(result.failureReason?.contains("rejected") == true)
    }

    // (c.3) A `displaced` terminal maps to a `.failed` result.
    @Test("a displaced terminal maps to a failed result")
    func displacedTerminalMapsToFailed() async throws {
        let displaced = try remoteResultEnvelope(state: "displaced", result: nil)
        let stub = RemoteStubServer(resultBodies: [displaced])
        let driver = makeRemoteDriver(stub: stub)

        let result = try await driver.runTask(prompt: "stale")

        #expect(!result.isSuccess)
        #expect(result.completion == .failed)
        #expect(result.failureReason?.contains("displaced") == true)
    }

    // A poll budget exhausted by a never-terminating `running` maps to a bounded
    // `.failed` timeout (proves the loop cannot busy-spin forever).
    @Test("an endlessly-running task times out to a failed result")
    func endlessRunningTimesOut() async throws {
        let running = try remoteResultEnvelope(state: "running", result: nil)
        let stub = RemoteStubServer(resultBodies: [running])
        let driver = makeRemoteDriver(stub: stub, maxPollAttempts: 3)

        let result = try await driver.runTask(prompt: "hang")

        #expect(!result.isSuccess)
        #expect(result.completion == .failed)
        #expect(result.failureReason?.contains("timed out") == true)
        #expect(await stub.resultCount == 3)
    }

    // A transport-layer throw (a real network failure would surface this) maps to a
    // `.failed` result rather than propagating out of `runTask`.
    @Test("a transport error maps to a failed result")
    func transportErrorMapsToFailed() async throws {
        struct StubError: Error {}
        let transport: RemoteAutomationDriver.Transport = { _, _, _ in throw StubError() }
        let driver = RemoteAutomationDriver(
            endpoint: URL(string: "http://127.0.0.1:65535")!,
            transport: transport,
            pollInterval: .milliseconds(1))

        let result = try await driver.runTask(prompt: "boom")

        #expect(!result.isSuccess)
        #expect(result.completion == .failed)
        #expect(result.failureReason?.contains("transport error") == true)
    }
    // MARK: - /agent/permissions
    //
    // Sent on EVERY run, including the deny case, so a run never silently inherits
    // the grants of the one before it.

    @Test("the permissions hop precedes the task")
    func permissionsAreSentInOrder() async throws {
        let done = try remoteResultEnvelope(state: "done", result: remoteSuccessFixture)
        let stub = RemoteStubServer(resultBodies: [done])
        let driver = makeRemoteDriver(stub: stub, permissions: [.camera])

        _ = try await driver.runTask(prompt: "grant me")

        // `/agent/lane` first: the probe that picks the protocol. This stub has no such
        // route, so it answers 404 and the legacy sequence follows, unchanged.
        #expect(await stub.paths
                == ["/agent/lane", "/agent/new", "/agent/permissions", "/agent/task", "/agent/result"])
    }

    // An empty set is an explicit revoke, not a no-op: it still goes over the wire.
    @Test("a run granting nothing still sends the deny list")
    func denyIsStillSent() async throws {
        let done = try remoteResultEnvelope(state: "done", result: remoteSuccessFixture)
        let stub = RemoteStubServer(resultBodies: [done])
        let driver = makeRemoteDriver(stub: stub)

        _ = try await driver.runTask(prompt: "nothing granted")

        #expect(await stub.permissionsCount == 1)
        #expect(await stub.firstPermissionsBody() == #"{"permissions":[]}"#)
        #expect(await stub.taskCount == 1)
    }

    @Test("the body is an object carrying the raw names in canonical order")
    func permissionsBodyShape() async throws {
        let done = try remoteResultEnvelope(state: "done", result: remoteSuccessFixture)
        let stub = RemoteStubServer(resultBodies: [done])
        let driver = makeRemoteDriver(stub: stub, permissions: [.camera, .microphone])

        _ = try await driver.runTask(prompt: "two")

        let body = try #require(await stub.firstPermissionsBody())
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        #expect(object["permissions"] as? [String] == ["camera", "microphone"])
    }

    @Test("all five names go over the wire spelled exactly")
    func permissionsBodyCarriesEveryName() async throws {
        let done = try remoteResultEnvelope(state: "done", result: remoteSuccessFixture)
        let stub = RemoteStubServer(resultBodies: [done])
        let driver = makeRemoteDriver(stub: stub, permissions: CLIPermission.allCases)

        _ = try await driver.runTask(prompt: "everything")

        let body = try #require(await stub.firstPermissionsBody())
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        #expect(
            object["permissions"] as? [String]
                == ["camera", "microphone", "geolocation", "storage_access", "external_scheme"])
    }

    // A browser that will not take the grants must not then be handed the task: the
    // turn would run with the wrong permissions and nobody would know.
    @Test("a rejected permissions write fails the run before any task starts")
    func rejectedPermissionsStopTheRun() async throws {
        for status in [400, 404] {
            let stub = RemoteStubServer(permissionsStatus: status, resultBodies: [])
            let driver = makeRemoteDriver(stub: stub, permissions: [.camera])

            let result = try await driver.runTask(prompt: "denied")

            #expect(!result.isSuccess)
            #expect(result.completion == .failed)
            #expect(result.failureReason?.contains("/agent/permissions") == true)
            #expect(await stub.taskCount == 0)
        }
    }

    // The set is the DRIVER's, not the prompt's: the same prompt sends different
    // bodies from two differently-built drivers.
    @Test("the permission set comes from the driver, not the prompt")
    func permissionsComeFromTheDriver() async throws {
        func body(_ permissions: [CLIPermission]) async throws -> String? {
            let done = try remoteResultEnvelope(state: "done", result: remoteSuccessFixture)
            let stub = RemoteStubServer(resultBodies: [done])
            _ = try await makeRemoteDriver(stub: stub, permissions: permissions)
                .runTask(prompt: "same prompt")
            return await stub.firstPermissionsBody()
        }

        let granted = try await body([.geolocation])
        let denied = try await body([])
        #expect(granted == #"{"permissions":["geolocation"]}"#)
        #expect(denied != granted)
    }

    // MARK: - quit

    // `quit` is one POST and nothing else: no permissions, no task — it stops the
    // instance, it does not drive it.
    @Test("quit posts /quit alone and says nothing when the instance accepts")
    func quitAcceptedReportsNoFailure() async throws {
        let stub = RemoteStubServer(resultBodies: [])
        let driver = makeRemoteDriver(stub: stub)

        let failure = await driver.quit()

        #expect(failure == nil)
        #expect(await stub.paths == ["/quit"])
        #expect(await stub.quitMethods == ["POST"])
    }

    // The refusal a windowed browser answers with is REPORTED, not swallowed: the
    // whole point of the route is that ⌘Q is the only way to quit that one.
    @Test("a refused quit is reported verbatim on stderr terms")
    func refusedQuitIsReported() async throws {
        let stub = RemoteStubServer(quitStatus: 403, resultBodies: [])
        let driver = makeRemoteDriver(stub: stub)

        let failure = await driver.quit()

        let message = try #require(failure)
        #expect(message.hasPrefix("error:"))
        #expect(message.contains("/quit"))
        #expect(message.contains("403"))
        #expect(message.contains("not headless"))
    }

    // Nothing listening is a failure too — never a silent success.
    @Test("a transport error fails the quit")
    func transportErrorFailsTheQuit() async throws {
        struct Refused: Error {}
        let driver = RemoteAutomationDriver(
            endpoint: URL(string: "http://127.0.0.1:65535")!,
            transport: { _, _, _ in throw Refused() })

        let failure = await driver.quit()

        #expect(failure?.hasPrefix("error: automation transport error") == true)
    }

    // MARK: - Which conversation a turn runs in

    // The default is a FRESH conversation. Before this, every turn appended to whichever
    // one the host was last on, so two unrelated runs from two terminals landed in one
    // transcript and neither could be addressed afterwards.
    @Test("by default a turn mints a conversation and reports it")
    func freshIsTheDefault() async throws {
        let done = try remoteResultEnvelope(state: "done", result: remoteSuccessFixture)
        let stub = RemoteStubServer(resultBodies: [done])
        let driver = makeRemoteDriver(stub: stub)

        let (result, sessionId) = await driver.runTurn(prompt: "two plus two")

        #expect(result == remoteSuccessFixture)
        #expect(await stub.newCount == 1)
        #expect(await stub.firstNewBody() == "")   // no id: mint one
        #expect(sessionId == "minted-0001")
    }

    @Test("--resume names the conversation, and it is the one reported back")
    func resumeMovesToTheNamedLane() async throws {
        let done = try remoteResultEnvelope(state: "done", result: remoteSuccessFixture)
        let stub = RemoteStubServer(resultBodies: [done])
        let driver = makeRemoteDriver(stub: stub, session: .resume("chat-42"))

        let (result, sessionId) = await driver.runTurn(prompt: "and again")

        #expect(result == remoteSuccessFixture)
        #expect(await stub.firstNewBody()?.contains("chat-42") == true)
        #expect(sessionId == "chat-42")
    }

    // A host that predates per-id resume answers /agent/new with a minted id instead of
    // the requested one. Running anyway would append the turn to the WRONG conversation —
    // the single thing --resume exists to prevent — so the driver refuses.
    @Test("a host that ignores the requested id fails the turn instead of running elsewhere")
    func resumeRefusesWhenTheHostIgnoresTheId() async throws {
        let done = try remoteResultEnvelope(state: "done", result: remoteSuccessFixture)
        let stub = RemoteStubServer(resultBodies: [done])
        await stub.setNewSessionOverride("some-other-lane")
        let driver = makeRemoteDriver(stub: stub, session: .resume("chat-42"))

        let (result, sessionId) = await driver.runTurn(prompt: "and again")

        #expect(!result.isSuccess)
        #expect(result.failureReason?.contains("did not resume chat-42") == true)
        #expect(sessionId == "some-other-lane")
        #expect(await stub.taskCount == 0)   // the turn never ran
    }

    @Test("--continue leaves the host's lane alone")
    func currentSkipsTheLaneMove() async throws {
        let done = try remoteResultEnvelope(state: "done", result: remoteSuccessFixture)
        let stub = RemoteStubServer(resultBodies: [done])
        let driver = makeRemoteDriver(stub: stub, session: .current)

        let (result, sessionId) = await driver.runTurn(prompt: "carry on")

        #expect(result == remoteSuccessFixture)
        #expect(await stub.newCount == 0)
        #expect(sessionId == nil)   // nothing was chosen, so there is nothing to report
    }
}

func pendingTermsEnvelope(_ question: TermsQuestion) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
        "state": "running",
        "result": NSNull(),
        "pendingTerms": [
            "id": question.id,
            "termsUrl": question.termsUrl,
            "privacyUrl": question.privacyUrl,
            "answerableInApp": question.answerableInApp,
        ],
    ])
}

nonisolated final class QuestionSink: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [TermsQuestion] = []
    func add(_ question: TermsQuestion) { lock.withLock { items.append(question) } }
    var all: [TermsQuestion] { lock.withLock { items } }
}

@Suite("RemoteAutomationDriver terms question")
struct RemoteAutomationDriverTermsTests {
    static let question = TermsQuestion(
        id: "Q-1", termsUrl: "https://example.com/terms",
        privacyUrl: "https://example.com/privacy", answerableInApp: true)
    static let done = { try! remoteResultEnvelope(state: "done", result: remoteSuccessFixture) }()

    @Test("the responder is asked once while the question repeats, and its answer is posted")
    func responderIsAskedOnce() async throws {
        let stub = RemoteStubServer(resultBodies: [try pendingTermsEnvelope(Self.question)])
        await stub.answerTerms(status: 200, then: Self.done)
        let asked = QuestionSink()
        let driver = makeRemoteDriver(stub: stub, maxPollAttempts: 10_000, terms: { question in
            asked.add(question)
            while await stub.resultCount < 3 { try? await Task.sleep(for: .milliseconds(1)) }
            return true
        })

        let result = try await driver.runTask(prompt: "hi")

        #expect(result == remoteSuccessFixture)
        #expect(asked.all == [Self.question])
        let posted = await stub.termsRequests
        #expect(posted.count == 1)
        #expect(posted.first?.method == "POST")
        let body = try #require(posted.first?.body)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        #expect(object["id"] as? String == "Q-1")
        #expect(object["accept"] as? Bool == true)
    }

    @Test("a question that disappears cancels the responder and posts nothing")
    func clearedQuestionCancelsTheResponder() async throws {
        let running = try remoteResultEnvelope(state: "running", result: nil)
        let stub = RemoteStubServer(resultBodies: [try pendingTermsEnvelope(Self.question), running])
        let cancelled = QuestionSink()
        let driver = makeRemoteDriver(stub: stub, maxPollAttempts: 10_000, terms: { question in
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(1)) }
            cancelled.add(question)
            await stub.script([Self.done])
            return true
        })

        let result = try await driver.runTask(prompt: "hi")

        #expect(result == remoteSuccessFixture)
        #expect(cancelled.all == [Self.question])
        #expect(await stub.termsRequests.isEmpty)
    }

    @Test("a stale answer is ignored and any other refusal is a note", arguments: [(409, false), (500, true)])
    func refusedAnswer(status: Int, warns: Bool) async throws {
        let stub = RemoteStubServer(resultBodies: [try pendingTermsEnvelope(Self.question)])
        await stub.answerTerms(status: status, then: Self.done)
        let notes = NoteSink()
        let driver = makeRemoteDriver(stub: stub, maxPollAttempts: 10_000, notes: notes, terms: { _ in false })

        let result = try await driver.runTask(prompt: "hi")

        #expect(result == remoteSuccessFixture)
        #expect(await stub.termsRequests.count == 1)
        #expect(notes.all.contains { $0.contains("/agent/terms") } == warns)
    }

    @Test("a terminal result waits for the cancelled responder to finish")
    func terminalResultWaitsForTheResponder() async throws {
        let stub = RemoteStubServer(resultBodies: [try pendingTermsEnvelope(Self.question)])
        let finished = QuestionSink()
        let driver = makeRemoteDriver(stub: stub, maxPollAttempts: 10_000, terms: { question in
            await stub.script([Self.done])
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(1)) }
            await Task.detached { try? await Task.sleep(for: .milliseconds(20)) }.value
            finished.add(question)
            return nil
        })

        let result = try await driver.runTask(prompt: "hi")

        #expect(result == remoteSuccessFixture)
        #expect(finished.all == [Self.question])
    }

    @Test("a question nobody answers here is left to the host")
    func unansweredQuestionPostsNothing() async throws {
        let stub = RemoteStubServer(resultBodies: [try pendingTermsEnvelope(Self.question)])
        let asked = QuestionSink()
        let driver = makeRemoteDriver(stub: stub, maxPollAttempts: 10_000, terms: { question in
            asked.add(question)
            await stub.script([Self.done])
            return nil
        })

        let result = try await driver.runTask(prompt: "hi")

        #expect(result == remoteSuccessFixture)
        #expect(asked.all == [Self.question])
        #expect(await stub.termsRequests.isEmpty)
    }
}
