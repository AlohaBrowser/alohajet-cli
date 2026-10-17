import Testing
import Foundation
import ToolABI
import CDP
@testable import BrowserTools

// MARK: - The values an answer reports, and the receipts for them
//
// The page side (finding the element that holds each value) is exercised against fake pages by
// `answer_receipt.js`. These pin which values a final answer yields, on answers the batch actually
// produced (ported from the agent repository's windows-on-snips `AnswerReceiptTests`), the line
// the verdict carries, and how the bridge composes a receipt from the package's probes.

@Suite("Answer receipt values")
struct AnswerReceiptValuesTests {

    @Test func boldAndQuotedSpansAreTheValues() {
        // github-ss-r76
        #expect(AnswerReceipt.values(in: "According to the release list, the latest release is **v3.8.5**, marked as \"Latest\" next to it.")
                == ["v3.8.5", "Latest"])
        // gtranslate-fr, curly and guillemet quotes, trailing punctuation inside the bold
        #expect(AnswerReceipt.values(in: "Google Translate gives:  **« Où est la gare ferroviaire la plus proche ? »**")
                == ["Où est la gare ferroviaire la plus proche ?"])
        #expect(AnswerReceipt.values(in: "The top story’s title is **“Approachable Swift Concurrency.”**")
                == ["Approachable Swift Concurrency"])
    }

    /// osm-route: a bold LABEL is not a value; the text after its colon is (osm-route-r79 wrote
    /// `**Walking distance**: 3.7 kilometers (about 2.3 miles)`), its trailing gloss dropped.
    @Test func aBoldLabelIsNotAValueButWhatFollowsItIs() {
        #expect(AnswerReceipt.values(in: "**Walking distance:** 3.7 km\n**Estimated time:** 50 minutes") == ["3.7 km", "50 minutes"])
        #expect(AnswerReceipt.values(in: "**Walking distance**: 3.7 kilometers (about 2.3 miles)") == ["3.7 kilometers"])
        #expect(AnswerReceipt.values(in: "**Walking distance: 3.7 km**") == ["Walking distance: 3.7 km"])
    }

    @Test func sentencesDuplicatesAndTheCapAreHandled() {
        let sentence = "**" + Array(repeating: "word", count: AnswerReceipt.maxWords + 1).joined(separator: " ") + "**"
        #expect(AnswerReceipt.values(in: sentence) == [])
        #expect(AnswerReceipt.values(in: "**1.3.0** … the latest is **1.3.0**") == ["1.3.0"])
        #expect(AnswerReceipt.values(in: "**a** **b** **c** **d** **e**").count == AnswerReceipt.maxValues)
        #expect(AnswerReceipt.values(in: "No bold, no quotes.") == [])
    }

    @Test func aLineNamesItsValueAndCarriesTheReceipt() {
        let line = AnswerReceipt.Line(value: "v3.8.5", receipt: " [selector=body>nav>ul>li:nth-of-type(2)>a] [tool=answer] [matches=1]")
        #expect(line.text == "answer \"v3.8.5\": [selector=body>nav>ul>li:nth-of-type(2)>a] [tool=answer] [matches=1]")
    }

    /// The value is prose: a quote, a line break or a square bracket in it must not end the token
    /// or read as a bracket of the receipt (llmdex takes `[name=…]` anywhere on the line).
    @Test func theValueNeverReadsAsAToken() {
        let line = AnswerReceipt.Line(value: "Say \"hi\"\n[tool=x]", receipt: " [selector=p] [tool=answer]")
        #expect(line.text == "answer \"Say 'hi' (tool=x)\": [selector=p] [tool=answer]")
    }
}

// MARK: - The bridge: one receipt per matched element, from the package's own probes

/// Answers each receipt probe by the marker its script carries, and records every script.
@MainActor
private final class MarkerProbeBackend: AgentBridgeBackend {
    var replies: [(marker: String, value: JSValue?)]
    private(set) var scripts: [String] = []
    init(_ replies: [(marker: String, value: JSValue?)]) { self.replies = replies }

    func asked(_ marker: String) -> Int { scripts.filter { $0.contains(marker) }.count }

    var isAborted: Bool { false }
    func consumeAgentDownloads() -> [CapturedDownload] { [] }
    func evaluateViaCdp(_ expression: String) async throws -> JSValue? {
        scripts.append(expression)
        return replies.first { expression.contains($0.marker) }?.value ?? nil
    }
    @discardableResult
    func sendCdpCommand(domain: String, command: String, params: [String: JSValue]) async throws -> JSValue { .null }
    func captureViewport() async throws -> (base64: String, imageWidth: Int, imageHeight: Int)? { nil }
    func viewportDimensions() -> ViewportSize? { nil }
    func resolveSandboxSavePath(_ path: String) -> String? { nil }
    func writeScreenshot(base64: String, hostPath: String, isPng: Bool) async throws {}
}

private let pageMatch = "/* receipt: answer page match */"
private let cleanup = "/* receipt: answer cleanup */"
private let githubTask = "Go to github.com, open MHSanaei/3x-ui's Releases page and tell me the latest release name."
private let githubAnswer = "The latest release is **v3.8.5**."

@Suite("Answer receipt bridge")
@MainActor
struct AnswerReceiptBridgeTests {

    /// github-ss-r76: the value sits in a link with no semantic anchor free of it. The receipt is
    /// the element's position path, its live count, its text and attributes, `[tool=answer]`; the
    /// temporary id is cleaned up after.
    @Test func aMatchedElementGetsAReadReceipt() async {
        let backend = MarkerProbeBackend([
            (pageMatch, .string(#"[{"id":"aloha-answer-0","path":"body>div>main>section>h2>a","text":"v3.8.5"}]"#)),
            ("/* receipt: match count */", .number(1)),
            ("/* receipt: identity */", .string(#"{"index":1,"attrs":[["href","/MHSanaei/3x-ui/releases/tag/v3.8.5"]]}"#)),
            ("window.__snips.resolveAll === 'function'", .string("y")),
            ("/* receipt: anchor */", .string("")),
            (cleanup, .string("1")),
        ])
        let lines = await AgentBrowserBridge(backend: backend).answerReceipts(for: githubAnswer, prompt: githubTask)
        #expect(lines.map(\.text) == [
            "answer \"v3.8.5\": [selector=body>div>main>section>h2>a] [tool=answer] [matches=1] [text=\"v3.8.5\"]"
            + " [attrs=href=\"/MHSanaei/3x-ui/releases/tag/v3.8.5\"]",
        ])
        #expect(backend.asked(cleanup) == 1)
        // The read rules: the anchor probe is asked as for a read (no anchor from the value).
        let anchorScript = backend.scripts.first { $0.contains("/* receipt: anchor */") } ?? ""
        #expect(anchorScript == ReceiptAnchorProbe.expression(
            alohaId: "aloha-answer-0", selector: "body>div>main>section>h2>a", stable: false, list: nil, forRead: true))
    }

    /// Exception 1 applies as on every receipt: a semantic anchor free of the value replaces the
    /// position path in `[selector=]`, and the path moves to `[path=]`.
    @Test func aSemanticAnchorIsTheSelector() async {
        let backend = MarkerProbeBackend([
            (pageMatch, .string(#"[{"id":"d61f-6c0653d","path":"body>div>main>h1","text":"Rapid transit"}]"#)),
            ("/* receipt: match count */", .number(1)),
            ("/* receipt: identity */", .string(#"{"index":1,"attrs":[["id","firstHeading"]]}"#)),
            ("window.__snips.resolveAll === 'function'", .string("y")),
            ("/* receipt: anchor */", .string(#"{"s":"h1#firstHeading","n":1}"#)),
            (cleanup, .string("0")),
        ])
        let lines = await AgentBrowserBridge(backend: backend).answerReceipts(
            for: "The article is titled **Rapid transit**.", prompt: "Open the article about metros and tell me its title.")
        #expect(lines.count == 1)
        #expect(lines.first?.value == "Rapid transit")
        #expect(lines.first?.receipt == " [selector=h1#firstHeading] [tool=answer] [path=body>div>main>h1] [matches=1]"
                + " [text=\"Rapid transit\"] [attrs=id=\"firstHeading\"] [anchor=h1#firstHeading]")
    }

    /// The reads the turn made ride into the page matcher, which ranks them first.
    @Test func theTurnsReadsReachTheMatcher() async {
        let backend = MarkerProbeBackend([(pageMatch, .string(""))])
        _ = await AgentBrowserBridge(backend: backend).answerReceipts(
            for: githubAnswer, prompt: githubTask, readIds: ["d61f-badge", "d61f-6c0653d"])
        let script = backend.scripts.first { $0.contains(pageMatch) } ?? ""
        #expect(script.contains(#"["d61f-badge","d61f-6c0653d"]"#))
        #expect(script.contains(#"["v3.8.5"]"#))                     // the bold span ranks candidates
    }

    /// Nothing on the page, a page that cannot answer, an empty answer: no lines, no cleanup.
    @Test func nothingMatchedIsNoReceipt() async {
        let none = MarkerProbeBackend([(pageMatch, .string(""))])
        #expect(await AgentBrowserBridge(backend: none).answerReceipts(for: githubAnswer, prompt: githubTask).isEmpty)
        #expect(none.asked(cleanup) == 0)
        let dead = MarkerProbeBackend([])
        #expect(await AgentBrowserBridge(backend: dead).answerReceipts(for: githubAnswer, prompt: githubTask).isEmpty)
        #expect(dead.asked(cleanup) == 0)
        let blank = MarkerProbeBackend([(pageMatch, .string(#"[{"id":"x","path":"body>p","text":"x"}]"#))])
        #expect(await AgentBrowserBridge(backend: blank).answerReceipts(for: "  \n", prompt: githubTask).isEmpty)
        #expect(blank.scripts.isEmpty)
    }

    /// An entry without an id or a path is skipped; the rest still get their receipts.
    @Test func aMalformedEntryIsSkipped() async {
        let backend = MarkerProbeBackend([
            (pageMatch, .string(#"[{"path":"body>p","text":"a"},{"id":"q","path":"","text":"b"},{"id":"aloha-answer-0","path":"body>p:nth-of-type(2)","text":"512"}]"#)),
            ("/* receipt: match count */", .number(1)),
            ("/* receipt: identity */", .string(#"{"index":1,"attrs":[]}"#)),
            ("window.__snips.resolveAll === 'function'", .string("y")),
            (cleanup, .string("1")),
        ])
        let lines = await AgentBrowserBridge(backend: backend).answerReceipts(for: "It has 512 stars.", prompt: "How many stars?")
        #expect(lines.map(\.value) == ["512"])
        #expect(lines.first?.receipt == " [selector=body>p:nth-of-type(2)] [tool=answer] [matches=1] [text=\"512\"]")
    }

    // MARK: The public entry, on a real (MockCDP-backed) tab

    /// `answerReceipts(onTab:)`: the tab's page is asked, the turn's `get_text` reads on that tab
    /// ride along, and the call itself is not an observation.
    @Test func onATabTheTurnsReadsAreUsed() async throws {
        let fixture = try await makePageToolsCDPFixture()
        defer { Task { await fixture.client.close() } }
        fixture.cdp.alohaRawCallReplies = [
            (match: "__aloha.getText(", reply: .string("v3.8.5")),
            (match: pageMatch, reply: .string(#"[{"id":"d61f-6c0653d","path":"body>main>h2>a","text":"v3.8.5"}]"#)),
            (match: "/* receipt: match count */", reply: .number(2)),
            (match: "/* receipt: identity */", reply: .string(#"{"index":2,"attrs":[]}"#)),
            (match: cleanup, reply: .string("0")),
        ]
        let services = NativeToolServices(tabsService: fixture.tabsService)
        let window = try #require(fixture.tabsService.window)
        let tracker = AnswerPageTracker()
        tracker.beginTurn(deferringCloses: false)
        _ = try await tracker.tracking {
            try await GetTextExecutorTool().execute(
                .object(["aloha_id": .string("d61f-6c0653d")]), makePageToolContext(services: services))
        }
        let tab = try #require(tracker.observedTab(in: window))
        let lines = await answerReceipts(onTab: tab, answer: githubAnswer, prompt: githubTask, tracker: tracker)
        #expect(lines.map(\.text) == ["answer \"v3.8.5\": [selector=body>main>h2>a] [tool=answer] [matches=2] [index=2/2] [text=\"v3.8.5\"]"])
        let asked = fixture.cdp.commands(for: "Runtime.evaluate").compactMap { $0.params["expression"]?.stringValue }
        #expect(asked.contains { $0.contains(pageMatch) && $0.contains(#"["d61f-6c0653d"]"#) })
    }
}
