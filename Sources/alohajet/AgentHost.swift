#if os(Linux)
import AgentDriver
import Foundation
import ToolABI

// MARK: - `alohajet -p` / `mcp-stdio` with no `--endpoint`, on Linux
//
// The rules — what the agent is handed, which flags it cannot honour, where it is — are
// `AlohaJetAgent`'s, in the library, where a test can reach them. This reads argv and
// maps a refusal onto the usage exit code and a missing agent onto the unreachable one.

/// The flags only the agent handoff reads: `--grant-permissions` takes a value, and the
/// parser must know that before a stray `camera` becomes a command.
let agentHostValueFlags: Set<String> = ["--grant-permissions"]

enum AgentHost {

    static func turn(_ args: Args, prompt: String) -> Int32 {
        handOff(AlohaJetAgent.turnArguments(
            prompt: prompt, json: args.has("--json"), headless: args.has("--headless"),
            noHeadless: args.has("--no-headless"), acceptTerms: args.has("--accept-terms"),
            resume: args.has("--resume"), continueLast: args.has("--continue"),
            grantPermissions: args.flags["--grant-permissions"]))
    }

    static func mcp(_ args: Args) -> Int32 {
        if let refusal = refuseAcceptTermsOnMCP(args) {
            writeToStandardError("alohajet: \(refusal.message)\n")
            return refusal.code
        }
        return handOff(AlohaJetAgent.mcpArguments(
            headless: args.has("--headless"), noHeadless: args.has("--no-headless")))
    }

    /// What `--endpoint` cannot carry. The agent there keeps its own window, and the
    /// protocol-2 client sends no page permissions, so a flag asking for either would be
    /// dropped and the turn would run as though it had been honoured.
    static func refuseOverEndpoint(_ args: Args, endpoint: URL) -> CLIError? {
        if args.has("--no-headless") {
            return CLIError(
                message: "the agent at \(endpoint.absoluteString) decides its own window: drop --no-headless",
                code: exitUsage)
        }
        if let permissions = args.flags["--grant-permissions"], permissions != "none" {
            let shown = permissions.isEmpty ? "\"\"" : permissions
            return CLIError(message: """
                -p sends no page permissions to the agent at \(endpoint.absoluteString): \
                drop --grant-permissions \(shown)
                """, code: exitUsage)
        }
        return nil
    }

    private static func handOff(_ arguments: Result<[String], AlohaJetAgent.FlagError>) -> Int32 {
        switch arguments {
        case let .failure(error):
            writeToStandardError("alohajet: \(error.message)\n")
            return exitUsage
        case let .success(arguments):
            do {
                try AlohaJetAgent.handOff(arguments)
            } catch {
                writeToStandardError("alohajet: \(error.message)\n")
                return exitUnreachable
            }
        }
    }
}
#endif
