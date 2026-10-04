import Testing
import Foundation
import ToolABI
@testable import BrowserTools

// MARK: - `[index=i/N]` and `[attrs=…]` on every action receipt
//
// A scenario replays on the one site it was minted from, so the receipt may be as site-specific
// as the element: its real attributes and which of the selector's matches it was. Until now a
// mint had the selector, the count and the element's text -- text was the ONLY anchor, and text
// is fragile (localised labels, reordered words: agent run jacket-bag-luna-ge34 anchored 'FAUX
// SUEDE BELTED JACKET' on a card that read 'BELTED FAUX SUEDE JACKET'). The mechanism is general;
// the content is whatever the page wrote on the element.

@Suite("Action receipt identity")
@MainActor
struct PageToolReceiptIdentityTests {

    private let sizeM = ElementIdentity(
        index: 2,
        attributes: [.init(name: "data-qa-action", value: "size-in-stock"), .init(name: "aria-label", value: "M")])

    /// The full receipt: selector, count, index, text, attrs -- in that order, one line.
    @Test func theNoteCarriesIndexAndAttributes() {
        let note = PageToolReceipt.selectorNote(
            selector: "button.size-selector-sizes-size__button", matches: 3, text: "M", identity: sizeM)
        #expect(note == " [selector=button.size-selector-sizes-size__button] [matches=3] [index=2/3] [text=\"M\"]"
                + " [attrs=data-qa-action=\"size-in-stock\" aria-label=\"M\"]")
    }

    /// One match: the selector already names the element, so no `[index=1/1]` noise.
    @Test func aSingleMatchHasNoIndexToken() {
        let one = ElementIdentity(index: 1, attributes: [.init(name: "name", value: "q")])
        #expect(PageToolReceipt.selectorNote(selector: "#q", matches: 1, identity: one)
                == " [selector=#q] [matches=1] [attrs=name=\"q\"]")
    }

    /// An index the count cannot hold (stale snapshot, page changed between reads) is dropped.
    @Test func anIndexBeyondTheCountIsNotPrinted() {
        let odd = ElementIdentity(index: 5, attributes: [])
        #expect(PageToolReceipt.selectorNote(selector: "a.card", matches: 3, identity: odd) == " [selector=a.card] [matches=3]")
    }

    /// No identity (page could not be asked) leaves the old receipt exactly as it was.
    @Test func noIdentityIsTheOldReceipt() {
        #expect(PageToolReceipt.selectorNote(selector: "a.card", matches: 60, text: "BELTED JACKET")
                == " [selector=a.card] [matches=60] [text=\"BELTED JACKET\"]")
    }

    /// Values stay tokenizable: no `"`, no `]`, no line breaks inside a `[key=…]` token.
    @Test func attributeValuesAreTokenSafe() {
        let quirky = ElementIdentity(index: 1, attributes: [
            .init(name: "title", value: "Say \"hi\"]\nnow"),
            .init(name: "aria-label", value: "plain"),
        ])
        #expect(PageToolReceipt.selectorNote(selector: "div", matches: 1, identity: quirky)
                == " [selector=div] [matches=1] [attrs=title=\"Say 'hi') now\" aria-label=\"plain\"]")
        #expect(PageToolReceipt.selectorNote(selector: "div", matches: 1, text: "line\r\nbreak \"q\"")
                == " [selector=div] [matches=1] [text=\"line  break 'q'\"]")
    }

    /// The probe's JSON reply -> identity.
    @Test func theReplyParses() {
        let parsed = ReceiptIdentityProbe.parse(#"{"index":2,"attrs":[["data-qa-action","size-in-stock"],["aria-label","M"]]}"#)
        #expect(parsed == sizeM)
        #expect(ReceiptIdentityProbe.parse(#"{"index":-1,"attrs":[]}"#) == ElementIdentity(index: nil, attributes: []))
        #expect(ReceiptIdentityProbe.parse("not json") == nil)
        #expect(ReceiptIdentityProbe.parse("[1,2]") == nil)
        // a malformed pair is skipped, the rest kept
        #expect(ReceiptIdentityProbe.parse(#"{"index":1,"attrs":[["x"],["href","/p"],[3,4]]}"#)
                == ElementIdentity(index: 1, attributes: [.init(name: "href", value: "/p")]))
    }

    /// The expression embeds the selector and the id as JSON literals (no injection through either).
    @Test func theExpressionEmbedsLiterals() {
        let expression = ReceiptIdentityProbe.expression(selector: "a[href*=\"x\"]", alohaId: "1g\"; alert(1); //")
        #expect(expression.contains(#""a[href*=\"x\"]""#))
        #expect(expression.contains(#""1g\"; alert(1); //""#))
        #expect(expression.contains("\(ReceiptIdentityProbe.maxAttributes)"))
        #expect(!expression.contains("\\#("))
    }

    @Test func theBridgeAsksOnceAndParses() async {
        let backend = ReceiptProbeBackend([.string(#"{"index":2,"attrs":[["aria-label","M"]]}"#)])
        let bridge = AgentBrowserBridge(backend: backend)
        let identity = await bridge.elementIdentity(selector: "button.size", alohaId: "a2")
        #expect(identity == ElementIdentity(index: 2, attributes: [.init(name: "aria-label", value: "M")]))
        #expect(backend.asked == 1)
        #expect(backend.scripts[0].contains("getAttributeNames"))
    }

    /// A page that throws, a non-string reply, or an empty id yield nil -- and the receipt then
    /// says nothing about identity rather than guessing.
    @Test func failuresYieldNil() async {
        #expect(await AgentBrowserBridge(backend: ReceiptProbeBackend(error: ReceiptProbeFailure())).elementIdentity(selector: "a", alohaId: "x") == nil)
        #expect(await AgentBrowserBridge(backend: ReceiptProbeBackend([.number(3)])).elementIdentity(selector: "a", alohaId: "x") == nil)
        #expect(await AgentBrowserBridge(backend: ReceiptProbeBackend([.string("{}")])).elementIdentity(selector: "a", alohaId: "") == nil)
    }

    /// A position path is the last resort: when the ladder fell to one and the anchor is semantic
    /// and not positional, the anchor IS the selector and the path moves to `[path=…]`
    /// (agent runs github-ss-r81/r83: the search button's mint step was the 13-segment path).
    @Test func aSemanticAnchorReplacesAPositionPathAsTheSelector() {
        let path = "body>div:nth-of-type(1)>header>div>button"
        var id = ElementIdentity(index: 2, attributes: [])
        id.anchor = .init(selector: "button[aria-label=\"Search or jump to, type / to search\"]", nth: nil, count: 1)
        let note = PageToolReceipt.selectorNote(selector: path, matches: 3, text: "Search/", identity: id, tool: "page_click")
        #expect(note.hasPrefix(" [selector=button[aria-label=\"Search or jump to, type / to search\"]] [tool=page_click] [path=\(path)] [matches=1]"))
        #expect(!note.contains("[index="))       // the index was among the PATH's matches
        #expect(note.hasSuffix(" [anchor=button[aria-label=\"Search or jump to, type / to search\"]]"))

        // A rule-0 link anchor reports how many links lead to the same place; the unverified
        // path's missing index is not `[index=none]` either, the anchor WAS verified.
        var rel = ElementIdentity(index: nil, attributes: [])
        rel.anchor = .init(selector: "a:rel-href(\"releases\")", nth: nil, count: 3)
        #expect(PageToolReceipt.selectorNote(selector: path, matches: 0, identity: rel).hasPrefix(" [selector=a:rel-href(\"releases\")] [path=\(path)] [matches=3] [anchor="))

        // No swap: an anchor that is itself an ordinal or a path, or a ladder selector that is not
        // a position path.
        var ordinal = ElementIdentity(index: 2, attributes: [])
        ordinal.anchor = .init(selector: "body>ul>li>a", nth: 2)
        #expect(PageToolReceipt.selectorNote(selector: path, matches: 3, identity: ordinal).hasPrefix(" [selector=\(path)] [matches=3] [index=2/3]"))
        var named = ElementIdentity(index: 1, attributes: [])
        named.anchor = .init(selector: "button[aria-label=\"Sort\"]", nth: nil, count: 1)
        #expect(PageToolReceipt.selectorNote(selector: "[data-testid=\"sort-button\"]", matches: 1, identity: named)
                == " [selector=[data-testid=\"sort-button\"]] [matches=1] [anchor=button[aria-label=\"Sort\"]]")
    }

    /// The receipt names who wrote it, right after its selector (llmdex, 2026-09-30: receipts lifted
    /// out of `<tool_result tool="…">` reached the mint as `receipt :`, a read indistinguishable
    /// from a click). No label, no token -- every older receipt shape is unchanged.
    @Test func theReceiptNamesItsTool() {
        #expect(PageToolReceipt.selectorNote(selector: "a.ActionListContent", matches: 27, tool: "get_text")
                == " [selector=a.ActionListContent] [tool=get_text] [matches=27]")
        #expect(PageToolReceipt.selectorNote(selector: "h1", matches: 1, source: "main-heading")
                == " [selector=h1] [source=main-heading] [matches=1]")
        #expect(PageToolReceipt.selectorNote(selector: "#q", matches: 1) == " [selector=#q] [matches=1]")
        #expect(PageToolReceipt.selectorNote(selector: nil, matches: 1, tool: "page_click") == "")
    }

    /// `[submitted=enter]` is a bracket like the others, so a mint reads it where it dropped the
    /// prose "and pressed Enter to submit" (agent run github-ss-r4).
    @Test func theSubmitTokenIsABracketedNote() {
        #expect(PageToolReceipt.submittedNote == " [submitted=enter]")
    }

    /// The whole note from the live page, in one call: the ladder's selector verified live (with
    /// its count), the text and the identity, in the receipt's order. With no durable selector: "".
    @Test func theLiveNoteComposesEveryProbe() async {
        let node = DomNode(id: "a2", element: DomElement(tagName: "button", attributes: ["class": "size"]))
        let tab = ReceiptFakeTab(nodes: ["a2": node])
        // The live-selector probe (count included), then the text, then the identity.
        let backend = ReceiptProbeBackend([.string(#"{"n":3,"has":true,"path":"","pathN":0}"#), .string("M"),
                                           .string(#"{"index":2,"attrs":[["aria-label","M"]]}"#)])
        let note = await PageToolReceipt.liveNote(alohaId: "a2", tab: tab, bridge: AgentBrowserBridge(backend: backend), tool: "page_click")
        #expect(note == " [selector=button.size] [tool=page_click] [matches=3] [index=2/3] [text=\"M\"] [attrs=aria-label=\"M\"]")
        #expect(backend.asked == 3)
        let none = await PageToolReceipt.liveNote(alohaId: "zz", tab: tab, bridge: AgentBrowserBridge(backend: ReceiptProbeBackend([.number(1)])), tool: "page_click")
        #expect(none == "")
    }

    /// A SELECTOR THE LIVE PAGE DOES NOT CONFIRM is written with `[index=none]`: the identity probe
    /// found the element but not among the selector's matches (its class or id changed on
    /// re-render, or it matches nothing now), and no path could be rebuilt. A mint then knows not
    /// to build a step on that address (2026-10-04 audit).
    @Test func anUnverifiedSelectorIsMarkedIndexNone() {
        let unconfirmed = ElementIdentity(index: nil, attributes: [.init(name: "href", value: "/p")])
        #expect(PageToolReceipt.selectorNote(selector: "a.card", matches: 2, identity: unconfirmed)
                == " [selector=a.card] [matches=2] [index=none] [attrs=href=\"/p\"]")
        #expect(PageToolReceipt.selectorNote(selector: "#q", matches: 0, identity: ElementIdentity(index: nil, attributes: []))
                == " [selector=#q] [matches=0] [index=none]")
        #expect(PageToolReceipt.selectorNote(selector: "#q", matches: 1, identity: ElementIdentity(index: nil, attributes: []))
                == " [selector=#q] [matches=1] [index=none]")
        // Confirmed, or unknown count, or no identity at all: no such token.
        #expect(!PageToolReceipt.selectorNote(selector: "#q", matches: 1, identity: ElementIdentity(index: 1, attributes: [])).contains("[index="))
        #expect(!PageToolReceipt.selectorNote(selector: "#q", matches: nil, identity: unconfirmed).contains("[index="))
        #expect(!PageToolReceipt.selectorNote(selector: "#q", matches: 2).contains("[index="))
    }

    /// Through the live note: a named selector the page no longer confirms is rebuilt as the
    /// element's position path, and the receipt carries that path with its own count.
    @Test func theLiveNoteCarriesTheRebuiltPath() async {
        let node = DomNode(id: "q1", element: DomElement(tagName: "input", attributes: ["id": "q"]))
        let tab = ReceiptFakeTab(nodes: ["q1": node])
        let backend = ReceiptProbeBackend([
            .string(#"{"n":1,"has":false,"path":"body>form>input:nth-of-type(2)","pathN":1}"#), .string(""),
            .string(#"{"index":1,"attrs":[["name","q"]]}"#)])
        let note = await PageToolReceipt.liveNote(alohaId: "q1", tab: tab, bridge: AgentBrowserBridge(backend: backend), tool: "page_type")
        #expect(note == " [selector=body>form>input:nth-of-type(2)] [tool=page_type] [matches=1] [attrs=name=\"q\"]")
        // The identity probe is asked about the REBUILT selector, not the stale one.
        #expect(backend.scripts[2].contains("body>form>input:nth-of-type(2)"))
    }
}

/// A tab whose snapshot holds the nodes a receipt test names, so no browser is needed.
struct ReceiptFakeTab: StepTraceTab {
    var traceTabId: String = "tab-1"
    var traceTabURL: String = "http://shop.example/"
    var traceTabTitle: String? = "Shop"
    var nodes: [String: DomNode] = [:]

    func captureInteractMarkdown() async throws -> StepTraceMarkdown {
        StepTraceMarkdown(markdown: "", screenshotBase64: nil)
    }

    func captureAccessibilityTree() async throws -> JSValue { .null }

    func traceDomNode(forAlohaId alohaId: String) -> DomNode? { nodes[alohaId] }
}
