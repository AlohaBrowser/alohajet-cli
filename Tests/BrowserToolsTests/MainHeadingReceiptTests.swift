import Testing
import Foundation
import ToolABI
@testable import BrowserTools

// MARK: - The page's main heading on a whole-page read
//
// Agent runs github-ss-r25/r26 (2026-09-23): the agent read the release name off the page with
// `manage_tabs read`, which names no element; the mint invented `h1.d-flex span` and
// `h1.d-inline.mr-3` for the read step and refused both. The read now names the main heading(s)
// with a selector from the click ladder. The page-side probe is exercised by `main_heading.js`.

@Suite("Main heading receipt")
@MainActor
struct MainHeadingReceiptTests {

    private let releasesReply = #"[{"tag":"h1","attrs":[["class","d-inline mr-3"]],"xpath":"/body/div/main/section[1]/div/h1","text":"v4.31.0"},{"tag":"h1","attrs":[],"xpath":"/body/div/main/section[2]/div/h1","text":"v4.30.0"}]"#

    @Test func theReplyParses() {
        let hs = MainHeadingProbe.parse(releasesReply)
        #expect(hs.count == 2)
        #expect(hs[0].text == "v4.31.0")
        #expect(hs[0].xpath == "/body/div/main/section[1]/div/h1")
    }

    @Test func theSelectorComesFromTheClickLadder() {
        let hs = MainHeadingProbe.parse(releasesReply)
        #expect(MainHeadingProbe.selector(for: hs[0]) == "h1.d-inline.mr-3")                          // stable classes
        #expect(MainHeadingProbe.selector(for: hs[1]) == "body>div>main>section:nth-of-type(2)>div>h1") // position path
    }

    @Test func theLineUsesTheReceiptBrackets() {
        let h = MainHeadingProbe.parse(releasesReply)[0]
        let note = PageToolReceipt.selectorNote(
            selector: MainHeadingProbe.selector(for: h), matches: 2, text: h.text,
            identity: ElementIdentity(index: 1, attributes: MainHeadingProbe.receiptAttributes(h)), source: "main-heading")
        let line = MainHeadingProbe.receiptLine([note])
        #expect(line.hasPrefix("Main heading on this page:\n- [selector=h1.d-inline.mr-3] [source=main-heading] [matches=2] [index=1/2] [text=\"v4.31.0\"]"))
        #expect(!line.contains("[attrs="))   // class is filtered, nothing else to show
        #expect(MainHeadingProbe.receiptLine([]) == "")
        #expect(MainHeadingProbe.receiptLine([note, note]).hasPrefix("Main headings on this page:"))
    }

    @Test func malformedEntriesAreDropped() {
        #expect(MainHeadingProbe.parse(#"[{"tag":"","xpath":"/body/h1"},{"tag":"h1","xpath":"/html/h1"},{"tag":"h1"}]"#).isEmpty)
        #expect(MainHeadingProbe.parse("not json").isEmpty)
    }

    /// The bridge: one probe for the headings, then a count and an index per heading that has
    /// matches, composed into the read's line. An empty page adds nothing.
    @Test func theBridgeComposesTheLine() async {
        let backend = ReceiptProbeBackend([.string(releasesReply), .number(2), .number(1), .number(1), .number(1)])
        let line = await AgentBrowserBridge(backend: backend).mainHeadingReceiptLine()
        #expect(line == "Main headings on this page:"
                + "\n- [selector=h1.d-inline.mr-3] [source=main-heading] [matches=2] [index=1/2] [text=\"v4.31.0\"]"
                + "\n- [selector=body>div>main>section:nth-of-type(2)>div>h1] [source=main-heading] [matches=1] [text=\"v4.30.0\"]")
        #expect(backend.asked == 5)
        #expect(await AgentBrowserBridge(backend: ReceiptProbeBackend([.string("[]")])).mainHeadingReceiptLine() == "")
        #expect(await AgentBrowserBridge(backend: ReceiptProbeBackend(error: ReceiptProbeFailure())).mainHeadingReceiptLine() == "")
    }

    /// A heading whose ladder selector does not name it on the live page (the class rung matched
    /// another `h1`) is written with `[index=none]`, like every other unverified receipt address.
    @Test func anUnverifiedHeadingSelectorIsMarked() async {
        let one = #"[{"tag":"h1","attrs":[["class","d-inline mr-3"]],"xpath":"/body/div/main/section[1]/div/h1","text":"v4.31.0"}]"#
        let backend = ReceiptProbeBackend([.string(one), .number(1), .number(-1)])
        let line = await AgentBrowserBridge(backend: backend).mainHeadingReceiptLine()
        #expect(line == "Main heading on this page:\n- [selector=h1.d-inline.mr-3] [source=main-heading] [matches=1] [index=none] [text=\"v4.31.0\"]")
    }
}
