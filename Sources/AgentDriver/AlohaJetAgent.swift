#if os(Linux)
import Foundation
import Glibc

// MARK: - On Linux, the agent host is `alohajet-agent`
//
// There is no Aloha app to launch and nothing serves its automation port, so `-p` and
// `mcp-stdio` cannot reach an agent the way they do on macOS. The alohajet package's own
// CLI, `alohajet-agent`, ships beside this binary and is that agent: `-p` runs the turn
// in-process against a headless Chromium, and `mcp` serves the app's MCP server on stdio.
// This process BECOMES it — exec, not spawn — so the agent's stdio, its exit status and
// every signal sent to the pid the caller holds reach it with nothing in between.

/// The sibling `alohajet-agent`: what it is handed, where it is, and the handoff itself.
public enum AlohaJetAgent {
    /// Why the flags cannot be handed to the agent. The message is the whole of it, and
    /// the caller owns the exit code.
    public struct FlagError: Error, Equatable {
        public let message: String
    }

    /// Why there is no agent to hand off to.
    public struct HostError: Error, Equatable {
        public let message: String
    }

    /// Replaces this process image with `path`, `argv[0]` included. Returns only when it
    /// could not, with the `errno` that says why. Production is ``liveExec``.
    public typealias Exec = @Sendable (_ path: String, _ argv: [String]) -> Int32

    public nonisolated static let executableName = "alohajet-agent"
    public nonisolated static let pathEnvKey = "ALOHAJET_AGENT_BIN"

    /// `alohajet -p <prompt>` as `alohajet-agent -p <prompt>`.
    ///
    /// `headless` is the agent's default and is not forwarded. A conversation and a page
    /// permission are the app's: the agent keeps neither, so a flag asking for one is
    /// refused rather than dropped.
    public static func turnArguments(
        prompt: String, json: Bool = false, headless: Bool = false, noHeadless: Bool = false,
        acceptTerms: Bool = false, resume: Bool = false, continueLast: Bool = false,
        grantPermissions: String? = nil
    ) -> Result<[String], FlagError> {
        if headless, noHeadless { return .failure(bothWindowModes) }
        if resume { return .failure(needsConversations("--resume")) }
        if continueLast { return .failure(needsConversations("--continue")) }
        if let grantPermissions, grantPermissions != "none" {
            let shown = grantPermissions.isEmpty ? "\"\"" : grantPermissions
            return .failure(FlagError(message: """
                --grant-permissions \(shown) needs the Aloha app on macOS, which grants page \
                permissions; alohajet-agent grants the page none
                """))
        }
        return .success(["-p", prompt] + (json ? ["--json"] : []) + (noHeadless ? ["--no-headless"] : [])
            + (acceptTerms ? ["--accept-terms"] : []))
    }

    /// `alohajet mcp-stdio` as `alohajet-agent mcp`.
    public static func mcpArguments(headless: Bool = false, noHeadless: Bool = false) -> Result<[String], FlagError> {
        if headless, noHeadless { return .failure(bothWindowModes) }
        return .success(["mcp"] + (noHeadless ? ["--no-headless"] : []))
    }

    private static let bothWindowModes = FlagError(message: "--headless and --no-headless: pass one")

    private static func needsConversations(_ flag: String) -> FlagError {
        FlagError(message: """
            \(flag) needs the Aloha app on macOS, which keeps conversations; alohajet-agent \
            starts a new one for every -p
            """)
    }

    /// `ALOHAJET_AGENT_BIN` when it names one, else the `alohajet-agent` beside the file
    /// `executable` resolves to — an install that links `alohajet` onto PATH keeps the
    /// pair together somewhere else, and the agent beside the link is not this one's.
    public static func path(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        executable: String = "/proc/self/exe"
    ) -> Result<String, HostError> {
        if let override = environment[pathEnvKey], !override.isEmpty {
            guard override.hasPrefix("/") else {
                return .failure(HostError(
                    message: "\(pathEnvKey) must be an absolute path to \(executableName) — got \"\(override)\""))
            }
            guard isExecutableFile(override) else {
                return .failure(HostError(message: "\(pathEnvKey) names \(override), which is not an executable file"))
            }
            guard !isSameFile(override, executable) else {
                return .failure(HostError(
                    message: "\(pathEnvKey) names \(override), which is alohajet itself, not \(executableName)"))
            }
            return .success(override)
        }
        guard let resolved = realpath(executable, nil) else {
            let reason = String(cString: strerror(errno))
            return .failure(HostError(message: """
                could not resolve \(executable) to look for \(executableName) beside it (\(reason)) \
                — set \(pathEnvKey) to its absolute path
                """))
        }
        defer { free(resolved) }
        let sibling = ((String(cString: resolved) as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent(executableName)
        guard isExecutableFile(sibling) else {
            return .failure(HostError(message: """
                no \(executableName) at \(sibling) — it ships beside alohajet; install it there, \
                or set \(pathEnvKey) to its absolute path
                """))
        }
        guard !isSameFile(sibling, executable) else {
            return .failure(HostError(message: """
                \(sibling) is alohajet itself, not \(executableName) — install \(executableName) there, \
                or set \(pathEnvKey) to its absolute path
                """))
        }
        return .success(sibling)
    }

    /// Become the agent, handed `arguments`. On success this process image is gone, so the
    /// only way out of this function is the error saying why it is still here.
    public static func handOff(
        _ arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        executable: String = "/proc/self/exe",
        exec: Exec = liveExec
    ) throws(HostError) -> Never {
        let agent = try path(environment: environment, executable: executable).get()
        let failure = exec(agent, [agent] + arguments)
        throw HostError(message: "could not run \(agent): \(String(cString: strerror(failure)))")
    }

    /// `execv`, with every signal unblocked and SIGPIPE back at its default first. An exec
    /// keeps the signal mask and every ignored signal: this CLI ignores SIGPIPE itself, and
    /// a parent that spawned it from a dispatch worker — Foundation's `Process` on Linux
    /// does, so an MCP host written in Swift can — hands it nearly every signal blocked.
    /// An agent exec'd as-is would start deaf to SIGINT and SIGTERM, and its host could
    /// not stop it.
    public nonisolated static let liveExec: Exec = { path, argv in
        var unblocked = sigset_t()
        var mask = sigset_t()
        sigemptyset(&unblocked)
        pthread_sigmask(SIG_SETMASK, &unblocked, &mask)
        let pipeDisposition = signal(SIGPIPE, SIG_DFL)
        let pointers = argv.map { strdup($0) } + [nil]
        execv(path, pointers)
        let failure = errno
        signal(SIGPIPE, pipeDisposition)
        pthread_sigmask(SIG_SETMASK, &mask, nil)
        pointers.forEach { free($0) }
        return failure
    }

    private nonisolated static func isSameFile(_ first: String, _ second: String) -> Bool {
        var one = stat()
        var other = stat()
        return stat(first, &one) == 0 && stat(second, &other) == 0
            && one.st_dev == other.st_dev && one.st_ino == other.st_ino
    }

    private nonisolated static func isExecutableFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }
}
#endif
