import Testing
import Foundation
@testable import BrowserTools

/// The observation ends with the page's typable fields and the id to type into each.
///
/// On Postmill's submit form the body textarea was missing from the rendered markdown on 588 of
/// 1355 observations (43%, runs 34314082894 and 34276664037) while the walk had id'd it every
/// time -- so the model typed the post body into the neighbouring "Markdown allowed." span and
/// submitted an empty post. The trailer is built from the nodes the walk already returned (no DOM
/// query), appended AFTER the token cap, and marks a field the model cannot find above.
@Suite struct FormFieldTrailerTests {

    private func field(_ id: String, _ tag: String, _ attrs: [String: String] = [:]) -> DomNode {
        DomNode(
            id: id,
            element: DomElement(tagName: tag, attributes: attrs),
            interactivity: DomInteractivity(isInteractive: true, isInput: true, isHighlighted: true),
            positioning: DomPositioning(isVisible: true))
    }

    @Test func namesEachTypableFieldWithTheIdToTypeInto() {
        let nodes = [
            field("3f5c-0001", "input", ["name": "submission[title]", "type": "text"]),
            field("3f5c-0002", "textarea", ["name": "submission[body]"]),
        ]
        let view = "input(\"Title\") {aloha-id=\"3f5c-0001\" input}\ntextarea(\"Body\") {aloha-id=\"3f5c-0002\" textarea}"
        let out = AgentDOMService.formFieldTrailer(nodes, renderedInto: view)
        #expect(out.hasPrefix("FORM FIELDS ON THIS PAGE"))
        #expect(out.contains("pass one of these ids to page_type"))
        #expect(out.contains("  3f5c-0001 (submission[title]) input"))
        #expect(out.contains("  3f5c-0002 (submission[body]) textarea"))
        #expect(!out.contains("not in the view"))
    }

    /// The marker is membership of the id in the RENDERED markdown -- the model's actual view --
    /// not the walker's highlight flag, which fired only on fields that are never highlighted at
    /// all and never once on the body textarea the trailer exists for.
    @Test func aFieldTheViewDoesNotShowIsMarked() {
        let nodes = [
            field("3f5c-0001", "input", ["name": "submission[title]"]),
            field("3f5c-0002", "textarea", ["name": "submission[body]"]),
        ]
        let view = "input(\"Title\") {aloha-id=\"3f5c-0001\" input}\nMarkdown allowed."
        let out = AgentDOMService.formFieldTrailer(nodes, renderedInto: view)
        #expect(out.contains("3f5c-0002 (submission[body]) textarea  [not in the view above]"))
        #expect(!out.contains("3f5c-0001 (submission[title]) input  [not"))
    }

    /// The heading names page_type, so a `<select>` -- a page_select target -- is not listed.
    /// Listing it made the model choose the forum on Postmill's userFlag dropdown 160-193 times
    /// per run.
    @Test func selectsAreNotPageTypeTargets() {
        let nodes = [
            field("3f5c-0003", "select", ["name": "submission[userFlag]"]),
            field("3f5c-0001", "input", ["name": "submission[title]"]),
        ]
        let out = AgentDOMService.formFieldTrailer(nodes, renderedInto: "")
        #expect(!out.contains("userFlag"))
        #expect(!out.contains("select"))
        #expect(out.contains("3f5c-0001"))
    }

    /// Matching `page_type`'s own eligibility: no hidden inputs, checkboxes, radios, buttons,
    /// files or passwords -- which is also where CSRF tokens and honeypots live.
    @Test func nonTextInputsAreLeftOut() {
        let kinds = ["hidden", "checkbox", "radio", "submit", "button", "reset", "file", "image", "range", "color", "password", "PASSWORD"]
        let nodes = kinds.enumerated().map { i, kind in
            field("3f5c-\(1000 + i)", "input", ["name": "k_\(kind)", "type": kind])
        } + [field("3f5c-2000", "input", ["name": "submission[title]", "type": "text"]),
             field("3f5c-2001", "input", ["name": "q"]),
             field("3f5c-2002", "input", ["name": "when", "type": "date"])]
        let out = AgentDOMService.formFieldTrailer(nodes, renderedInto: "")
        for kind in kinds { #expect(!out.contains("k_\(kind)")) }
        #expect(out.contains("3f5c-2000 (submission[title]) input"))
        #expect(out.contains("3f5c-2001 (q) input"))
        #expect(out.contains("3f5c-2002 (when) input"))
    }

    @Test func theNameFallsBackToAriaLabelThenPlaceholderAndIsClipped() {
        let long = String(repeating: "n", count: 60)
        let nodes = [
            field("3f5c-0001", "input", ["aria-label": "Search"]),
            field("3f5c-0002", "input", ["placeholder": "City"]),
            field("3f5c-0003", "input", [:]),
            field("3f5c-0004", "input", ["name": long]),
        ]
        let out = AgentDOMService.formFieldTrailer(nodes, renderedInto: "")
        #expect(out.contains("  3f5c-0001 (Search) input"))
        #expect(out.contains("  3f5c-0002 (City) input"))
        #expect(out.contains("  3f5c-0003 input"))
        #expect(out.contains("(\(String(repeating: "n", count: 40))) input"))
        #expect(!out.contains(long))
    }

    @Test func aPageWithNoTypableFieldRendersNoTrailer() {
        let nodes = [
            field("3f5c-0001", "button"),
            field("3f5c-0002", "select"),
            field("3f5c-0003", "input", ["type": "checkbox"]),
        ]
        #expect(AgentDOMService.formFieldTrailer(nodes, renderedInto: "").isEmpty)
        #expect(AgentDOMService.formFieldTrailer([], renderedInto: "").isEmpty)
    }

    @Test func aNodeWithoutAnIdCannotBeTypedIntoAndIsSkipped() {
        let out = AgentDOMService.formFieldTrailer([field("", "textarea", ["name": "body"])], renderedInto: "")
        #expect(out.isEmpty)
    }

    /// Twelve lines, so a long form cannot grow the observation past what the cap saved.
    @Test func isBoundedAtTwelveLines() {
        let nodes = (0..<30).map { field("3f5c-\(5000 + $0)", "input", ["name": "f\($0)"]) }
        let out = AgentDOMService.formFieldTrailer(nodes, renderedInto: "")
        let lines = out.split(separator: "\n")
        #expect(lines.count == 13)
        #expect(out.contains("f11"))
        #expect(!out.contains("f12"))
    }
}
