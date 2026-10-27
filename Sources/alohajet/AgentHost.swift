#if os(Linux)
import AgentDriver
import Foundation
import ToolABI

/// Unlisted, `camera` in `--grant-permissions camera` would parse as the command.
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
