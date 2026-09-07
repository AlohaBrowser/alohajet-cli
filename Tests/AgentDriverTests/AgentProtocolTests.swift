import Testing
import Foundation
@testable import AgentDriver

// MARK: - Which protocol the driver speaks, and what it does with each
//
// The wire changed shape: a turn now NAMES the conversation it runs in, in the same
// request that carries the prompt and the grants, so two terminals cannot write into
// each other's chats and cannot rewrite each other's page permissions mid-turn. The
// old three-request handshake could not express that binding — the task read a lane a
// separate earlier request had moved — so it is not amended, it is left frozen and
// selected against.
//
// Everything here runs over the injected transport; no socket, no browser.

/// A hermetic protocol-2 host. `/agent/lane` answers the version + the conversation the
/// app is on; `/agent/run` answers through `run`, which by default ECHOES the requested
/// conversation UPPERCASED — the canonical spelling a real host files chats under, and
/// the thing the caller must report instead of what it asked for.
actor ProtocolStub {
    private(set) var requests: [(method: String, path: String, body: String)] = []
    private let lane: RemoteAutomationHTTPResponse
    private let run: @Sendable ([String: Any]) -> RemoteAutomationHTTPResponse
    private var results: [Data]

    init(
        lane: RemoteAutomationHTTPResponse,
        run: @escaping @Sendable ([String: Any]) -> RemoteAutomationHTTPResponse = ProtocolStub.echoingRun,
        results: [Data] = []
    ) {
        self.lane = lane
        self.run = run
        self.results = results
    }

    static func json(_ status: Int, _ object: [String: Any]) -> RemoteAutomationHTTPResponse {
        RemoteAutomationHTTPResponse(
            statusCode: status,
            body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
    }

    /// A protocol-2 `/agent/lane`: the version, plus the conversation the app is on.
    static func laneV2(_ conversation: String? = "AAAAAAAA-0000-4000-8000-00000000AAAA") -> RemoteAutomationHTTPResponse {
        var object: [String: Any] = ["protocol": 2, "known": true]
        if let conversation { object["conversation"] = conversation }
        return json(200, object)
    }

    /// What a pre-v2 host answers: its route table has no such path.
    static let laneMissing = json(404, ["error": "not found", "path": "/agent/lane"])

    static let echoingRun: @Sendable ([String: Any]) -> RemoteAutomationHTTPResponse = { body in
        let asked = (body["conversation"] as? String) ?? "BBBBBBBB-0000-4000-8000-00000000BBBB"
        return json(200, [
            "ok": true, "taskId": "task-1",
            "conversation": asked.uppercased(), "known": true,
        ])
    }

    func handle(method: String, path: String, body: String) -> RemoteAutomationHTTPResponse {
        requests.append((method, path, body))
        switch path {
        case "/agent/lane":
            return lane
        case "/agent/run":
            let object = ((try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]) ?? [:]
            return run(object)
        case "/agent/permissions", "/agent/new":
            return Self.json(200, ["ok": true, "sessionId": "legacy-lane"])
        case "/agent/task":
            return Self.json(200, ["ok": true, "taskId": "legacy-task"])
        case "/agent/result":
            let next = results.count > 1 ? results.removeFirst() : (results.first ?? Data("{}".utf8))
            return RemoteAutomationHTTPResponse(statusCode: 200, body: next)
        default:
            return Self.json(404, ["error": "not found"])
        }
    }

    var paths: [String] { requests.map(\.path) }
    /// The raw request body, as a String — a parsed `[String: Any]` cannot cross the
    /// actor boundary, and the bytes are what is being pinned anyway.
    func rawBody(of path: String) -> String? {
        requests.first(where: { $0.path == path })?.body
    }
}

/// The `/agent/run` request body, parsed on this side of the actor hop.
func runBody(_ stub: ProtocolStub) async -> [String: Any] {
    guard let raw = await stub.rawBody(of: "/agent/run"),
          let object = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any]
    else { return [:] }
    return object
}

/// Collects the driver's stderr-bound notices. `@unchecked Sendable` over a lock
/// because the `warn` seam is `@Sendable` and a test must read what went through it.
nonisolated final class NoteSink: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ note: String) { lock.lock(); items.append(note); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
}

func makeProtocolDriver(
    stub: ProtocolStub, permissions: [CLIPermission] = [],
    session: AgentSession = .fresh, notes: NoteSink = NoteSink()
) -> RemoteAutomationDriver {
    RemoteAutomationDriver(
        endpoint: URL(string: "http://127.0.0.1:65535")!,
        permissions: permissions,
        session: session,
        warn: { notes.add($0) },
        transport: { method, url, body in
            await stub.handle(method: method, path: url.path,
                              body: body.map { String(decoding: $0, as: UTF8.self) } ?? "")
        },
        pollInterval: .milliseconds(1),
        maxPollAttempts: 50)
}

private let doneEnvelope = { try! remoteResultEnvelope(state: "done", result: remoteSuccessFixture) }()

@Suite("Agent protocol selection")
struct AgentProtocolTests {

    // MARK: - The probe

    // One read-only GET decides it, and a pre-v2 host's 404 IS the answer — no version
    // header, no negotiation. The legacy sequence that follows is the one that works
    // today, unchanged, because breaking it would strand every un-updated browser.
    @Test("a host without /agent/lane gets the legacy three-request handshake")
    func legacyHostKeepsTheOldSequence() async throws {
        let stub = ProtocolStub(lane: ProtocolStub.laneMissing, results: [doneEnvelope])
        let notes = NoteSink()
        let driver = makeProtocolDriver(stub: stub, notes: notes)

        let (result, sessionId) = await driver.runTurn(prompt: "hi")

        #expect(result == remoteSuccessFixture)
        #expect(await stub.paths == ["/agent/lane", "/agent/new", "/agent/permissions", "/agent/task", "/agent/result"])
        #expect(sessionId == "legacy-lane")
        // And the user is told, once, that overlap is unsafe here — the one thing the
        // client can do about a wire with nowhere to put the binding.
        #expect(notes.all.count == 1)
        #expect(notes.all[0].contains("legacy agent protocol"))
    }

    // The whole point: ONE request carries prompt + conversation + grants, so there is
    // no window between naming a conversation and running in it, and no separate
    // permission write for another terminal's turn to overwrite.
    @Test("a protocol-2 host gets one /agent/run and no /agent/permissions")
    func protocol2CollapsesTheHandshake() async throws {
        let stub = ProtocolStub(lane: ProtocolStub.laneV2(), results: [doneEnvelope])
        let notes = NoteSink()
        let driver = makeProtocolDriver(stub: stub, permissions: [.camera], notes: notes)

        let result = try await driver.runTask(prompt: "two plus two")

        #expect(result == remoteSuccessFixture)
        #expect(await stub.paths == ["/agent/lane", "/agent/run", "/agent/result"])
        let body = await runBody(stub)
        #expect(body["prompt"] as? String == "two plus two")
        #expect(body["permissions"] as? [String] == ["camera"])
        #expect(notes.all.isEmpty)
    }

    // Absent, not empty: `.fresh` makes no claim on a conversation, and the server mints
    // one. The deny list is still explicit — `[]` is a value, not a missing field.
    @Test("a fresh turn names no conversation and still sends the deny list")
    func freshOmitsTheConversation() async throws {
        let stub = ProtocolStub(lane: ProtocolStub.laneV2(), results: [doneEnvelope])

        let (_, sessionId) = await makeProtocolDriver(stub: stub).runTurn(prompt: "new")

        let body = await runBody(stub)
        #expect(body["conversation"] == nil)
        #expect(body["permissions"] as? [String] == [])
        #expect(sessionId == "BBBBBBBB-0000-4000-8000-00000000BBBB")
    }

    // MARK: - Which conversation, and which id is reported

    @Test("--resume names the conversation on the turn itself")
    func resumeRidesOnTheRun() async throws {
        let id = "11111111-2222-4333-8444-555555555555"
        let stub = ProtocolStub(lane: ProtocolStub.laneV2(), results: [doneEnvelope])

        let (result, sessionId) = await makeProtocolDriver(stub: stub, session: .resume(id))
            .runTurn(prompt: "again")

        #expect(result == remoteSuccessFixture)
        #expect(await runBody(stub)["conversation"] as? String == id)
        #expect(sessionId == id)
    }

    // The id reported is the SERVER's, not the one asked for: it is the canonical
    // spelling the chat is filed under, and it is the only one that resumes.
    @Test("the reported id is the one the server answered with, not the one sent")
    func theServerSpellingIsWhatIsReported() async throws {
        let stub = ProtocolStub(lane: ProtocolStub.laneV2(), results: [doneEnvelope])

        let (result, sessionId) = await makeProtocolDriver(
            stub: stub, session: .resume("aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"))
            .runTurn(prompt: "case")

        // Same conversation, canonical spelling — so the guard must NOT fire on case.
        #expect(result.isSuccess)
        #expect(sessionId == "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE")
    }

    // The guard is a tautology on a correct protocol-2 server — the turn named its own
    // conversation — and it stays exactly for the server that is not correct.
    @Test("a server that answers with a different conversation fails the turn")
    func aLyingServerIsRefused() async throws {
        let elsewhere = ProtocolStub.json(200, [
            "ok": true, "taskId": "task-1",
            "conversation": "99999999-9999-4999-8999-999999999999", "known": true,
        ])
        let stub = ProtocolStub(lane: ProtocolStub.laneV2(), run: { _ in elsewhere }, results: [doneEnvelope])
        let asked = "11111111-2222-4333-8444-555555555555"

        let (result, sessionId) = await makeProtocolDriver(stub: stub, session: .resume(asked))
            .runTurn(prompt: "elsewhere")

        #expect(!result.isSuccess)
        #expect(result.failureReason?.contains("did not run in \(asked)") == true)
        #expect(sessionId == "99999999-9999-4999-8999-999999999999")
        #expect(await stub.paths.contains("/agent/result") == false)   // the turn was never awaited
    }

    // A 200 with no conversation in it is the one shape the guard can still genuinely
    // catch: nothing confirms where the turn went.
    @Test("a server that names no conversation at all fails the turn")
    func anUnnamedConversationIsRefused() async throws {
        let unnamed = ProtocolStub.json(200, ["ok": true, "taskId": "task-1"])
        let stub = ProtocolStub(lane: ProtocolStub.laneV2(), run: { _ in unnamed }, results: [doneEnvelope])

        let (result, _) = await makeProtocolDriver(
            stub: stub, session: .resume("11111111-2222-4333-8444-555555555555"))
            .runTurn(prompt: "where")

        #expect(!result.isSuccess)
        #expect(result.failureReason?.contains("cannot be confirmed") == true)
    }

    // `--continue` PINS the lane the probe read and thereafter is an ordinary id: it is
    // sent on the run, it is reported back, and it can be resumed. Under the legacy
    // protocol it could do none of that.
    @Test("--continue pins the probed lane and reports it")
    func continuePinsTheLane() async throws {
        let stub = ProtocolStub(lane: ProtocolStub.laneV2("CCCCCCCC-0000-4000-8000-00000000CCCC"), results: [doneEnvelope])

        let (result, sessionId) = await makeProtocolDriver(stub: stub, session: .current)
            .runTurn(prompt: "carry on")

        #expect(result == remoteSuccessFixture)
        #expect(await runBody(stub)["conversation"] as? String
                == "CCCCCCCC-0000-4000-8000-00000000CCCC")
        #expect(sessionId == "CCCCCCCC-0000-4000-8000-00000000CCCC")
    }

    // Rather than quietly minting a fresh one, which is what "continue" must never mean.
    @Test("--continue against a host that names no lane fails instead of starting fresh")
    func continueWithoutALaneFails() async throws {
        let stub = ProtocolStub(lane: ProtocolStub.laneV2(nil), results: [doneEnvelope])

        let (result, _) = await makeProtocolDriver(stub: stub, session: .current)
            .runTurn(prompt: "carry on")

        #expect(!result.isSuccess)
        #expect(result.failureReason?.contains("--continue") == true)
        #expect(await stub.paths == ["/agent/lane"])
    }

    // An id that names nothing YET — a turn that printed it and then failed before
    // committing — is a note, not a refusal. Refusing would make a printed id dead
    // forever; this way the retry simply works.
    @Test("an unknown resumed id warns on stderr and still runs")
    func unknownConversationWarnsAndRuns() async throws {
        let unknown = ProtocolStub.json(200, [
            "ok": true, "taskId": "task-1",
            "conversation": "11111111-2222-4333-8444-555555555555", "known": false,
        ])
        let stub = ProtocolStub(lane: ProtocolStub.laneV2(), run: { _ in unknown }, results: [doneEnvelope])
        let notes = NoteSink()

        let (result, _) = await makeProtocolDriver(
            stub: stub, session: .resume("11111111-2222-4333-8444-555555555555"), notes: notes)
            .runTurn(prompt: "retry")

        #expect(result == remoteSuccessFixture)
        #expect(notes.all.count == 1)
        #expect(notes.all[0].contains("named no existing conversation"))
    }

    // `known:false` on a FRESH turn is the normal case — the id was minted a moment ago
    // and nothing has committed to it yet. Warning about it would train users to ignore
    // the warning that matters.
    @Test("a fresh turn does not warn about an id it never asked for")
    func freshDoesNotWarnAboutKnown() async throws {
        let minted = ProtocolStub.json(200, [
            "ok": true, "taskId": "task-1",
            "conversation": "11111111-2222-4333-8444-555555555555", "known": false,
        ])
        let stub = ProtocolStub(lane: ProtocolStub.laneV2(), run: { _ in minted }, results: [doneEnvelope])
        let notes = NoteSink()

        _ = await makeProtocolDriver(stub: stub, notes: notes).runTurn(prompt: "new")

        #expect(notes.all.isEmpty)
    }

    // MARK: - The refusals /agent/run can answer with

    @Test("every /agent/run refusal maps to a failed turn with the words that fix it",
          arguments: [
            (409, #"{"ok":false,"error":"busy"}"#, "already has a turn running"),
            (409, #"{"ok":false,"error":"permissions_conflict","message":"another turn is running with page permissions [camera]"}"#,
                  "another turn is running with page permissions [camera]"),
            (400, #"{"ok":false,"error":"bad_conversation_id","message":"conversation must be a UUID - got \"probe-me\""}"#,
                  "conversation must be a UUID"),
            (400, #"{"ok":false,"error":"empty_prompt"}"#, "non-empty prompt"),
            (415, "", "application/json"),
            (500, #"{"ok":false,"error":"boom"}"#, "refused /agent/run"),
          ])
    func runRefusalsAreReported(_ status: Int, _ body: String, _ expected: String) async throws {
        let refusal = RemoteAutomationHTTPResponse(statusCode: status, body: Data(body.utf8))
        let stub = ProtocolStub(lane: ProtocolStub.laneV2(), run: { _ in refusal }, results: [doneEnvelope])

        let (result, sessionId) = await makeProtocolDriver(stub: stub).runTurn(prompt: "collide")

        #expect(!result.isSuccess)
        #expect(result.completion == CLITurnCompletion.failed)
        #expect(result.failureReason?.contains(expected) == true,
                "got: \(result.failureReason ?? "nil")")
        #expect(sessionId == nil)
        #expect(await stub.paths == ["/agent/lane", "/agent/run"])   // nothing was polled
    }

    // The probe is a READ. A host that is not there at all is a transport failure like
    // any other — never a silent fall-through to a protocol nobody confirmed.
    @Test("a dead endpoint fails at the probe")
    func aDeadEndpointFailsAtTheProbe() async throws {
        struct Refused: Error {}
        let driver = RemoteAutomationDriver(
            endpoint: URL(string: "http://127.0.0.1:65535")!,
            transport: { _, _, _ in throw Refused() },
            pollInterval: .milliseconds(1))

        let (result, sessionId) = await driver.runTurn(prompt: "nobody home")

        #expect(!result.isSuccess)
        #expect(result.failureReason?.contains("transport error") == true)
        #expect(sessionId == nil)
    }

    // A host that answers the route but claims a protocol this client does not speak is
    // handled as the legacy host it might be, not guessed at.
    @Test("an unknown protocol version falls back to the legacy handshake")
    func anUnknownVersionIsTreatedAsLegacy() async throws {
        let stub = ProtocolStub(lane: ProtocolStub.json(200, ["protocol": 99]), results: [doneEnvelope])

        let result = try await makeProtocolDriver(stub: stub).runTask(prompt: "hi")

        #expect(result == remoteSuccessFixture)
        #expect(await stub.paths.contains("/agent/new"))
        #expect(await stub.paths.contains("/agent/run") == false)
    }
}

// MARK: - Which conversation the flags name
//
// This rule had NO test while it lived in the executable, and the suite stayed green
// both with it hard-wired to `.fresh` and with `--resume` dropped from the argument
// reader's value flags — the second of which surfaces here as the empty-value case.

@Suite("AgentSession.resolve")
struct AgentSessionResolveTests {

    @Test("neither flag is a fresh conversation")
    func neitherIsFresh() {
        #expect(try! AgentSession.resolve(resume: nil, hasResume: false, continueLast: false).get() == .fresh)
    }

    @Test("--continue continues where the host is")
    func continueIsCurrent() {
        #expect(try! AgentSession.resolve(resume: nil, hasResume: false, continueLast: true).get() == .current)
    }

    // The whole point of the flag: the id is carried, not dropped.
    @Test("--resume carries the id")
    func resumeCarriesTheId() {
        let id = "11111111-2222-4333-8444-555555555555"
        #expect(try! AgentSession.resolve(resume: id, hasResume: true, continueLast: false).get() == .resume(id))
    }

    // The host files chats under the canonical uppercase spelling and echoes that back,
    // so a lowercase id must be normalised BEFORE it is sent or the resume guard refuses
    // a conversation that was resumed correctly.
    @Test("a lowercase id is normalised to the canonical spelling")
    func lowercaseIsNormalised() {
        let session = try! AgentSession.resolve(
            resume: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", hasResume: true, continueLast: false).get()
        #expect(session == .resume("AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"))
    }

    @Test("surrounding whitespace is trimmed off the id")
    func whitespaceIsTrimmed() {
        let session = try! AgentSession.resolve(
            resume: "  11111111-2222-4333-8444-555555555555\n", hasResume: true, continueLast: false).get()
        #expect(session == .resume("11111111-2222-4333-8444-555555555555"))
    }

    // A host that cannot parse the id opens the user's MOST RECENT chat and reports it as
    // the resume that was asked for — a silent cross-conversation write. Refused here,
    // one round trip earlier, where the message can name the actual mistake.
    @Test("a non-UUID id is a usage error, not a request",
          arguments: ["probe-me", "chat-42", "11111111-2222-4333-8444", "not a uuid at all"])
    func aNonUUIDIsRefused(_ raw: String) {
        let error = AgentSession.resolve(resume: raw, hasResume: true, continueLast: false)
        #expect(error == .failure(AgentSession.FlagError(message: "--resume expects a chat id (a UUID) — got \"\(raw)\"")))
    }

    // PRESENCE, not value: an argument reader that folds an empty value into "absent"
    // makes `--resume "$CHAT_ID"` with an unset variable mint a brand-new conversation
    // and call it a resume.
    @Test("--resume with no value is a usage error, never a fresh conversation",
          arguments: [nil, "", "   "])
    func anEmptyValueIsRefused(_ raw: String?) {
        let error = AgentSession.resolve(resume: raw, hasResume: true, continueLast: false)
        #expect(error == .failure(AgentSession.FlagError(message: "--resume expects a chat id")))
    }

    @Test("--resume and --continue together are a usage error")
    func bothFlagsConflict() {
        let error = AgentSession.resolve(
            resume: "11111111-2222-4333-8444-555555555555", hasResume: true, continueLast: true)
        #expect(error == .failure(AgentSession.FlagError(
            message: "--resume <id> and --continue both name a conversation; pass one")))
    }
}
