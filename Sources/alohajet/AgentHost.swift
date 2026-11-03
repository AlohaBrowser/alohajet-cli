#if os(Linux) || os(macOS)
import AgentDriver
import Foundation
import ToolABI

#if os(Linux)
/// Unlisted, `camera` in `--grant-permissions camera` would parse as the command.
let agentHostValueFlags: Set<String> = ["--grant-permissions", "--outcome"]
let agentHostTurnFlags = agentHostValueFlags.union(["--no-headless"])
#endif

enum AgentHost {

    #if os(Linux)
    static func turn(_ args: Args, prompt: String) -> Int32 {
        handOff(AlohaJetAgent.turnArguments(
            prompt: prompt, json: args.has("--json"), headless: args.has("--headless"),
            noHeadless: args.has("--no-headless"), acceptTerms: args.has("--accept-terms"),
            resume: args.has("--resume"), continueLast: args.has("--continue"),
            grantPermissions: args.flags["--grant-permissions"], outcome: args.flags["--outcome"]))
    }

    static func mcp(_ args: Args) -> Int32 {
        if let refusal = refuseAcceptTermsOnMCP(args) {
            writeToStandardError("alohajet: \(refusal.message)\n")
            return refusal.code
        }
        return handOff(AlohaJetAgent.mcpArguments(
            headless: args.has("--headless"), noHeadless: args.has("--no-headless")))
    }
    #endif

    /// `alohajet mcp` with no `--endpoint`. The agent's server completes the verification
    /// checks these tools cannot, on a Chromium of its own, so it is the one served whenever
    /// it is installed — unless the caller named a browser for these tools, or chose them
    /// with `--browser-only`.
    static func serveMCP(_ args: Args) async -> Int32 {
        guard !args.has("--browser-only"), !namesABrowser(args) else { return await MCPServer.main(args) }
        switch AlohaJetAgent.installation() {
        case let .failure(error):
            writeToStandardError("alohajet: \(error.message)\n")
            return exitUnreachable
        case let .success(.notInstalled(expectedAt)):
            writeToStandardError("alohajet mcp: \(ownToolsNote(agentExpectedAt: expectedAt))\n")
            return await MCPServer.main(args)
        case let .success(.installed(agent)):
            if let refusal = refuseAcceptTermsOnMCP(args) {
                writeToStandardError("alohajet: \(refusal.message)\n")
                return refusal.code
            }
            switch AlohaJetAgent.mcpArguments(headless: args.has("--headless"), noHeadless: args.has("--no-headless")) {
            case let .failure(error):
                writeToStandardError("alohajet: \(error.message)\n")
                return exitUsage
            case let .success(arguments):
                do {
                    try AlohaJetAgent.handOff(to: agent, arguments)
                } catch {
                    writeToStandardError("alohajet: \(error.message)\n")
                    return exitUnreachable
                }
            }
        }
    }

    private static func namesABrowser(_ args: Args) -> Bool {
        args.has("--cdp") || args.has("--launch") || args.has("--port")
            || (args.has("--browser") && args.value("--browser") != "chromium")
    }

    private static func ownToolsNote(agentExpectedAt: String) -> String {
        #if os(Linux)
        """
        no alohajet-agent at \(agentExpectedAt), so this serves the browser tools alone, and they \
        complete no verification check (CAPTCHA); install alohajet-agent there or set \
        ALOHAJET_AGENT_BIN to serve its tools, which do, or pass --browser-only to choose these
        """
        #else
        """
        this serves the browser tools alone, and they complete no verification check (CAPTCHA); \
        the Aloha browser's own MCP server does, through mcp --endpoint <url>; pass --browser-only \
        to choose these
        """
        #endif
    }

    #if os(Linux)
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
        if args.has("--outcome") {
            return CLIError(
                message: "-p reports no verdict to the agent at \(endpoint.absoluteString): drop --outcome",
                code: exitUsage)
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
    #endif
}
#endif
