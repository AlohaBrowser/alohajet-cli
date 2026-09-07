import Testing
import Foundation
@testable import AgentDriver

// MARK: - Where the bearer token is allowed to go
//
// The credential under test grants `/agent/task`, `/agent/config` — which REWRITES the
// user's LLM provider key — and `/quit`. Before this it was attached to whatever
// `--endpoint` named, so a stub listening anywhere collected it. The rule now: the
// AMBIENT token (the file the browser provisioned, which the user never typed) goes to
// a loopback endpoint and nowhere else; a non-loopback endpoint is served only by
// `ALOHAJET_AGENT_TOKEN`, which someone had to set on purpose.

@Suite("AutomationToken confinement")
struct AutomationTokenTests {

    /// A token file no test may share, written 0600 like the real one.
    private func tokenFile(_ contents: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("alohajet-token-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("automation-token")
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func url(_ string: String) throws -> URL { try #require(URL(string: string)) }

    @Test("the file token is sent to every loopback spelling", arguments: [
        "http://127.0.0.1:8765", "http://127.0.0.53:8765", "http://localhost:8765",
        "http://LOCALHOST:8765", "http://[::1]:8765", "https://127.0.0.1:8765",
    ])
    func fileTokenReachesLoopback(_ endpoint: String) throws {
        let file = try tokenFile("secret-abc\n")
        #expect(AutomationToken.read(for: try url(endpoint), at: file, environment: [:]) == "secret-abc")
    }

    // THE HAZARD. A stub on a host that is not this machine used to receive the real
    // credential just by being named in --endpoint.
    @Test("the file token is NEVER sent off this machine", arguments: [
        "https://evil.example:8765", "http://evil.example:8765",
        "https://127.0.0.1.evil.example",           // carries the prefix, is not loopback
        "https://127.0.0.1@evil.example",           // userinfo, not a host
        "https://2130706433", "https://0177.0.0.1", // integer/octal spellings: not parsed, so denied
        "https://example.com/agent",
    ])
    func fileTokenIsConfinedToLoopback(_ endpoint: String) throws {
        let file = try tokenFile("secret-abc\n")
        #expect(AutomationToken.read(for: try url(endpoint), at: file, environment: [:]) == nil)
    }

    // The escape hatch, and the only one: an env var is a deliberate act.
    @Test("an explicit ALOHAJET_AGENT_TOKEN is sent anywhere")
    func environmentTokenIsNotConfined() throws {
        let file = try tokenFile("from-the-file")
        let environment = [AutomationToken.environmentVariable: "typed-on-purpose"]
        #expect(AutomationToken.read(for: try url("https://evil.example"), at: file, environment: environment)
                == "typed-on-purpose")
        // …and it still wins over the file on loopback.
        #expect(AutomationToken.read(for: try url("http://127.0.0.1:8765"), at: file, environment: environment)
                == "typed-on-purpose")
    }

    @Test("an empty or whitespace-only secret is no secret")
    func emptySecretsReadAsAbsent() throws {
        let file = try tokenFile("   \n")
        let loopback = try url("http://127.0.0.1:8765")
        #expect(AutomationToken.read(for: loopback, at: file, environment: [:]) == nil)
        #expect(AutomationToken.read(for: loopback, at: file,
                                     environment: [AutomationToken.environmentVariable: "  "]) == nil)
    }

    @Test("no token file and no variable is no header, not an empty one")
    func absentEverywhereIsNil() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("alohajet-token-\(UUID().uuidString)/absent")
        #expect(AutomationToken.read(for: try url("http://127.0.0.1:8765"), at: missing, environment: [:]) == nil)
    }
}
