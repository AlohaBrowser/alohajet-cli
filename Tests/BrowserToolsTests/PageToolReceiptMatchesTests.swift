import Testing
import Foundation
import ToolABI
@testable import BrowserTools

// MARK: - `[matches=N]` on every action receipt
//
// A mint that turns a run into a saved automation keeps the receipt's durable selector. Whether
// that selector names ONE element or many decides whether it can be kept as is or must be
// anchored (`a.product-link._item` matches every card on a results page; the size button class
// matches every size). Until the count rode along, the server side had to reason "ask it of
// every click"; the server asked for `[matches=N]` on the receipt. Agent run jacket-bag-luna-ge32
// (2026-09-21) had five receipts with `[selector=…]` and no count on any of them.

@Suite("Action receipt match count")
@MainActor
struct PageToolReceiptMatchesTests {

    @Test func theNoteCarriesSelectorAndCount() {
        #expect(PageToolReceipt.selectorNote(selector: "a.product-link._item", matches: 60)
                == " [selector=a.product-link._item] [matches=60]")
    }

    /// The count is omitted, never invented, when the page could not be asked.
    @Test func anUnknownCountLeavesOnlyTheSelector() {
        #expect(PageToolReceipt.selectorNote(selector: "#q", matches: nil) == " [selector=#q]")
    }

    /// No durable selector, no note at all (the old contract, unchanged).
    @Test func noSelectorNoNote() {
        #expect(PageToolReceipt.selectorNote(selector: nil, matches: 3) == "")
    }

    @Test func theBridgeCountsWithOneQuerySelectorAll() async {
        let backend = ReceiptProbeBackend([.number(3)])
        let bridge = AgentBrowserBridge(backend: backend)
        #expect(await bridge.selectorMatchCount("button.size-selector-sizes-size__button") == 3)
        #expect(backend.asked == 1)
        #expect(backend.scripts[0].contains("querySelectorAll"))
        #expect(backend.scripts[0].contains("button.size-selector-sizes-size__button"))
    }

    /// A selector that does not parse (-1 from the page), a page that throws, or no selector at
    /// all yield nil -- the receipt then says nothing about matches.
    @Test func failuresYieldNil() async {
        #expect(await AgentBrowserBridge(backend: ReceiptProbeBackend([.number(-1)])).selectorMatchCount("a[") == nil)
        #expect(await AgentBrowserBridge(backend: ReceiptProbeBackend(error: ReceiptProbeFailure())).selectorMatchCount("#q") == nil)
        #expect(await AgentBrowserBridge(backend: ReceiptProbeBackend([.number(5)])).selectorMatchCount(nil) == nil)
        #expect(await AgentBrowserBridge(backend: ReceiptProbeBackend([.number(5)])).selectorMatchCount("") == nil)
    }

    /// The element's own words ride on the receipt, capped and whitespace-collapsed by the page
    /// side; nil when the element has none and no aria-label / value / placeholder either.
    @Test func theBridgeReadsTheElementsOwnText() async {
        let backend = ReceiptProbeBackend([.string("BELTED FAUX SUEDE JACKET")])
        #expect(await AgentBrowserBridge(backend: backend).elementText(alohaId: "c1") == "BELTED FAUX SUEDE JACKET")
        #expect(backend.scripts[0].contains(#"[aloha-id="c1"]"#))
        #expect(await AgentBrowserBridge(backend: ReceiptProbeBackend([.string("")])).elementText(alohaId: "c1") == nil)
        #expect(await AgentBrowserBridge(backend: ReceiptProbeBackend(error: ReceiptProbeFailure())).elementText(alohaId: "c1") == nil)
    }

    /// The focused element's id, read for the press-keys receipt; nil when nothing has focus.
    @Test func theBridgeNamesTheFocusedElement() async {
        #expect(await AgentBrowserBridge(backend: ReceiptProbeBackend([.string("2766-66bf57a8-2")])).focusedElementAlohaId() == "2766-66bf57a8-2")
        #expect(await AgentBrowserBridge(backend: ReceiptProbeBackend([.string("")])).focusedElementAlohaId() == nil)
        #expect(await AgentBrowserBridge(backend: ReceiptProbeBackend(error: ReceiptProbeFailure())).focusedElementAlohaId() == nil)
    }
}
