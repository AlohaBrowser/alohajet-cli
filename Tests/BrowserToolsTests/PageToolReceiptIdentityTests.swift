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

    /// The whole note from the live page, in one call: the ladder's selector verified live, the
    /// count, the text and the identity, in the receipt's order. With no durable selector: "".
    @Test func theLiveNoteComposesEveryProbe() async {
        let node = DomNode(id: "a2", element: DomElement(tagName: "button", attributes: ["class": "size"]))
        let tab = ReceiptFakeTab(nodes: ["a2": node])
        // A named selector asks nothing of the live-path probe; then the count, the text, the identity.
        let backend = ReceiptProbeBackend([.number(3), .string("M"), .string(#"{"index":2,"attrs":[["aria-label","M"]]}"#)])
        let note = await PageToolReceipt.liveNote(alohaId: "a2", tab: tab, bridge: AgentBrowserBridge(backend: backend), tool: "page_click")
        #expect(note == " [selector=button.size] [tool=page_click] [matches=3] [index=2/3] [text=\"M\"] [attrs=aria-label=\"M\"]")
        #expect(backend.asked == 3)
        let none = await PageToolReceipt.liveNote(alohaId: "zz", tab: tab, bridge: AgentBrowserBridge(backend: ReceiptProbeBackend([.number(1)])), tool: "page_click")
        #expect(none == "")
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
