// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "alohajet",
    platforms: [
        // macOS 14 is the floor the sources were written and tested against.
        // Linux is supported too — `Sources/CDP/LinuxWebSocketChannel.swift` is
        // the raw-POSIX transport Foundation's `URLSessionWebSocketTask` cannot
        // provide off-Apple — but SwiftPM's `platforms` only constrains Apple
        // deployment targets, so there is nothing to declare for it here.
        .macOS(.v14)
    ],
    products: [
        .library(name: "BrowserTools", targets: ["BrowserTools"]),
        .library(name: "AgentDriver", targets: ["AgentDriver"]),
        // The two lower layers are products because consumers name their types
        // directly, not merely through `BrowserTools`: `BrowserToolSession.client`
        // is public and typed `CDPClient`, and a host implements the ToolABI
        // protocols (`TabsService`, `ExecutorSession`, `ExecutorTool`) itself.
        // Depending on `BrowserTools` alone does put both modules on the search
        // path, so `import CDP` compiles today — but that is SwiftPM leaking a
        // transitive target, not a promise, and it breaks the moment SwiftPM
        // tightens it.
        .library(name: "ToolABI", targets: ["ToolABI"]),
        .library(name: "CDP", targets: ["CDP"]),
        .executable(name: "alohajet", targets: ["alohajet-cli"]),
    ],
    dependencies: [
        // The OFFICIAL Model Context Protocol Swift SDK, linked by the EXECUTABLE
        // TARGET ONLY — `alohajet mcp --endpoint <url>` relays a stdio MCP client onto
        // a running Aloha browser's own `POST /mcp`. The four libraries above stay
        // dependency-free, which is what a consumer links; only the CLI pays for this.
        //
        // A RANGE, not `exact:`. An app that links this package and the SDK itself
        // normally pins the SDK `exact:`, and two `exact` requirements on one package
        // must name the same version forever — the second one to move breaks the
        // resolve for everyone. `from:` is satisfied by such a pin and does not have
        // to be edited in lockstep when it moves.
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk", from: "0.12.1"),
    ],
    targets: [
        // The tool ABI plus the two value types every layer exchanges
        // (`JSValue` for CDP params/results and tool arguments, `WorkflowValue`
        // for step inputs/outputs), the abort-signal cluster, and the logging
        // shim (`agentLogger`, `rootLogger`) every layer logs through.
        .target(name: "ToolABI"),

        // The Chrome DevTools Protocol client: the WebSocket transport, the
        // `/json` discovery endpoint, the Chrome launcher, and the attach seam.
        .target(name: "CDP", dependencies: ["ToolABI"]),

        // The runtime: the in-page scripts, the DOM walk and serializer, the
        // tab model over CDP, and the eight page tools.
        .target(name: "BrowserTools", dependencies: ["CDP", "ToolABI"]),

        // `alohajet -p <prompt>`: the seam an agent turn runs over, and the ONE
        // implementation of it this package ships — an HTTP client for an agent
        // loop that lives somewhere else. There is no in-process loop here and
        // there is not meant to be; the tool surface and the agent surface meet
        // at HTTP, not at a link edge.
        .target(name: "AgentDriver", dependencies: ["ToolABI"]),

        // The CLI, the MCP stdio server, and the stdio⇄HTTP relay. `MCP` stops HERE:
        // it is the one target in this package that links a dependency, and the four
        // libraries above are built and shipped without it.
        .executableTarget(
            name: "alohajet-cli",
            dependencies: [
                "BrowserTools", "AgentDriver",
                .product(name: "MCP", package: "swift-sdk"),
            ],
            path: "Sources/alohajet"),

        .testTarget(name: "CDPTests", dependencies: ["CDP"]),
        // Drives the built binary as a subprocess — see Tests/CLITests/BinaryUnderTest.swift.
        // The dependency is on the EXECUTABLE so `swift test` builds it first; nothing
        // in this target imports it.
        .testTarget(name: "CLITests", dependencies: ["alohajet-cli"]),
        .testTarget(name: "BrowserToolsTests", dependencies: ["BrowserTools"]),
        .testTarget(name: "AgentDriverTests", dependencies: ["AgentDriver"]),
    ]
)

// MARK: - Default isolation
//
// Every target runs on the main actor by default (SE-0466
// `defaultIsolation(MainActor.self)`), so its stored state — tab registries, the
// page bridge, the abort signals, the tool execution context — is main-isolated
// and carries neither locks nor `@unchecked Sendable`. The off-main perimeter
// opts out locally with `nonisolated`; dropping the default would mean auditing
// every one of those types for concurrent access instead.
//
// `CDP` is the one exception: it is an inherently off-main transport expressed
// as an `actor`, and `@MainActor` on it would force an actor hop onto every
// wire read.
// `CDPTests` and `CLITests` join it: both spend their time BLOCKED — one on sockets and
// process teardown, the other on a subprocess it drives over pipes. Left on the main
// actor they serialise against the library's own main-isolated tests, and the runtime's
// real wall-clock deadlines (the 18s wake, the 30s CDP backstop) then expire on tests
// that are merely waiting their turn.
let nonMainActorTargets: Set<String> = ["CDP", "CDPTests", "CLITests"]
for target in package.targets where !nonMainActorTargets.contains(target.name) {
    var settings = target.swiftSettings ?? []
    settings.append(.defaultIsolation(MainActor.self))
    target.swiftSettings = settings
}
