import Testing
import Foundation
import ToolABI
@testable import BrowserTools

// MARK: - An id a generator wrote is a handle for one render only
//
// MEASURED, across two runs of one preset on the same stand: Magento's admin gave the SAME
// quantity field `#CD26XAH` in one session and `#JV2FMF8` in the next. A scenario minted on
// either cannot replay, and the agent's run 35095614777 shows both endings —
// `WriteStepUnresolved(kind: "type", selector: "#XODHUST")` on two attempts and
// `waitFor timed out … #VL8WV5X` on a third.
//
// The ladder's own header already says a guessed selector is worse than no selector. This is
// the same rule applied one rung higher: an id that will not resolve next time is a guess
// wearing the clothes of the most stable rung there is.

/// Same shape as `StepTraceSelectorTests`' own builder: the tag plus the raw attribute bag,
/// which is all the derivation reads.
private func generatedIdNode(id: String? = nil, name: String? = nil,
                             tag: String = "input", xpath: String? = nil) -> DomNode {
    var attributes: [String: String] = [:]
    if let id { attributes["id"] = id }
    if let name { attributes["name"] = name }
    return DomNode(id: "a1", element: DomElement(tagName: tag, attributes: attributes, xpath: xpath))
}

@Suite struct StepTraceGeneratedIDTests {

    @Test("the four ids measured on the stand are all refused")
    func generatedIdsAreRefused() {
        for id in ["JV2FMF8", "CD26XAH", "VL8WV5X", "XODHUST"] {
            #expect(StepTraceSelector.looksGenerated(id), "\(id) should read as generated")
        }
    }

    @Test("ids a person writes keep their rung")
    func authoredIdsSurvive() {
        for id in ["save-button", "order-view-cancel-button", "fulltext", "qty",
                   "user_biography_biography", "sales_report_from", "tab-review", "searchForm"] {
            #expect(!StepTraceSelector.looksGenerated(id), "\(id) should read as authored")
        }
    }

    @Test("a generated id loses to the form-field name, which outlives the render")
    func theNameWinsOverAGeneratedId() {
        let selector = stableCSSSelector(for: generatedIdNode(id: "JV2FMF8", name: "product[qty]"))
        #expect(selector == "[name=\"product[qty]\"]")
    }

    @Test("with nothing else on the node it falls all the way to the position path")
    func positionIsPreferredToAnIdThatCannotResolve() {
        let selector = stableCSSSelector(for: generatedIdNode(id: "XODHUST", xpath: "/body/div[3]/form/input[2]"))
        #expect(selector == "body>div:nth-of-type(3)>form>input:nth-of-type(2)")
    }

    @Test("an authored id still beats everything below it")
    func theAuthoredIdStillWins() {
        let selector = stableCSSSelector(
            for: generatedIdNode(id: "save-button", name: "save", xpath: "/body/div[3]/form/input[2]"))
        #expect(selector == "#save-button")
    }

    // MARK: React 19 and component-library ids (github-ss r5, 2026-09-22)

    @Test("React 19 useId output is generated, in every spelling GitHub and React 19.1 use")
    func reactUseIdsAreRefused() {
        for id in ["_r_i_", "_r_1d_", "_R_vclld65_", "_r_1d_--label", "«r1»", "radix-_r_3_"] {
            #expect(StepTraceSelector.looksGenerated(id), "\(id) should read as generated")
        }
    }

    @Test("component libraries' counters are generated")
    func libraryCountersAreRefused() {
        for id in ["radix-1", "headlessui-menu-button-2", "mui-5", "downshift-0-item-3", "react-select-2-input", "ember1234"] {
            #expect(StepTraceSelector.looksGenerated(id), "\(id) should read as generated")
        }
    }

    @Test("short counters an id generator hands out are generated (translate.google.com's #ucj-3)")
    func shortCountersAreRefused() {
        for id in ["ucj-3", "c12", "j_5", "ab-1024"] {
            #expect(StepTraceSelector.looksGenerated(id), "\(id) should read as generated")
        }
        for id in ["save-button", "main_content-2", "tab-review", "section-12", "step-2-of-3", "qty"] {
            #expect(!StepTraceSelector.looksGenerated(id), "\(id) should read as authored")
        }
    }

    @Test("a CSS-modules hash after `___` is hashed even without a digit (github.com's search button)")
    func cssModuleHashesAreRefused() {
        #expect(StepTraceSelector.looksHashed("Primer_Brand__Button-module__Button--size-small___zQrEw"))
        #expect(StepTraceSelector.looksHashed("Header_nav___aB3dE"))
        #expect(StepTraceSelector.stableClassTokens("Primer_Brand__Button Primer_Brand__Button-module__Button--size-small___zQrEw").isEmpty == false)
        #expect(!StepTraceSelector.stableClassTokens("Primer_Brand__Button-module__Button--size-small___zQrEw").contains { $0.hasSuffix("zQrEw") })
        for token in ["block__element", "block__element--modifier", "col-md-6", "btn___", "Header___longer-than-ten-chars"] {
            #expect(!StepTraceSelector.looksHashed(token), "\(token) should read as authored")
        }
    }

    @Test("an underscore-separated authored id is not a React id")
    func underscoredAuthoredIdsSurvive() {
        for id in ["_root", "_r", "_r_", "_r_i", "_rate_", "r_1_", "main_content-2", "_reviews_tab_", "_R_"] {
            #expect(!StepTraceSelector.looksGenerated(id), "\(id) should read as authored")
        }
    }

    @Test("the sort button's generated id loses to its own test hook")
    func githubSortButtonUsesItsTestId() {
        let node = DomNode(id: "s", element: DomElement(tagName: "button", attributes: [
            "id": "_r_i_", "data-testid": "sort-button", "type": "button", "aria-haspopup": "true"], xpath: "/body/div/button"))
        #expect(stableCSSSelector(for: node) == "[data-testid=\"sort-button\"]")
    }
}
