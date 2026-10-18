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

    /// quotes-love-first-author, teach run F0C8A4B4 (2026-10-18), the answer verbatim: the lead value
    /// is bold and followed by a colon, and the quote it introduces is on the next line. It was taken
    /// for a LABEL (`**…**:`), so the answer's own value got no hint and no receipt.
    @Test func aBoldValueBeforeAColonAndALineBreakIsAValue() {
        let answer = """
        The first quote is attributed to **André Gide**:

        > “It is better to be hated for what you are than to be loved for what you are not.”

        There are 14 quotes tagged “love” across [page 1](https://quotes.toscrape.com/tag/love/page/1/) and \
        [page 2](https://quotes.toscrape.com/tag/love/page/2/). The rest are attributed, in order, to **Marilyn Monroe, \
        Bob Marley, Elie Wiesel, Friedrich Nietzsche, Pablo Neruda, Marilyn Monroe, Marilyn Monroe, James Baldwin, \
        Jane Austen, C.S. Lewis, Alfred Tennyson, Jane Austen,** and **J.M. Barrie**.
        """
        #expect(AnswerReceipt.values(in: answer) == ["André Gide", "love", "J.M. Barrie"])
        // The same answer with the colon at the end of the text, or the quote on the same line.
        #expect(AnswerReceipt.values(in: "The first quote is attributed to **André Gide**:") == ["André Gide"])
        #expect(AnswerReceipt.values(in: "It is by **André Gide**: “It is better to be hated.”") == ["André Gide", "It is better to be hated"])
    }

    /// A bold span with the colon AFTER it is a label only where a label stands -- at the start of a
    /// line or a clause -- and only with a value after it on the same line.
    @Test func aLabelOpensItsLineOrClauseAndHasAValue() {
        #expect(AnswerReceipt.values(in: "- **Author**: André Gide") == ["André Gide"])
        #expect(AnswerReceipt.values(in: "**Walking distance**: 3.7 kilometers. **Estimated time**: 50 minutes.")
                == ["3.7 kilometers", "50 minutes"])
        #expect(AnswerReceipt.values(in: "The author is **André Gide**: a French writer.") == ["André Gide"])
        // A "value" that is a sentence makes the bold span the value, wherever it stands.
        #expect(AnswerReceipt.values(in: "**André Gide**: it is better to be hated for what you are than to be loved for what you are not")
                == ["André Gide"])
        // The colon inside the bold is always a label, with or without a value after it.
        #expect(AnswerReceipt.values(in: "**Time:**\n50 min") == [])
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

/// Answers each script with `reply` (nil: the page could not answer), and records every script.
@MainActor
private final class ScriptedProbeBackend: AgentBridgeBackend {
    let reply: (String) -> JSValue?
    private(set) var scripts: [String] = []
    init(_ reply: @escaping (String) -> JSValue?) { self.reply = reply }

    var isAborted: Bool { false }
    func consumeAgentDownloads() -> [CapturedDownload] { [] }
    func evaluateViaCdp(_ expression: String) async throws -> JSValue? {
        scripts.append(expression)
        return reply(expression)
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

    // MARK: The selector: the ladder's, narrowed, verified (2026-10-18)

    /// the-internet /secure (heroku-login-secure-area): the flash the answer quotes is `div#flash`,
    /// and the receipt said `body>div:nth-of-type(1)>div>div`. The ladder's id is verified live
    /// (its matches hold the element) and becomes the selector; the position path is not written.
    @Test func theLaddersIdIsTheSelector() async {
        let backend = ScriptedProbeBackend { script in
            if script.contains(pageMatch) {
                return .string(#"[{"id":"aloha-answer-0","path":"body>div:nth-of-type(1)>div>div","text":"You logged into a secure area! ×","tag":"div","attrs":{"id":"flash","class":"flash success","data-alert":""},"desc":["close"]}]"#)
            }
            if script.contains("/* receipt: live selector */") { return .string(#"{"n":1,"has":true,"path":"","pathN":0}"#) }
            if script.contains("/* receipt: identity */") { return .string(#"{"index":1,"attrs":[["data-alert",""],["id","flash"]]}"#) }
            if script.contains("window.__snips.resolveAll === 'function'") { return .string("y") }
            if script.contains("/* receipt: anchor */") { return .string(##"{"s":"#flash","n":1}"##) }
            if script.contains(cleanup) { return .string("1") }
            return nil
        }
        let lines = await AgentBrowserBridge(backend: backend).answerReceipts(
            for: #"Logged in. The page message was: **"You logged into a secure area!"**"#,
            prompt: "Log in on this page as tomsmith using the demo credentials it shows, and tell me the message you get.")
        #expect(lines.map(\.receipt) == [
            #" [selector=#flash] [tool=answer] [matches=1] [text="You logged into a secure area! ×"] [attrs=data-alert="" id="flash"] [anchor=#flash]"#,
        ])
        #expect(!backend.scripts.contains { $0.contains("/* receipt: match count */") })   // the path was never needed
    }

    /// Wikipedia's infobox (wiki-ada-lovelace-birthdate): the ladder gives `td.infobox-data`, which
    /// every infobox cell matches. A class INSIDE the cell narrows it to exactly this one; the
    /// first narrowing that resolves to one element -- this element -- wins.
    @Test func aSharedClassIsNarrowedByAClassInsideTheElement() async {
        let backend = ScriptedProbeBackend { script in
            if script.contains(pageMatch) {
                return .string(#"[{"id":"aloha-answer-0","path":"body>div>main>table>tbody>tr:nth-of-type(3)>td","text":"Augusta Ada Byron 10 December 1815 London, England","tag":"td","attrs":{"class":"infobox-data"},"desc":["css-1x2y3z","nickname","bday"]}]"#)
            }
            if script.contains("/* receipt: live selector */") {
                if script.contains(#""td.infobox-data""#) { return .string(#"{"n":9,"has":true,"path":"","pathN":0}"#) }
                if script.contains(#""td.infobox-data:has(.nickname)""#) { return .string(#"{"n":2,"has":true,"path":"","pathN":0}"#) }
                if script.contains(#""td.infobox-data:has(.bday)""#) { return .string(#"{"n":1,"has":true,"path":"","pathN":0}"#) }
                return .string(#"{"n":0,"has":false,"path":"","pathN":0}"#)
            }
            if script.contains("/* receipt: identity */") { return .string(#"{"index":1,"attrs":[]}"#) }
            if script.contains("window.__snips.resolveAll === 'function'") { return .string("y") }
            if script.contains(cleanup) { return .string("1") }
            return nil
        }
        let lines = await AgentBrowserBridge(backend: backend).answerReceipts(
            for: "Ada Lovelace was born on **10 December 1815**.",
            prompt: "Open the Wikipedia article on Ada Lovelace and tell me her date of birth.")
        #expect(lines.first?.receipt.hasPrefix(" [selector=td.infobox-data:has(.bday)] [tool=answer] [matches=1]") == true, "\(lines)")
        // A hashed class is never tried; the shared one stays when nothing narrows it.
        #expect(!backend.scripts.contains { $0.contains("css-1x2y3z") })
        #expect(AnswerReceipt.narrowed("td.infobox-data", insideClasses: [.string("Born")], text: "born") == [])
    }

    /// A ladder selector the live page does not match on this element (a class the page swapped)
    /// is not written: the live position path is, as before.
    @Test func aLadderSelectorThatMissesFallsBackToThePath() async {
        let backend = ScriptedProbeBackend { script in
            if script.contains(pageMatch) {
                return .string(#"[{"id":"aloha-answer-0","path":"body>main>p","text":"512","tag":"p","attrs":{"class":"stars"},"desc":[]}]"#)
            }
            if script.contains("/* receipt: live selector */") { return .string(#"{"n":3,"has":false,"path":"body>main>p","pathN":1}"#) }
            if script.contains("/* receipt: match count */") { return .number(1) }
            if script.contains("/* receipt: identity */") { return .string(#"{"index":1,"attrs":[]}"#) }
            if script.contains(cleanup) { return .string("1") }
            return nil
        }
        let lines = await AgentBrowserBridge(backend: backend).answerReceipts(for: "It has **512** stars.", prompt: "How many stars?")
        #expect(lines.map(\.receipt) == [#" [selector=body>main>p] [tool=answer] [matches=1] [text="512"]"#])
    }

    // MARK: The caps llmdex reads them with (open ask 6)

    /// Every line is shorter than 4000 runes -- llmdex keeps the first 4000 of an entry and would cut
    /// a longer one inside a bracket. The attributes go first; a line still too long is not sent.
    @Test func aLineStaysUnderTheEntryCap() async {
        let longPath = "body>" + Array(repeating: "div", count: 500).joined(separator: ">")          // ~2000
        let longList = "body>" + Array(repeating: "section", count: 190).joined(separator: ">")     // ~1500
        let attrs = (0..<12).map { #"["data-k\#($0)","\#(String(repeating: "v", count: 60))"]"# }.joined(separator: ",")
        let backend = ScriptedProbeBackend { script in
            if script.contains(pageMatch) {
                return .string(#"[{"id":"aloha-answer-0","path":"\#(longPath)","text":"512"},{"id":"aloha-answer-1","path":"\#(longPath)>\#(longPath)","text":"513"}]"#)
            }
            if script.contains("/* receipt: match count */") { return .number(1) }
            if script.contains("/* receipt: identity */") {
                return .string(#"{"index":1,"attrs":[\#(attrs)],"list":{"selector":"\#(longList)","index":1,"count":2}}"#)
            }
            if script.contains(cleanup) { return .string("2") }
            return nil
        }
        let lines = await AgentBrowserBridge(backend: backend).answerReceipts(for: "It has 512 or 513 stars.", prompt: "How many stars?")
        #expect(lines.map(\.value) == ["512"])
        #expect(lines.allSatisfy { $0.text.unicodeScalars.count < AnswerReceipt.maxLineLength })
        #expect(lines.first.map { !$0.receipt.contains("[attrs=") && $0.receipt.contains("[list=") } == true)
    }

    /// At most twelve lines per answer, whatever the page answers.
    @Test func atMostTwelveLines() async {
        let items = (0..<15).map { #"{"id":"aloha-answer-\#($0)","path":"body>p:nth-of-type(\#($0 + 1))","text":"v\#($0).0.1"}"# }
        let backend = ScriptedProbeBackend { script in
            if script.contains(pageMatch) { return .string("[" + items.joined(separator: ",") + "]") }
            if script.contains("/* receipt: match count */") { return .number(1) }
            if script.contains("/* receipt: identity */") { return .string(#"{"index":1,"attrs":[]}"#) }
            if script.contains(cleanup) { return .string("15") }
            return nil
        }
        let lines = await AgentBrowserBridge(backend: backend).answerReceipts(for: "Versions v0.0.1 to v14.0.1.", prompt: "List them.")
        #expect(lines.count == AnswerReceipt.maxLines)
        #expect(AnswerReceipt.maxValues <= AnswerReceipt.maxLines)
        #expect(AnswerReceipt.maxLines == 12 && AnswerReceipt.maxLineLength == 4000)
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
