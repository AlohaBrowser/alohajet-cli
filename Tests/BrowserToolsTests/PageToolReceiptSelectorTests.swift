import Foundation
import Testing
import ToolABI
@testable import BrowserTools

/// The re-resolvable selector on the page-tool receipt — and why it had to move there.
/// The `aloha_id` beside it is stable across walks but is a hash, so a trace consumer has no
/// page to resolve it against; that is what this string is for.
///
/// The derivation (`StepTraceSelector`) and the snapshot lookup (`CDPTabHandle.traceDomNode`) both
/// already shipped, tested, cheap: the lookup is a pure read of the DOM service's most recent snapshot,
/// no CDP round-trip. But the only consumer was the step-trace artifact behind `ALOHAJET_TRACE_STEPS`,
/// which nothing in this package sets — so a working, covered capability produced nothing anybody read.
///
/// On the receipt it rides the transport line stream every consumer already reads.
struct PageToolReceiptSelectorTests {

    /// A tab whose snapshot holds the nodes we name, so no browser is needed.
    private struct FakeTab: StepTraceTab {
        var traceTabId: String = "tab-1"
        var traceTabURL: String = "http://shop.example/admin"
        var traceTabTitle: String? = "Admin"
        var nodes: [String: DomNode] = [:]

        func captureInteractMarkdown() async throws -> StepTraceMarkdown {
            StepTraceMarkdown(markdown: "", screenshotBase64: nil)
        }

        func captureAccessibilityTree() async throws -> JSValue { .null }

        func traceDomNode(forAlohaId alohaId: String) -> DomNode? { nodes[alohaId] }
    }

    private func node(_ id: String, tag: String, _ attributes: [String: String]) -> DomNode {
        DomNode(id: id, element: DomElement(tagName: tag, attributes: attributes))
    }

    @Test func anIdBearingElementYieldsItsSelector() {
        let tab = FakeTab(nodes: ["1g": node("1g", tag: "input", ["id": "search-input"])])
        #expect(PageToolReceipt.durableSelector(alohaId: "1g", tab: tab) == "#search-input")
        #expect(PageToolReceipt.selectorNote(alohaId: "1g", tab: tab) == " [selector=#search-input]")
    }

    @Test func theNoteIsEmptyAtEveryGapRatherThanGuessing() {
        let tab = FakeTab(nodes: ["1g": node("1g", tag: "div", [:])])
        // No tab at all.
        #expect(PageToolReceipt.selectorNote(alohaId: "1g", tab: nil) == "")
        // An id the snapshot does not hold — the page navigated after the tool ran.
        #expect(PageToolReceipt.selectorNote(alohaId: "9z", tab: tab) == "")
        // An empty id.
        #expect(PageToolReceipt.selectorNote(alohaId: "", tab: tab) == "")
        // A node with nothing stable on it. A guessed selector is worse than none: it fails
        // silently when replayed, which is indistinguishable from the agent being wrong.
        #expect(PageToolReceipt.selectorNote(alohaId: "1g", tab: tab) == "")
    }

    @Test func theClickReceiptCarriesTheSelectorWithoutLosingTheId() {
        // The id must stay: it is what the model reuses THIS turn. The selector is for whoever reads the
        // trace afterwards. Appended, so `tracesteps.parse_trace` — which keys on `tool-call:` /
        // `tool-result` and passes the remainder through — is unaffected.
        let result = PageClickExecutorTool.interpret(
            AgentActionResult(output: "", isError: false,
                              pendingResults: [PendingResult(type: "click", success: true, error: nil)]),
            route: PageClickExecutorTool.ClickRoute(call: "click", pendingType: "click"),
            alohaId: "1g", clickType: "single",
            urlBefore: "http://shop.example/a", urlAfter: "http://shop.example/a",
            selectorNote: " [selector=#add-to-cart]")
        let output = result.output
        #expect(output.contains("\"1g\""))
        #expect(output.contains("[selector=#add-to-cart]"))
        #expect(result.isError == nil)
    }

    @Test func aFailedClickCarriesNoSelector() {
        // A failed action is not a procedure step, so it must not be minted as one.
        let result = PageClickExecutorTool.interpret(
            AgentActionResult(output: "", isError: false,
                              pendingResults: [PendingResult(type: "click", success: false,
                                                             error: "element not found")]),
            route: PageClickExecutorTool.ClickRoute(call: "click", pendingType: "click"),
            alohaId: "1g", clickType: "single", selectorNote: " [selector=#add-to-cart]")
        #expect(result.isError == true)
        #expect(!result.output.contains("selector="))
    }
}
