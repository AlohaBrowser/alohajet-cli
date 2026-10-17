import Testing
import Foundation
import ToolABI
@testable import BrowserTools

// MARK: - `[anchor=…]` on the action receipt
//
// One address per element, chosen by one rule and verified on the live page with the replay's
// resolver (page side: `receipt_anchor.js`). Agent runs, 2026-09-23: the mint anchored H&M's White
// swatch on a neighbour's text and left size M and GitHub's Go filter as position paths.

@Suite("Receipt anchor")
@MainActor
struct ReceiptAnchorTests {

    @Test func theProbeReplyParses() {
        #expect(ReceiptAnchorProbe.parse(#"{"s":"a[href=\"/p/001\"]"}"#) == .init(selector: "a[href=\"/p/001\"]", nth: nil))
        #expect(ReceiptAnchorProbe.parse(#"{"s":"body>ul>li>a","nth":2}"#) == .init(selector: "body>ul>li>a", nth: 2))
        #expect(ReceiptAnchorProbe.parse("") == nil)
        #expect(ReceiptAnchorProbe.parse(#"{"s":""}"#) == nil)
        #expect(ReceiptAnchorProbe.parse(#"{"s":"a","nth":0}"#) == .init(selector: "a", nth: nil))
        #expect(ReceiptAnchorProbe.parse("Example Domain") == nil)
    }

    @Test func onlyAPositionPathIsUnstable() {
        #expect(ReceiptAnchorProbe.isStable("#add-to-bag-button"))
        #expect(ReceiptAnchorProbe.isStable("a[href=\"/p/001\"]"))
        #expect(ReceiptAnchorProbe.isStable("li[role=\"menuitemradio\"]"))
        #expect(!ReceiptAnchorProbe.isStable("body>main>div>ul>li:nth-of-type(3)>div>div"))
        #expect(!ReceiptAnchorProbe.isStable("body"))
        #expect(!ReceiptAnchorProbe.isStable(nil))
    }

    @Test func theReceiptCarriesTheAnchorLast() {
        var identity = ElementIdentity(index: 1, attributes: [.init(name: "data-testid", value: "003-in-stock")],
                                       list: .init(selector: "body>main>div>ul>li>div>div", index: 3, count: 7))
        identity.anchor = .init(selector: "body>main>div>ul>li>div>div:has-text(\"M\")", nth: nil)
        let note = PageToolReceipt.selectorNote(selector: "body>main>div>ul>li:nth-of-type(3)>div>div", matches: 1, text: "M", identity: identity)
        #expect(note.hasSuffix(" [list=body>main>div>ul>li>div>div 3/7] [anchor=body>main>div>ul>li>div>div:has-text(\"M\")]"))
        identity.anchor = .init(selector: "body>ul>li>a", nth: 2)
        let ordinal = PageToolReceipt.selectorNote(selector: "body>ul>li:nth-of-type(2)>a", matches: 1, identity: identity)
        #expect(ordinal.hasSuffix(" [anchor=body>ul>li>a] [anchor-nth=2]"))
    }

    /// A read's probe is told it is a read (it then never anchors on the text it reads); an
    /// action's is not. The rule itself is exercised page-side (receipt_anchor.js cases 9-11).
    @Test func theReadFlagReachesTheProbe() {
        let read = ReceiptAnchorProbe.expression(alohaId: "r1", selector: "a.x", stable: true, list: "body>ul>li>a", forRead: true)
        let click = ReceiptAnchorProbe.expression(alohaId: "r1", selector: "a.x", stable: true, list: "body>ul>li>a")
        #expect(read.contains(#""body>ul>li>a", true)"#))
        #expect(click.contains(#""body>ul>li>a", false)"#))
        #expect(!read.contains("\\#("))
        #expect(read.contains("/* receipt: anchor */"))
    }

    /// The probe says how many elements its address resolved to; a rel-href anchor parses like any
    /// other, and so does an old sub-path one.
    @Test func theProbeReportsItsMatchCount() {
        #expect(ReceiptAnchorProbe.parse(#"{"s":"a:rel-href(\"releases\")","n":3}"#)
                == .init(selector: "a:rel-href(\"releases\")", nth: nil, count: 3))
        #expect(ReceiptAnchorProbe.parse(#"{"s":"body>ul>li>a","nth":2,"n":1}"#) == .init(selector: "body>ul>li>a", nth: 2, count: 1))
        #expect(ReceiptAnchorProbe.parse(#"{"s":"a","n":0}"#)?.count == nil)
        #expect(ReceiptAnchorProbe.parse(#"{"s":"a:sub-path(\"/releases\")"}"#) == .init(selector: "a:sub-path(\"/releases\")", nth: nil))
    }

    // MARK: the bridge

    /// The resolver is installed when the page has none, then the probe runs; a page that already
    /// has it is asked once less. The installer ships `SelectorResolverScript` and nothing else.
    @Test func theBridgeInstallsTheResolverWhenAbsent() async {
        let absent = ReceiptProbeBackend([.string("n"), .string("installed"), .string(#"{"s":"a[href=\"/p/001\"]","n":1}"#)])
        let anchor = await AgentBrowserBridge(backend: absent).receiptAnchor(alohaId: "s2", selector: "a[href=\"/p/001\"]", list: nil)
        #expect(anchor == .init(selector: "a[href=\"/p/001\"]", nth: nil, count: 1))
        #expect(absent.asked == 3)
        #expect(absent.scripts[0] == SelectorResolverScript.isInstalledProbe)
        #expect(absent.scripts[1] == SelectorResolverScript.installIfNeeded)
        #expect(absent.scripts[2].contains("/* receipt: anchor */"))
        // `stable` is false for a position path, true for every other rung.
        #expect(absent.scripts[2].contains(#""a[href=\"/p/001\"]", true, "", false)"#))

        let present = ReceiptProbeBackend([.string("y"), .string(#"{"s":"body>ul>li>a","nth":2,"n":1}"#)])
        let ordinal = await AgentBrowserBridge(backend: present).receiptAnchor(alohaId: "i2", selector: "body>ul>li:nth-of-type(2)>a", list: "body>ul>li>a", forRead: true)
        #expect(ordinal == .init(selector: "body>ul>li>a", nth: 2, count: 1))
        #expect(present.asked == 2)
        #expect(present.scripts[1].contains(#""body>ul>li:nth-of-type(2)>a", false, "body>ul>li>a", true)"#))
    }

    /// Nothing to anchor (no selector and no list, or no id), a silent page, or a probe that found
    /// no candidate: nil, and the receipt then carries no `[anchor=…]`.
    @Test func noAnchorWithoutEvidence() async {
        let untouched = ReceiptProbeBackend([.string("y")])
        #expect(await AgentBrowserBridge(backend: untouched).receiptAnchor(alohaId: "x", selector: nil, list: nil) == nil)
        #expect(await AgentBrowserBridge(backend: untouched).receiptAnchor(alohaId: "", selector: "#q", list: nil) == nil)
        #expect(untouched.asked == 0)
        #expect(await AgentBrowserBridge(backend: ReceiptProbeBackend([.string("y"), .string("")])).receiptAnchor(alohaId: "x", selector: "#q", list: nil) == nil)
        #expect(await AgentBrowserBridge(backend: ReceiptProbeBackend(error: ReceiptProbeFailure())).receiptAnchor(alohaId: "x", selector: "#q", list: nil) == nil)
    }

    /// The identity probe carries the anchor: identity first, then the resolver check, then the
    /// anchor, with the list the identity found handed to the anchor rule.
    @Test func theIdentityCarriesTheAnchor() async {
        let backend = ReceiptProbeBackend([
            .string(#"{"index":3,"attrs":[["href","/p/003"]],"list":{"selector":"body>ul>li>a","index":3,"count":7}}"#),
            .string("y"),
            .string(#"{"s":"body>ul>li>a:has-text(\"M\")","n":1}"#)])
        let identity = await AgentBrowserBridge(backend: backend).elementIdentity(selector: "body>ul>li:nth-of-type(3)>a", alohaId: "z2")
        #expect(identity?.anchor == .init(selector: "body>ul>li>a:has-text(\"M\")", nth: nil, count: 1))
        #expect(identity?.list?.index == 3)
        #expect(backend.asked == 3)
        #expect(backend.scripts[2].contains(#""body>ul>li>a", false)"#))
    }
}
