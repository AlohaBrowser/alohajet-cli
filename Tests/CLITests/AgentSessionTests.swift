import Foundation
import Testing

// MARK: - `-p`: which conversation the flags choose, and which stream the id lands on
//
// THE GAP THIS FILLS. The suite used to stay green with `resolveSession` hard-wired to
// `.fresh`, and green with `"--resume"` removed from `valueFlags` — the exact bug the
// feature commit fixed — because nothing between argv and the driver was ever executed
// by a test. `AgentSession` is resolved inside the executable, from flags, so the only
// place it is observable is from OUTSIDE the process: at the wire (`AgentStubServer`
// records what `-p` actually asked the host for) and at the two output streams.
//
// The driver's own wire is pinned hermetically elsewhere. What is only reachable here is
// argv → session → request, and stdout vs stderr.

@Suite("agent turn, through the process", .serialized)
struct AgentSessionTests {

    /// A real chat id. `--resume` takes a UUID and nothing else, so the fixtures are
    /// UUIDs — and this one is lowercase on purpose (see `resumeSendsTheCanonicalId`).
    static let chatA = "33333333-3333-4333-8333-333333333333"

    /// A turn against the stub, with the ambient token replaced by a known one so the
    /// case neither depends on the developer's real token file nor hands it to a stub.
    private func runTurn(_ arguments: [String], stub: AgentStubServer, terminal: String? = nil) throws -> RunOutput {
        try runCLI(arguments + ["--endpoint", stub.url],
                   terminal: terminal,
                   environment: ["ALOHAJET_AGENT_TOKEN": "test-token"],
                   timeout: 60)
    }

    private func withStub<T>(
        protocolVersion: Int = 1, finalText: String = "Four.", ranOverride: String? = nil,
        termsAnswerableInApp: Bool? = nil,
        _ body: (AgentStubServer) throws -> T
    ) throws -> T {
        let stub = AgentStubServer(
            protocolVersion: protocolVersion, finalText: finalText, ranOverride: ranOverride,
            termsAnswerableInApp: termsAnswerableInApp)
        try stub.start()
        defer { stub.stop() }
        return try body(stub)
    }

    // MARK: - The invocations that never reach a host

    /// `--resume "$CHAT_ID"` with the variable UNSET. `args.value` reads an empty value
    /// as absent, so before the presence check this fell through to `.fresh` and minted
    /// a brand-new conversation, reported as a success — the exact thing `--resume`
    /// exists to prevent. It must exit 2 and run nothing.
    @Test("--resume with an empty value is a usage error, not a fresh conversation")
    func emptyResumeIsAUsageError() throws {
        let run = try runCLI(["-p", "hi", "--endpoint", "http://127.0.0.1:1", "--resume", ""])
        #expect(run.status == 2, "exited \(run.status): \(run.combined)")
        #expect(run.stderr.contains("--resume expects a chat id"))
    }

    /// The same hole one space wider: a variable holding whitespace.
    @Test("--resume with a whitespace-only value is a usage error", arguments: [" ", "\n"])
    func whitespaceResumeIsAUsageError(_ value: String) throws {
        let run = try runCLI(["-p", "hi", "--endpoint", "http://127.0.0.1:1", "--resume", value])
        #expect(run.status == 2, "exited \(run.status): \(run.combined)")
        #expect(run.stderr.contains("--resume expects a chat id"))
    }

    /// A chat id is a UUID. A host that cannot parse one falls back to the user's most
    /// recent chat, so a typo is a write into a conversation nobody named, reported as a
    /// successful resume — caught here, at parse time, one round trip earlier.
    @Test("--resume refuses a non-UUID", arguments: ["probe-me", "chat-42", "not a uuid"])
    func nonUUIDResumeIsAUsageError(_ value: String) throws {
        let run = try runCLI(["-p", "hi", "--endpoint", "http://127.0.0.1:1", "--resume", value])
        #expect(run.status == 2, "exited \(run.status): \(run.combined)")
        #expect(run.stderr.contains("--resume expects a chat id (a UUID)"))
    }

    @Test("-p with a help flag prints the help and contacts nothing", arguments: ["--help", "-h"])
    func promptHelpContactsNothing(_ flag: String) throws {
        try withStub(protocolVersion: 2) { stub in
            let run = try runTurn(["-p", flag], stub: stub)
            #expect(run.status == 0, "exited \(run.status): \(run.combined)")
            #expect(run.stdout.contains("-p <prompt>"), "\(run.combined)")
            #expect(stub.requests.isEmpty, "contacted \(stub.paths)")
        }
    }

    /// Two flags naming two different conversations. Silently preferring one would run
    /// the turn somewhere the caller did not ask for.
    @Test("--resume and --continue together are refused", arguments: [
        ["--resume", chatA, "--continue"],
        ["--continue", "--resume", chatA],
        ["--resume=\(chatA)", "--continue"],
    ])
    func resumeAndContinueTogetherAreRefused(_ session: [String]) throws {
        let run = try runCLI(["-p", "hi", "--endpoint", "http://127.0.0.1:1"] + session)
        #expect(run.status == 2, "exited \(run.status): \(run.combined)")
        #expect(run.stderr.contains("both name a conversation"))
    }

    /// `--resume` is a VALUE flag: it consumes the next token. Dropped from `valueFlags`
    /// it becomes a bare boolean and the id becomes a positional — so the bare flag must
    /// complain about a missing VALUE (the parser's message, not the session's), and a
    /// flag WITH a value must get past parsing into the turn (exit 1 on a dead endpoint,
    /// never 2).
    @Test("--resume consumes the following token")
    func resumeIsAValueFlag() throws {
        let bare = try runCLI(["-p", "hi", "--endpoint", "http://127.0.0.1:1", "--resume"])
        #expect(bare.status == 2, "exited \(bare.status): \(bare.combined)")
        #expect(bare.stderr.contains("--resume expects a value"), "\(bare.combined)")

        let withValue = try runCLI(
            ["-p", "hi", "--endpoint", "http://127.0.0.1:1", "--resume", Self.chatA, "--json"],
            timeout: 60)
        #expect(withValue.status == 1, "exited \(withValue.status): \(withValue.combined)")
        #expect(withValue.stdout.contains("transport error"))
    }

    // MARK: - What the flags actually put on the wire

    /// The default: a conversation is MINTED for this turn — `/agent/new` with no id.
    @Test("a bare -p asks the host to mint a conversation")
    func freshIsTheDefault() throws {
        try withStub { stub in
            let run = try runTurn(["-p", "two plus two"], stub: stub)
            #expect(run.status == 0, "exited \(run.status): \(run.combined)")
            #expect(stub.paths == ["/agent/lane", "/agent/new", "/agent/permissions", "/agent/task", "/agent/result"])
            #expect(stub.requests(path: "/agent/new").first?.body == "")
        }
    }

    /// `--resume <id>` names the conversation ON THE WIRE — hard-wire the session to
    /// `.fresh` and this body is empty instead, the mutation the old suite could not see.
    /// The id is normalized ONCE, here: trimmed (a shell variable arrives padded) and
    /// uppercased (the canonical spelling the host files chats under and echoes back —
    /// send the other one and the resume guard refuses a chat that was resumed correctly).
    @Test("--resume sends the trimmed, canonical id and nothing else")
    func resumeSendsTheCanonicalId() throws {
        try withStub { stub in
            let run = try runTurn(["-p", "and again", "--resume", "  \(Self.chatA)\t"], stub: stub)
            #expect(run.status == 0, "exited \(run.status): \(run.combined)")
            let body = try #require(stub.requests(path: "/agent/new").first?.body)
            #expect(body == #"{"sessionId":"\#(Self.chatA.uppercased())"}"#, "sent \(body)")
        }
    }

    /// `--continue` runs where the host already is. Under the legacy protocol that means
    /// moving no lane at all — and having chosen nothing, there is nothing to report.
    @Test("--continue moves no lane on a legacy host, and reports no id")
    func continueLeavesTheLegacyLaneAlone() throws {
        try withStub { stub in
            let run = try runTurn(["-p", "carry on", "--continue"], stub: stub)
            #expect(run.status == 0, "exited \(run.status): \(run.combined)")
            #expect(stub.requests(path: "/agent/new").isEmpty, "it moved the lane")
            #expect(stub.paths == ["/agent/lane", "/agent/permissions", "/agent/task", "/agent/result"])
            #expect(!run.stderr.contains("continue it with"))
        }
    }

    /// Against a protocol-2 host the same flag PINS the conversation the app was on and
    /// sends it explicitly, so the turn cannot land wherever the app drifted to — and the
    /// id becomes printable and resumable like any other.
    @Test("--continue pins and sends the host's conversation on a protocol-2 host")
    func continuePinsTheLaneOnProtocol2() throws {
        try withStub(protocolVersion: 2) { stub in
            let run = try runTurn(["-p", "carry on", "--continue"], stub: stub)
            #expect(run.status == 0, "exited \(run.status): \(run.combined)")
            #expect(stub.paths == ["/agent/lane", "/agent/run", "/agent/result"])
            let body = try #require(stub.requests(path: "/agent/run").first?.body)
            let object = try #require(try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
            #expect(object["conversation"] as? String == AgentStubServer.lane)
            #expect(object["prompt"] as? String == "carry on")
            #expect(run.stderr.contains("chat \(AgentStubServer.lane)"))
        }
    }

    /// A host that answers with a different conversation than the one asked for would
    /// have appended the turn somewhere else. It is refused, and the turn never starts.
    @Test("a host that ignores the requested id fails the turn before it runs")
    func aHostThatIgnoresTheIdIsRefused() throws {
        try withStub(ranOverride: "99999999-9999-4999-8999-999999999999") { stub in
            let run = try runTurn(["-p", "and again", "--resume", Self.chatA], stub: stub)
            #expect(run.status == 1, "exited \(run.status): \(run.combined)")
            #expect(run.stderr.contains(Self.chatA.uppercased()))
            #expect(stub.requests(path: "/agent/task").isEmpty, "the turn ran anyway")
        }
    }

    // MARK: - Which stream the id lands on

    /// STDOUT IS THE ANSWER. The conversation id is prose ABOUT the run, so it goes to
    /// stderr — `alohajet -p … > answer.txt` must capture the answer and nothing else.
    @Test("the answer goes to stdout and the conversation id to stderr")
    func theIdIsOnStderrNotStdout() throws {
        try withStub(finalText: "Four.") { stub in
            let run = try runTurn(["-p", "two plus two"], stub: stub)
            #expect(run.status == 0, "exited \(run.status): \(run.combined)")
            #expect(run.stdout == "Four.\n", "stdout was \(run.stdout.debugDescription)")
            #expect(!run.stdout.contains(AgentStubServer.minted), "the id leaked into the piped answer")
            #expect(run.stderr.contains("chat \(AgentStubServer.minted)"))
            #expect(run.stderr.contains("--resume \(AgentStubServer.minted)"))
        }
    }

    /// `--json` is the other surface: ONE object on stdout carrying the id as a field, so
    /// a harness never parses prose off stderr — and the prose is not printed twice.
    @Test("--json carries the id as a field and leaves stderr clean of it")
    func jsonReportsTheIdOnStdout() throws {
        try withStub { stub in
            let run = try runTurn(["-p", "two plus two", "--json"], stub: stub)
            #expect(run.status == 0, "exited \(run.status): \(run.combined)")
            let object = try #require(
                try JSONSerialization.jsonObject(with: Data(run.stdout.utf8)) as? [String: Any])
            #expect(object["sessionId"] as? String == AgentStubServer.minted)
            #expect(object["finalText"] as? String == "Four.")
            #expect(object["isSuccess"] as? Bool == true)
            #expect(!run.stderr.contains("chat \(AgentStubServer.minted)"))
        }
    }

    // MARK: - Where the bearer token may go

    /// The loopback half of the confinement rule, end to end: a bearer token IS sent to
    /// an endpoint on this machine, on every request. (The half no socket can test — that
    /// the ambient token is withheld from a host that is NOT this machine — is pinned by
    /// `AutomationTokenTests`.)
    @Test("every agent request to a loopback endpoint carries the bearer token")
    func loopbackGetsTheToken() throws {
        try withStub { stub in
            _ = try runTurn(["-p", "two plus two"], stub: stub)
            #expect(!stub.requests.isEmpty)
            for request in stub.requests {
                #expect(request.authorization == "Bearer test-token",
                        "\(request.path) sent \(request.authorization ?? "nothing")")
            }
        }
    }

    /// Plaintext to a host that is not this machine is refused at argument-parse time —
    /// before any transport call, so no header can be built for it and the prompt cannot
    /// leave the machine in the clear either.
    @Test("a non-loopback plaintext --endpoint is refused", arguments: [
        "http://evil.example:8765",
        "http://127.0.0.1.evil.example",   // carries the prefix, is not this machine
        "http://192.168.1.9:8765",
    ])
    func nonLoopbackPlaintextIsRefused(_ endpoint: String) throws {
        let run = try runCLI(["-p", "hi", "--endpoint", endpoint])
        #expect(run.status == 2, "exited \(run.status): \(run.combined)")
        #expect(run.stderr.contains("must be loopback http or https"))
        #expect(run.stderr.contains("provider API key"))
    }

    /// …and the spellings that ARE allowed still reach the turn (exit 1 on a dead port),
    /// so the rule narrows the endpoint check without breaking it.
    @Test("loopback http and https are accepted", arguments: [
        "http://127.0.0.1:1", "http://localhost:1", "http://[::1]:1", "https://example.invalid",
    ])
    func allowedEndpointsReachTheTurn(_ endpoint: String) throws {
        let run = try runCLI(["-p", "hi", "--endpoint", endpoint, "--json"], timeout: 60)
        #expect(run.status == 1, "exited \(run.status): \(run.combined)")
        #expect(!run.stderr.contains("must be loopback"))
    }

    static let declined = "The Terms of Service and the Privacy Policy were not accepted; the model was not asked.\n"
    static let inTheApp = "Accept the Terms of Service and the Privacy Policy in the app window to continue.\n"
    static let prompt = "To continue, accept the Terms of Service (\(AgentStubServer.termsUrl))"
        + " and the Privacy Policy (\(AgentStubServer.privacyUrl)).\nAccept? [y/N] "

    private func termsAnswer(_ stub: AgentStubServer) throws -> (request: AgentStubServer.Request, accept: Bool?) {
        let answers = stub.requests(path: "/agent/terms")
        #expect(answers.count == 1, "\(answers.count) answers")
        let request = try #require(answers.first)
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(request.body.utf8)) as? [String: Any])
        #expect(object["id"] as? String == AgentStubServer.termsId)
        return (request, object["accept"] as? Bool)
    }

    @Test("terms the app window cannot answer are declined from a pipe, and the turn says so")
    func termsDeclinedWithoutAWindow() throws {
        try withStub(protocolVersion: 2, termsAnswerableInApp: false) { stub in
            let run = try runTurn(["-p", "hi"], stub: stub)
            #expect(run.status == 1, "exited \(run.status): \(run.combined)")
            #expect(run.stderr.hasSuffix(Self.declined), "\(run.stderr)")
            #expect(run.stdout.isEmpty)
            let answer = try termsAnswer(stub)
            #expect(answer.request.method == "POST")
            #expect(answer.request.contentType == "application/json")
            #expect(answer.request.authorization == "Bearer test-token")
            #expect(answer.accept == false)
        }
    }

    @Test("terms the app window can answer are left to it when stdin is a pipe")
    func termsLeftToTheAppWindow() throws {
        try withStub(protocolVersion: 2, termsAnswerableInApp: true) { stub in
            let run = try runTurn(["-p", "hi"], stub: stub)
            #expect(run.status == 0, "exited \(run.status): \(run.combined)")
            #expect(run.stdout == "Four.\n")
            #expect(run.stderr.components(separatedBy: Self.inTheApp).count == 2, "\(run.stderr)")
            #expect(stub.requests(path: "/agent/terms").isEmpty)
        }
    }

#if canImport(Darwin)
    @Test("a terminal answers the terms prompt", arguments: [("y\n", true), ("YES\n", true), ("n\n", false), ("\n", false)])
    func terminalAnswersTheTerms(input: String, accept: Bool) throws {
        try withStub(protocolVersion: 2, termsAnswerableInApp: false) { stub in
            let run = try runTurn(["-p", "hi"], stub: stub, terminal: input)
            #expect(run.status == (accept ? 0 : 1), "exited \(run.status): \(run.combined)")
            #expect(run.stderr.hasPrefix(Self.prompt), "\(run.stderr)")
            #expect(try termsAnswer(stub).accept == accept)
            #expect(run.stderr.hasSuffix(Self.declined) != accept, "\(run.stderr)")
        }
    }

    @Test("a terms prompt answered in the app window is closed and posts nothing")
    func terminalPromptAnsweredInTheApp() throws {
        try withStub(protocolVersion: 2, termsAnswerableInApp: true) { stub in
            let run = try runTurn(["-p", "hi"], stub: stub, terminal: "")
            #expect(run.status == 0, "exited \(run.status): \(run.combined)")
            #expect(run.stdout == "Four.\n")
            #expect(run.stderr.hasPrefix(Self.prompt + "\n"), "\(run.stderr)")
            #expect(stub.requests(path: "/agent/terms").isEmpty)
        }
    }
#endif
}
