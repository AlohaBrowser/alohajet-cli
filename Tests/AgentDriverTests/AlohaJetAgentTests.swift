#if os(Linux)
import Testing
import Foundation
@testable import AgentDriver

@Suite("AlohaJetAgent")
final class AlohaJetAgentTests {

    private let scratch: URL

    init() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("alohajet-agent-lookup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: scratch) }

    private func directory(_ name: String) throws -> URL {
        let url = scratch.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func executable(_ url: URL, mode: Int = 0o755) throws -> String {
        try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        return url.path
    }

    // MARK: - What the agent is handed

    struct Turn: Sendable, CustomTestStringConvertible {
        var json = false, headless = false, noHeadless = false, acceptTerms = false
        var grantPermissions: String?
        var outcome: String?
        let expected: [String]
        var testDescription: String { expected.joined(separator: " ") }
    }

    @Test("-p maps onto alohajet-agent -p, flag by flag", arguments: [
        Turn(expected: ["-p", "book a table"]),
        Turn(json: true, expected: ["-p", "book a table", "--json"]),
        Turn(noHeadless: true, expected: ["-p", "book a table", "--no-headless"]),
        Turn(acceptTerms: true, expected: ["-p", "book a table", "--accept-terms"]),
        Turn(headless: true, expected: ["-p", "book a table"]),
        Turn(grantPermissions: "none", expected: ["-p", "book a table"]),
        Turn(json: true, noHeadless: true, acceptTerms: true,
             expected: ["-p", "book a table", "--json", "--no-headless", "--accept-terms"]),
        Turn(outcome: "success", expected: ["-p", "book a table", "--outcome", "success"]),
        Turn(outcome: "Failure", expected: ["-p", "book a table", "--outcome", "failure"]),
        Turn(noHeadless: true, acceptTerms: true, outcome: "skip",
             expected: ["-p", "book a table", "--no-headless", "--accept-terms", "--outcome", "skip"]),
    ])
    func turnArguments(_ turn: Turn) {
        #expect(AlohaJetAgent.turnArguments(
            prompt: "book a table", json: turn.json, headless: turn.headless,
            noHeadless: turn.noHeadless, acceptTerms: turn.acceptTerms,
            grantPermissions: turn.grantPermissions, outcome: turn.outcome) == .success(turn.expected))
    }

    @Test("a verdict that is not success, failure or skip is refused", arguments: ["done", "", "succeeded"])
    func unknownVerdictsAreRefused(_ value: String) {
        let shown = value.isEmpty ? "\"\"" : value
        #expect(AlohaJetAgent.turnArguments(prompt: "hi", outcome: value) == .failure(.init(
            message: "--outcome expects success, failure or skip, not \(shown)")))
    }

    @Test("--outcome with --json is refused: --json reports no verdict")
    func outcomeWithJSONIsRefused() {
        #expect(AlohaJetAgent.turnArguments(prompt: "hi", json: true, outcome: "success") == .failure(.init(
            message: "--outcome and --json: --json reports no verdict; pass one")))
    }

    @Test("a prompt that looks like a flag is still the prompt")
    func promptIsAlwaysTheValueOfP() {
        #expect(AlohaJetAgent.turnArguments(prompt: "--json") == .success(["-p", "--json"]))
    }

    @Test("mcp-stdio maps onto alohajet-agent mcp, which takes the window mode alone")
    func mcpArguments() {
        #expect(AlohaJetAgent.mcpArguments() == .success(["mcp"]))
        #expect(AlohaJetAgent.mcpArguments(headless: true) == .success(["mcp"]))
        #expect(AlohaJetAgent.mcpArguments(noHeadless: true) == .success(["mcp", "--no-headless"]))
    }

    // MARK: - What only the macOS app can do

    @Test("a conversation to resume needs the macOS app")
    func conversationsAreRefused() {
        for (result, flag) in [
            (AlohaJetAgent.turnArguments(prompt: "hi", resume: true), "--resume"),
            (AlohaJetAgent.turnArguments(prompt: "hi", continueLast: true), "--continue"),
        ] {
            guard case let .failure(error) = result else {
                Issue.record("\(flag) was handed to the agent")
                continue
            }
            #expect(error.message == "\(flag) needs the Aloha app on macOS, which keeps conversations;"
                + " alohajet-agent starts a new one for every -p")
        }
    }

    @Test("a page permission needs the macOS app; none is the agent's own default",
          arguments: ["camera", "all", "camera,none", "", "None"])
    func permissionsAreRefused(_ value: String) {
        let shown = value.isEmpty ? "\"\"" : value
        #expect(AlohaJetAgent.turnArguments(prompt: "hi", grantPermissions: value) == .failure(.init(
            message: "--grant-permissions \(shown) needs the Aloha app on macOS, which grants page"
                + " permissions; alohajet-agent grants the page none")))
    }

    @Test("--headless with --no-headless is refused rather than one silently winning")
    func bothWindowModesAreRefused() {
        let refusal = AlohaJetAgent.FlagError(message: "--headless and --no-headless: pass one")
        #expect(AlohaJetAgent.turnArguments(prompt: "hi", headless: true, noHeadless: true) == .failure(refusal))
        #expect(AlohaJetAgent.mcpArguments(headless: true, noHeadless: true) == .failure(refusal))
    }

    // MARK: - Which alohajet-agent

    @Test("the agent is the alohajet-agent beside this executable")
    func siblingOfTheExecutable() throws {
        let install = try directory("install")
        let cli = try executable(install.appendingPathComponent("alohajet"))
        let agent = try executable(install.appendingPathComponent("alohajet-agent"))
        #expect(AlohaJetAgent.path(environment: [:], executable: cli) == .success(agent))
    }

    @Test("a symlinked executable's agent is looked for beside the file it resolves to")
    func siblingOfTheResolvedExecutable() throws {
        let install = try directory("install")
        let cli = try executable(install.appendingPathComponent("alohajet"))
        let agent = try executable(install.appendingPathComponent("alohajet-agent"))
        let onPath = try directory("bin")
        try executable(onPath.appendingPathComponent("alohajet-agent"))
        let link = onPath.appendingPathComponent("alohajet").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: cli)

        #expect(AlohaJetAgent.path(environment: [:], executable: link) == .success(agent))
    }

    @Test("this process's own path comes from /proc/self/exe")
    func defaultExecutableIsThisProcess() throws {
        let running = try FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe")
        let beside = (running as NSString).deletingLastPathComponent + "/alohajet-agent"
        try #require(!FileManager.default.fileExists(atPath: beside), "\(beside) exists")
        guard case let .failure(error) = AlohaJetAgent.path(environment: [:]) else {
            Issue.record("found an alohajet-agent beside the test runner")
            return
        }
        #expect(error.message.contains(beside), "\(error.message)")
    }

    @Test("a missing agent is named, with where it ships and the variable that overrides it")
    func missingSiblingIsNamed() throws {
        let lonely = try directory("lonely")
        let cli = try executable(lonely.appendingPathComponent("alohajet"))
        let expected = lonely.appendingPathComponent("alohajet-agent").path
        #expect(AlohaJetAgent.path(environment: [:], executable: cli) == .failure(.init(message:
            "no alohajet-agent at \(expected) — it ships beside alohajet; install it there,"
                + " or set ALOHAJET_AGENT_BIN to its absolute path")))

        try FileManager.default.createDirectory(atPath: expected, withIntermediateDirectories: true)
        #expect(AlohaJetAgent.path(environment: [:], executable: cli) == .failure(.init(message:
            "no alohajet-agent at \(expected) — it ships beside alohajet; install it there,"
                + " or set ALOHAJET_AGENT_BIN to its absolute path")), "a directory is not an agent")
    }

    @Test("an executable whose path cannot be resolved says so")
    func unresolvableExecutable() {
        let gone = scratch.appendingPathComponent("gone/alohajet").path
        guard case let .failure(error) = AlohaJetAgent.path(environment: [:], executable: gone) else {
            Issue.record("resolved a path that does not exist")
            return
        }
        #expect(error.message.hasPrefix("could not resolve \(gone) to look for alohajet-agent beside it"))
        #expect(error.message.hasSuffix("— set ALOHAJET_AGENT_BIN to its absolute path"))
    }

    @Test("ALOHAJET_AGENT_BIN wins over the sibling, and an empty one names nothing")
    func overrideWins() throws {
        let install = try directory("install")
        let cli = try executable(install.appendingPathComponent("alohajet"))
        let sibling = try executable(install.appendingPathComponent("alohajet-agent"))
        let elsewhere = try executable(try directory("opt").appendingPathComponent("agent-build"))

        #expect(AlohaJetAgent.path(environment: ["ALOHAJET_AGENT_BIN": elsewhere], executable: cli)
            == .success(elsewhere))
        #expect(AlohaJetAgent.path(environment: ["ALOHAJET_AGENT_BIN": ""], executable: cli)
            == .success(sibling))
    }

    @Test("an ALOHAJET_AGENT_BIN that is relative or names no executable is refused")
    func unusableOverride() throws {
        let cli = try executable(try directory("install").appendingPathComponent("alohajet"))
        #expect(AlohaJetAgent.path(environment: ["ALOHAJET_AGENT_BIN": "bin/alohajet-agent"], executable: cli)
            == .failure(.init(message:
                "ALOHAJET_AGENT_BIN must be an absolute path to alohajet-agent — got \"bin/alohajet-agent\"")))

        let notExecutable = try executable(scratch.appendingPathComponent("plain"), mode: 0o644)
        for path in [notExecutable, scratch.path, scratch.appendingPathComponent("absent").path] {
            #expect(AlohaJetAgent.path(environment: ["ALOHAJET_AGENT_BIN": path], executable: cli)
                == .failure(.init(message: "ALOHAJET_AGENT_BIN names \(path), which is not an executable file")))
        }
    }

    @Test("an agent that is this alohajet is refused: it would hand off to itself forever")
    func thisExecutableIsNotTheAgent() throws {
        let install = try directory("install")
        let cli = try executable(install.appendingPathComponent("alohajet"))
        let sibling = install.appendingPathComponent("alohajet-agent").path
        try FileManager.default.createSymbolicLink(atPath: sibling, withDestinationPath: "alohajet")
        #expect(AlohaJetAgent.path(environment: [:], executable: cli) == .failure(.init(message:
            "\(sibling) is alohajet itself, not alohajet-agent — install alohajet-agent there,"
                + " or set ALOHAJET_AGENT_BIN to its absolute path")))

        let hardLink = try directory("opt").appendingPathComponent("alohajet-agent").path
        try FileManager.default.linkItem(atPath: cli, toPath: hardLink)
        let onPath = try directory("bin").appendingPathComponent("alohajet").path
        try FileManager.default.createSymbolicLink(atPath: onPath, withDestinationPath: cli)
        for override in [cli, hardLink] {
            #expect(AlohaJetAgent.path(environment: ["ALOHAJET_AGENT_BIN": override], executable: onPath)
                == .failure(.init(message:
                    "ALOHAJET_AGENT_BIN names \(override), which is alohajet itself, not alohajet-agent")))
        }

        let spy = ExecSpy(failure: 0)
        #expect(throws: AlohaJetAgent.HostError.self) {
            try AlohaJetAgent.handOff(["-p", "hi"], environment: [:], executable: cli, exec: { spy.exec($0, $1) })
        }
        #expect(spy.calls.isEmpty)
    }

    // MARK: - The handoff

    nonisolated final class ExecSpy: @unchecked Sendable {
        private(set) var calls: [(path: String, argv: [String])] = []
        let failure: Int32
        init(failure: Int32) { self.failure = failure }
        func exec(_ path: String, _ argv: [String]) -> Int32 {
            calls.append((path, argv))
            return failure
        }
    }

    @Test("the handoff execs the agent with itself as argv[0], and a failed exec names it")
    func handOffExecsTheAgent() throws {
        let install = try directory("install")
        let cli = try executable(install.appendingPathComponent("alohajet"))
        let agent = try executable(install.appendingPathComponent("alohajet-agent"))
        let spy = ExecSpy(failure: ENOEXEC)

        let error = #expect(throws: AlohaJetAgent.HostError.self) {
            try AlohaJetAgent.handOff(["-p", "hi", "--json"], environment: [:], executable: cli,
                                      exec: { spy.exec($0, $1) })
        }
        #expect(spy.calls.count == 1)
        #expect(spy.calls.first?.path == agent)
        #expect(spy.calls.first?.argv == [agent, "-p", "hi", "--json"])
        #expect(error?.message == "could not run \(agent): \(String(cString: strerror(ENOEXEC)))")
    }

    @Test("no agent, no exec")
    func handOffWithoutAnAgentExecsNothing() throws {
        let cli = try executable(try directory("lonely").appendingPathComponent("alohajet"))
        let spy = ExecSpy(failure: 0)
        let error = #expect(throws: AlohaJetAgent.HostError.self) {
            try AlohaJetAgent.handOff(["mcp"], environment: [:], executable: cli, exec: { spy.exec($0, $1) })
        }
        #expect(spy.calls.isEmpty)
        #expect(error?.message.hasPrefix("no alohajet-agent at ") == true)
    }
}
#endif
