import Foundation
import BrowserTools
import ToolABI

// The CLI. One invocation = one command: connect, run exactly one tool call, print,
// disconnect. What it does NOT do any more is take the browser with it.
//
// Element refs (`aloha-id`) live in the page, so they survive exactly as long as the
// browser does. A lane that launched a Chromium per command and killed it on exit could
// therefore never run the second command anyone types — `open` printed refs that were
// already gone by the time `read`/`click` started. So the default lane launches ONE
// browser, records it in `browser.json` under the temp dir, and every later invocation
// attaches to it. It outlives us on purpose; `alohajet quit` is how it ends.
//
//   (default)  the shared browser: launched once, reused, ours to close
//   --launch   one throwaway browser for THIS command, terminated on exit
//   --cdp      someone else's browser: never launched, never terminated, never ours

// MARK: - Exit codes

let exitOK: Int32 = 0
let exitToolError: Int32 = 1
let exitUsage: Int32 = 2
let exitUnreachable: Int32 = 3

struct CLIError: Error {
    let message: String
    let code: Int32
}

// MARK: - Argument parsing

/// Flags that consume the following token. Everything else beginning with `-` is a
/// boolean; `--flag=value` works for any of them.
let valueFlags: Set<String> = [
    "--cdp", "--port", "--tab", "--text", "--index", "--timeout-ms", "--max-chars", "--browser",
    "-p", "--endpoint", "--resume"
]

struct Args {
    var positional: [String] = []
    var flags: [String: String] = [:]

    func has(_ name: String) -> Bool { flags[name] != nil }
    func value(_ name: String) -> String? { flags[name].flatMap { $0.isEmpty ? nil : $0 } }

    func int(_ name: String) throws -> Int? {
        guard let raw = value(name) else { return nil }
        guard let parsed = Int(raw) else {
            throw CLIError(message: "\(name) expects a number, got \"\(raw)\"", code: exitUsage)
        }
        return parsed
    }

    func required(_ index: Int, _ what: String) throws -> String {
        guard positional.count > index else {
            throw CLIError(message: "missing <\(what)>", code: exitUsage)
        }
        return positional[index]
    }
}

func parseArgs(_ argv: [String]) throws -> Args {
    var args = Args()
    var index = 0
    while index < argv.count {
        let token = argv[index]
        if token == "--" {
            // Everything after `--` is a positional, so `alohajet type <ref> -- -50%` works.
            args.positional.append(contentsOf: argv[(index + 1)...])
            break
        }
        if token.hasPrefix("-"), let equals = token.firstIndex(of: "=") {
            args.flags[String(token[token.startIndex..<equals])] = String(token[token.index(after: equals)...])
        } else if valueFlags.contains(token) {
            index += 1
            guard index < argv.count else {
                throw CLIError(message: "\(token) expects a value", code: exitUsage)
            }
            args.flags[token] = argv[index]
        } else if token.hasPrefix("-") && token != "-" {
            args.flags[token] = ""
        } else {
            args.positional.append(token)
        }
        index += 1
    }
    return args
}

// MARK: - Help

let commandHelp: [String: String] = [
    "open": "alohajet open <url>\n  Open a new tab at <url> and print its page as markdown with element refs.\n  Prints the tab id every other command takes; it stays valid until the tab or\n  the browser closes. The tab becomes the one in use, so the next command needs\n  no --tab. <url> must carry a scheme: https://example.com, not example.com.",
    "read": "alohajet read [--tab <id>]\n  Print a tab's page as markdown. Without --tab: the tab left in use by the last\n  command, else the browser's first http(s) tab.",
    "tabs": "alohajet tabs\n  List every open tab with its id and URL. ● marks the tab in use; a tab marked\n  [the user's tab] was already open when we attached and close refuses it.",
    "close": "alohajet close <id>\n  Close a tab by id. In the default lane every tab is one alohajet opened, so any\n  of them can be closed. Under --cdp the browser is the user's: tabs that were\n  already open there are theirs, not ours, and close refuses them.",
    "quit": "alohajet quit\n  Close the shared browser the default lane launched and delete its profile.\n  Nothing else ends it: it is deliberately still running when a command exits, so\n  the element refs the last command printed are still addressable by the next one.",
    "click": "alohajet [--tab <id>] click <ref> [--double|--right]\n  Click the element carrying that aloha-id on the tab in use.",
    "type": "alohajet [--tab <id>] type <ref> <text> [--submit] [--no-replace]\n  Type into an input by ref. --submit presses Enter after; --no-replace appends.",
    "select": "alohajet [--tab <id>] select <ref> --text <t> | --index <n>\n  Pick an option in a <select> by visible text or zero-based index.",
    "text": "alohajet [--tab <id>] text <ref>[,<ref>...] [--max-chars <n>]\n  Read the visible text (or input value) of up to 20 elements in one call.",
    "goto": "alohajet [--tab <id>] goto <url>\n  Navigate the tab in use, in place. http and https only.",
    "back": "alohajet [--tab <id>] back\n  Step back in the tab in use's history.",
    "keys": "alohajet [--tab <id>] keys <chord>\n  Send a key or chord to whatever has focus, e.g. \"Enter\", \"Control+a\".",
    "wait": "alohajet [--tab <id>] wait <css-selector> [--timeout-ms <n>]\n  Poll until an element matches, or the timeout (default 10000, capped at 30000).",
    "mcp": "alohajet mcp\n  Serve the eight tools as an MCP server over stdio."
]

let usage = """
alohajet — drive a real Chromium from the command line.

USAGE
  alohajet [connection flags] <command> [args] [--json]

COMMANDS
  open <url>                        open a tab and print the page
  read [--tab <id>]                 print a tab as markdown with element refs
  tabs                              list open tabs
  close <id>                        close a tab
  quit                              close the shared browser (see CONNECTION)
  click <ref> [--double|--right]    click an element by ref
  type <ref> <text> [--submit] [--no-replace]
  select <ref> --text <t> | --index <n>
  text <ref>[,<ref>...]             read element text
  goto <url> | back                 navigate the tab in use
  keys <chord>                      send a key or chord
  wait <css> [--timeout-ms <n>]     wait for an element
  mcp                               run as an MCP server on stdio

AGENT (the ONE thing here that is not a tool call)
  -p <prompt> --endpoint <url>      run one agent turn: hand <prompt> to the agent
                                    loop already running behind <url> (POST
                                    /agent/task) and print its final answer.
                                    NO loop runs in this process — without
                                    --endpoint there is nothing to run the turn and
                                    `-p` says so and exits 2. Every command above
                                    needs a browser and no agent; `-p` needs an
                                    agent and no browser flags.
                                    <url> must be loopback http (127.0.0.1, ::1,
                                    localhost) or https: see ALOHAJET_AGENT_TOKEN.
                                    Each `-p` runs in a FRESH conversation and
                                    prints its id on stderr, so a piped answer is
                                    still just the answer.
  --resume <chat-id>                continue that conversation instead. A host that
                                    answers with a different id is refused, not
                                    silently written to.
  --continue                        run in whichever conversation the agent is
                                    already on — what every turn did before the
                                    default became fresh.

CONNECTION (global; with none of these, the SHARED browser below is used)
  (default)                 one Chromium, launched on first use and REUSED by every
                            later command, so refs printed by `open` still work in
                            `click`. It outlives the command that started it —
                            `alohajet quit` closes it. Its port is recorded in
                            <tmp>/alohajet-<uid>/browser.json.
  --launch                  a throwaway Chromium for THIS command only, terminated
                            on exit. Refs it prints die with it: single commands
                            (`open`, `goto`) only.
  --headless/--no-headless  headless is the default; read only when a browser is
                            actually launched, not when one is reused
  --port <n>                debug port to launch on (default: a free one)
  --cdp <ws-url|port|host:port>
                            attach to a browser already listening; never terminated,
                            and its pre-existing tabs are the user's (close refuses)
  --browser chromium|aloha  which browser to drive. `aloha` attaches to the Aloha
                            browser's own CDP listener (127.0.0.1:9222, or
                            ALOHA_CDP_PORT), starting the app when it is not running.
                            It is the user's browser: never terminated, and its
                            pre-existing tabs are theirs. Default: chromium

OUTPUT
  --tab <id>                the tab to act on; every command that touches a page
                            takes it. Default: the tab the last command left in use,
                            else the browser's first http(s) tab. Ids are the ones
                            `open` and `tabs` print — one namespace, no translation
  --json                    print the RawToolResult as JSON instead of prose
  -h, --help                this text; `alohajet <command> --help` for one command

ENVIRONMENT
  ALOHAJET_NETWORK_LOG      OFF by default. Set to a directory to record every
                            request each agent-opened tab makes to
                            <dir>/<tabId>.jsonl (0600 in a 0700 directory); =1
                            uses a temp directory. Credential headers, POST
                            bodies and credential-named fields are masked;
                            RESPONSE BODIES ARE NOT — do not enable it on a page
                            you would not paste into a bug report. Nothing
                            deletes these files.
  ALOHAJET_BROWSER          path to the Chromium executable the default and --launch
                            lanes run. Unset: a system Chrome, else a Chrome for
                            Testing build downloaded once into Application Support
  ALOHA_CDP_PORT            the port --browser aloha looks for the Aloha browser's
                            CDP listener on (default 9222)
  ALOHA_BROWSER_APP         path to the Aloha .app --browser aloha launches, when it
                            is not a registered install
  ALOHAJET_AGENT_TOKEN      the bearer token `-p` sends to --endpoint. Unset: read
                            from ~/Library/Application Support/Aloha/automation-token,
                            where the Aloha browser provisions it — but that AMBIENT
                            token is sent to a LOOPBACK --endpoint only, since it
                            grants full control of the browser and rewrites the
                            provider API key stored in it. An https --endpoint
                            elsewhere is served only by this variable, set on purpose.
                            Absent entirely: no Authorization header is sent and the
                            endpoint answers 401 — never a silent unauthenticated retry
  ALOHAJET_DEBUG            log protocol chatter to stderr

EXIT CODES
  0 ok    1 tool error    2 usage    3 browser unreachable
"""

// MARK: - Output

func resultJSON(_ result: RawToolResult) -> String {
    var object: [String: WorkflowValue] = [
        "output": .string(result.output),
        "isError": .bool(result.isError ?? false)
    ]
    if let status = result.status { object["status"] = .string(status.rawValue) }
    if let metadata = result.metadata, !metadata.isEmpty { object["metadata"] = .object(metadata) }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(WorkflowValue.object(object)),
          let text = String(data: data, encoding: .utf8) else {
        return "{\"isError\":true,\"output\":\"result could not be encoded\"}"
    }
    return text
}

func emit(_ result: RawToolResult, json: Bool) {
    if json {
        print(resultJSON(result))
    } else if result.isError == true {
        writeToStandardError(result.output + "\n")
    } else {
        print(result.output)
    }
}

// MARK: - Connection

/// The shared browser the default lane reuses, as recorded on disk.
///
/// The old `--attach` read `~/.alohajet/cdp.json` and NOTHING in this package ever wrote
/// it, so the flag could only ever print "no live browser; launching one". This is that
/// file with a writer: the invocation that launches the shared browser records it here,
/// every later invocation attaches to `port`, and `quit` uses `profile`/`stderrLog` to
/// leave nothing behind. Two things changed besides the writer: the path is not
/// `~/.alohajet` (that directory belongs to the Aloha app, and a public tool must not
/// write into another product's home), and `tab` carries the one piece of session state
/// a one-command-per-process CLI otherwise cannot keep — which tab is in use.
struct SharedBrowser: Codable {
    var port: Int
    var profile: String?
    var stderrLog: String?
    /// The tab the last command acted on, so the next one needs no `--tab`.
    var tab: String?
}

/// `<tmp>/alohajet-<uid>/`: per-user (a shared `/tmp` must not hand one user's debug
/// port to another) and cleared on reboot, like the browser it describes.
let sharedStateDirectory = temporaryDirectory
    .appendingPathComponent("alohajet-\(getuid())", isDirectory: true).path
let sharedStatePath = (sharedStateDirectory as NSString).appendingPathComponent("browser.json")

/// The shared browser this invocation is using, once `connect` has resolved one. `nil`
/// under `--launch` and `--cdp`, which own no state to carry.
var sharedState: SharedBrowser?

func readSharedState() -> SharedBrowser? {
    guard let data = FileManager.default.contents(atPath: sharedStatePath) else { return nil }
    return try? JSONDecoder().decode(SharedBrowser.self, from: data)
}

func writeSharedState(_ state: SharedBrowser) {
    guard let data = try? JSONEncoder().encode(state) else { return }
    try? FileManager.default.createDirectory(
        atPath: sharedStateDirectory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    FileManager.default.createFile(
        atPath: sharedStatePath, contents: data, attributes: [.posixPermissions: 0o600])
}

func clearSharedState() {
    try? FileManager.default.removeItem(atPath: sharedStatePath)
}

/// The Chromium the launch lanes run: `ALOHAJET_BROWSER` when set, else a system Chrome,
/// else a Chrome for Testing build downloaded once and cached. The download is the last
/// resort and it is announced, because it is ~150 MB the user did not ask for.
func provisionedExecutablePath() async throws -> String {
    let provisioner = try ChromiumProvisioner(
        browserPath: ProcessInfo.processInfo.environment["ALOHAJET_BROWSER"])
    let manager = FileManager.default
    let willDownload = !(provisioner.browserPath.map(manager.isExecutableFile(atPath:)) ?? false)
        && !manager.isExecutableFile(atPath: provisioner.stagedExecutablePath())
        && !manager.isExecutableFile(atPath: provisioner.systemDefaultPath)
    if willDownload {
        writeToStandardError("""
            alohajet: no browser found at \(provisioner.systemDefaultPath) — downloading \
            Chrome for Testing \(provisioner.buildTable.version) once into \
            \(provisioner.stagedRootDir()). Set ALOHAJET_BROWSER to use your own.\n
            """)
    }
    return try await provisioner.resolveExecutablePath()
}

func connect(_ args: Args) async throws -> BrowserToolSession {
    // Parsed HERE, not inside `launch()`. It used to be read on the launch path only,
    // which had two consequences: `--port frotz` was silently ignored whenever a shared
    // browser was already running, and when it was not, the `CLIError` it throws fell
    // into `launch()`'s catch-all and came back as the struct's `description` —
    // `alohajet: CLIError(message: "--port expects a number, got \"frotz\"", code: 2)` —
    // under exit code 3 (browser unreachable) rather than 2 (usage).
    let requestedPort = try args.int("--port")

    func launch() async throws -> BrowserToolSession {
        do {
            return try await BrowserToolSession.launch(
                executablePath: try await provisionedExecutablePath(),
                headless: !args.has("--no-headless"),
                port: requestedPort)
        } catch let error as ChromiumProvisionerError {
            throw CLIError(message: error.description, code: exitUnreachable)
        } catch let error as BrowserToolSessionError {
            throw CLIError(message: error.description, code: exitUnreachable)
        } catch {
            throw CLIError(message: "\(error)", code: exitUnreachable)
        }
    }

    func attach(_ endpoint: String) async throws -> BrowserToolSession {
        do {
            if endpoint.hasPrefix("ws://") || endpoint.hasPrefix("wss://") {
                return try await BrowserToolSession.attach(webSocketURL: endpoint)
            }
            if let port = Int(endpoint) {
                return try await BrowserToolSession.attach(port: port)
            }
            let parts = endpoint.split(separator: ":")
            guard parts.count == 2, let port = Int(parts[1]) else {
                throw CLIError(
                    message: "--cdp expects a ws:// url, a port, or host:port — got \"\(endpoint)\"",
                    code: exitUsage)
            }
            return try await BrowserToolSession.attach(host: String(parts[0]), port: port)
        } catch let error as BrowserToolSessionError {
            throw CLIError(message: error.description, code: exitUnreachable)
        }
    }

    switch args.value("--browser") {
    case nil, "chromium":
        break
    case "aloha":
        // The user's own browser, so `ownsBrowser` stays false: its tabs are theirs and
        // `close` refuses them, exactly as under `--cdp`.
        guard args.value("--cdp") == nil else {
            throw CLIError(
                message: "--browser aloha and --cdp name two different browsers; pass one",
                code: exitUsage)
        }
        do {
            let url = try await AlohaBrowser().endpoint()
            return try await attach(url.absoluteString)
        } catch let error as AlohaBrowserError {
            throw CLIError(message: error.description, code: exitUnreachable)
        }
    case let other?:
        throw CLIError(
            message: "--browser expects chromium or aloha, got \"\(other)\"", code: exitUsage)
    }

    if let endpoint = args.value("--cdp") {
        return try await attach(endpoint)
    }
    if args.has("--launch") {
        return try await launch()
    }

    // The shared lane. `ownsBrowser: true` is the whole difference between this and
    // `--cdp`: the tabs in there are ones alohajet opened, so `close` may close them,
    // where a tab in the user's own browser may not be touched.
    // ponytail: last writer wins. Two commands starting from cold at the same instant
    // both launch, and one browser ends up unrecorded — the usual pid-file race. Take a
    // lock on the state file if that ever bites; a human typing commands cannot hit it.
    if let recorded = readSharedState() {
        if let session = try? await BrowserToolSession.attach(port: recorded.port, ownsBrowser: true) {
            sharedState = recorded
            return session
        }
        // The recorded browser is not answering, so it is gone — but a browser killed by
        // a signal never got to remove its throwaway profile, and the record about to be
        // overwritten is the last thing that knows where it is. Remove it now or nothing
        // ever will: that is how a machine ends up with seven abandoned profile dirs.
        if let profile = recorded.profile { try? FileManager.default.removeItem(atPath: profile) }
        if let stderrLog = recorded.stderrLog { try? FileManager.default.removeItem(atPath: stderrLog) }
    }
    let session = try await launch()
    guard let browser = session.launchedBrowser else { return session }
    let state = SharedBrowser(
        port: browser.port, profile: browser.userDataDir, stderrLog: browser.stderrLog, tab: nil)
    writeSharedState(state)
    sharedState = state
    // Hand the browser over to the file we just wrote: `shutdown()` now closes only our
    // socket, and the next invocation attaches to the same Chromium.
    session.releaseBrowser()
    return session
}

/// `alohajet quit` — the only thing that ends the shared browser.
///
/// `Browser.close` rather than a signal to the recorded pid: a pid outlives its process
/// and can be reused, and a CLI must never send a signal to a process it cannot prove is
/// the browser it launched. A CDP connection to the recorded port IS that proof.
func quitSharedBrowser() async -> Int32 {
    guard let state = readSharedState() else {
        print("No shared browser is running.")
        return exitOK
    }
    var closed = false
    if let session = try? await BrowserToolSession.attach(port: state.port) {
        _ = try? await session.client.send(method: "Browser.close", params: [:])
        await session.shutdown()
        closed = true
        // Chrome unlinks its own lock files as it exits; give it a moment so the
        // profile removal below does not race a live write.
        try? await Task.sleep(nanoseconds: 300_000_000)
    }
    if let profile = state.profile { try? FileManager.default.removeItem(atPath: profile) }
    if let stderrLog = state.stderrLog { try? FileManager.default.removeItem(atPath: stderrLog) }
    clearSharedState()
    print(closed
        ? "Closed the shared browser on port \(state.port)."
        : "No browser was listening on port \(state.port); cleared the stale record.")
    return exitOK
}

// MARK: - Commands

/// The tab a page command should act on when `--tab` was not given: the tab in use, then
/// the one the last invocation left in use, then the browser's first http(s) tab.
///
/// `nil` when the browser has no web tab at all. It used to answer the fresh
/// `about:blank` in that case, and the page tools then rejected it as `URL not allowed:
/// malformed or oversized URL` — a message that is wrong twice over (the URL is neither
/// malformed nor oversized) about a tab the user never asked for. There is no tab to
/// read; say so.
///
/// ponytail: scrapes the `ID:`/`URL:` lines out of `manage_tabs list`'s prose, because
/// the tab list is not exposed any other way. Swap it for a structured accessor if one
/// ever lands on the session.
func resolveTab(_ session: BrowserToolSession, _ explicit: String?) async -> String? {
    if let explicit { return explicit }
    if let active = session.getActiveBrowserTabId() { return active }
    let listing = await session.run("manage_tabs", arguments: ["action": "list"])
    guard listing.isError != true else { return nil }

    var tabs: [(id: String, url: String, isActive: Bool)] = []
    var pendingActive = false
    for line in listing.output.split(separator: "\n", omittingEmptySubsequences: false) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("ID: ") {
            tabs.append((String(trimmed.dropFirst(4)), "", pendingActive))
        } else if trimmed.hasPrefix("URL: "), !tabs.isEmpty {
            tabs[tabs.count - 1].url = String(trimmed.dropFirst(5))
        } else if !trimmed.isEmpty {
            pendingActive = trimmed.contains("\u{25CF}")
        }
    }
    let web = tabs.filter { $0.url.hasPrefix("http://") || $0.url.hasPrefix("https://") }
    guard !web.isEmpty else { return nil }
    // The remembered tab is checked against the live list, not trusted: it may have been
    // closed since, and a stale id would fail every later command with "not found".
    if let remembered = sharedState?.tab, web.contains(where: { $0.id == remembered }) {
        return remembered
    }
    return (web.first { $0.isActive } ?? web.first)?.id
}

/// The tab id a `manage_tabs` result named, off the metadata channel the tool already
/// fills — no second parse of the prose.
func resultTabId(_ result: RawToolResult) -> String? {
    guard case let .string(id)? = result.metadata?["tabId"], !id.isEmpty else { return nil }
    return id
}

/// Point the page tools at a tab before running one.
///
/// Every invocation is its own session, so nothing carries "the tab in use" over from
/// the last one: without this, a page command lands on whichever tab the browser model
/// considers active — `chrome://newtab` as often as not. One extra round-trip buys a
/// page command that acts on the page the caller means.
func useTab(_ session: BrowserToolSession, _ explicit: String?) async throws {
    if explicit == nil, session.getActiveBrowserTabId() != nil { return }
    guard let tabId = await resolveTab(session, explicit) else {
        throw CLIError(
            message: "no page open — run `alohajet open <url>` first, or `alohajet tabs` and pass --tab <id>",
            code: exitUsage)
    }
    let result = await session.run("manage_tabs", arguments: ["action": "use", "tab_id": tabId])
    if result.isError == true {
        throw CLIError(message: result.output, code: exitToolError)
    }
}

func toolCall(
    _ command: String, _ args: Args, _ session: BrowserToolSession
) async throws -> (String, [String: Any]) {
    switch command {
    case "open":
        return ("manage_tabs", ["action": "open", "url": try args.required(1, "url")])

    case "read":
        guard let tabId = await resolveTab(session, args.value("--tab")) else {
            throw CLIError(
                message: "no page open — run `alohajet open <url>` first, or `alohajet tabs` and pass --tab <id>",
                code: exitUsage)
        }
        return ("manage_tabs", ["action": "read", "tab_id": tabId])

    case "tabs":
        return ("manage_tabs", ["action": "list"])

    case "close":
        return ("manage_tabs", ["action": "close", "tab_id": try args.required(1, "id")])

    case "click":
        try await useTab(session, args.value("--tab"))
        let clickType = args.has("--right") ? "right" : (args.has("--double") ? "double" : "single")
        return ("page_click", ["aloha_id": try args.required(1, "ref"), "click_type": clickType])

    case "type":
        try await useTab(session, args.value("--tab"))
        return ("page_type", [
            "aloha_id": try args.required(1, "ref"),
            "text": try args.required(2, "text"),
            "replace": !args.has("--no-replace"),
            "submit": args.has("--submit")
        ])

    case "select":
        try await useTab(session, args.value("--tab"))
        var arguments: [String: Any] = ["aloha_id": try args.required(1, "ref")]
        if let text = args.value("--text") {
            arguments["text"] = text
        } else if let index = try args.int("--index") {
            arguments["index"] = index
        } else {
            throw CLIError(message: "select needs --text <t> or --index <n>", code: exitUsage)
        }
        return ("page_select", arguments)

    case "text":
        try await useTab(session, args.value("--tab"))
        var arguments: [String: Any] = ["aloha_id": try args.required(1, "ref")]
        if let maxChars = try args.int("--max-chars") { arguments["max_chars"] = maxChars }
        return ("get_text", arguments)

    case "goto":
        try await useTab(session, args.value("--tab"))
        return ("page_navigate", ["action": "goto", "url": try args.required(1, "url")])

    case "back":
        try await useTab(session, args.value("--tab"))
        return ("page_navigate", ["action": "back"])

    case "keys":
        try await useTab(session, args.value("--tab"))
        return ("page_press_keys", ["keys": try args.required(1, "chord")])

    case "wait":
        try await useTab(session, args.value("--tab"))
        var arguments: [String: Any] = ["selector": try args.required(1, "css-selector")]
        if let timeout = try args.int("--timeout-ms") { arguments["timeout_ms"] = timeout }
        return ("page_wait_for", arguments)

    default:
        throw CLIError(message: "unknown command \"\(command)\". Try --help.", code: exitUsage)
    }
}

// MARK: - Entry point

/// Carry "the tab in use" to the next invocation. Nothing else can: each command is its
/// own process, so the session pointer the page tools read is born empty every time and
/// `read` after `open` used to land on whichever tab the browser model happened to list
/// first. Only the shared lane has anywhere to keep it.
func rememberTab(_ command: String, _ args: Args, _ result: RawToolResult, ok: Bool) {
    guard var state = sharedState, ok else { return }
    let next = command == "close" ? nil : (args.value("--tab") ?? resultTabId(result) ?? state.tab)
    guard next != state.tab else { return }
    state.tab = next
    sharedState = state
    writeSharedState(state)
}

func report(_ error: CLIError, json: Bool) {
    if json {
        print(resultJSON(RawToolResult(output: error.message, isError: true, status: .error)))
    } else {
        writeToStandardError("alohajet: \(error.message)\n")
    }
}

func main() async -> Int32 {
    // `alohajet read | head` closes the pipe under us. The default SIGPIPE disposition
    // kills the process mid-print — before `shutdown()`, which is what terminates a
    // browser we launched. Ignoring it turns that into a failed write we survive.
    signal(SIGPIPE, SIG_IGN)

    let args: Args
    do {
        args = try parseArgs(Array(CommandLine.arguments.dropFirst()))
    } catch let error as CLIError {
        writeToStandardError("alohajet: \(error.message)\n")
        return error.code
    } catch {
        writeToStandardError("alohajet: \(error)\n")
        return exitUsage
    }

    let wantsHelp = args.has("--help") || args.has("-h")

    // `-p` is the agent entry, and it takes no command: it is not a tool call, it
    // launches no browser, and it connects to nothing this process owns. Answered
    // here, before `connect`, so a prompt never starts a Chromium it will not use.
    if args.has("-p"), !wantsHelp {
        return await AgentTurn.run(args)
    }

    guard let command = args.positional.first else {
        print(usage)
        return wantsHelp ? exitOK : exitUsage
    }
    if wantsHelp {
        guard let help = commandHelp[command] else {
            writeToStandardError("alohajet: unknown command \"\(command)\"\n")
            return exitUsage
        }
        print(help)
        return exitOK
    }
    let json = args.has("--json")

    // The MCP stdio server takes over here, before anything can reach stdout and before
    // `connect`: it builds its browser on the first `tools/call`, so a host that only
    // lists tools never pays for one. It reads the same connection flags off argv.
    if command == "mcp" {
        return await MCPServer.main(Array(args.positional.dropFirst()))
    }

    // `quit` connects to the recorded browser, not to a new one: it is the command that
    // ENDS the shared lane, so going through `connect` (which launches one when none is
    // running) would be exactly backwards.
    if command == "quit" {
        return await quitSharedBrowser()
    }

    let session: BrowserToolSession
    do {
        session = try await connect(args)
    } catch let error as CLIError {
        report(error, json: json)
        return error.code
    } catch {
        report(CLIError(message: "\(error)", code: exitUnreachable), json: json)
        return exitUnreachable
    }

    // Ctrl-C is the other exit path, and until this line it orphaned the browser and its
    // temp profile — a run must not outlive its launch. Installed only for a browser this
    // command owns: one reached through --cdp is the user's, and the shared browser was
    // released to the commands that come after this one. Neither is ours to reap.
    session.installSignalReaper()

    // One exit path from here down: whatever happens, a browser we launched gets
    // terminated before the process leaves.
    let code: Int32
    do {
        let (tool, arguments) = try await toolCall(command, args, session)
        let result = await session.run(tool, arguments: arguments)
        emit(result, json: json)
        code = result.isError == true ? exitToolError : exitOK
        rememberTab(command, args, result, ok: code == exitOK)
    } catch let error as CLIError {
        report(error, json: json)
        code = error.code
    } catch {
        report(CLIError(message: "\(error)", code: exitToolError), json: json)
        code = exitToolError
    }
    await session.shutdown()
    return code
}

exit(await main())
