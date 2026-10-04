import Testing
import Foundation
@testable import BrowserTools

/// Serialization follows the tree, so an element's place in the TEXT is its place in the DOCUMENT.
/// Every portal-rendering widget breaks that: it appends its dropdown to the end of `<body>`, so a
/// list sitting directly under a combobox on screen lands after the footer in the markdown.
///
/// WebArena run 33889241270, tasks 647/649: Postmill's submit form carries
/// `<select id="submission_forum" required>` whose first option is `<option value="">Choose one...`,
/// hidden behind select2. The model filled title and body, opened the combobox, never picked a
/// forum, and clicked `[Create submission]` five times -- each click landing, each refused by HTML5
/// validation, which draws a native bubble rather than a DOM node, so the page came back
/// byte-identical every time. The options were in the snapshot all along, 500 lines below the form,
/// after the footer.
@Suite struct ReattachOpenPopupsTests {

    private func node(_ id: String, _ attrs: [String: String] = [:],
                      children: [String] = []) -> DomNode {
        DomNode(id: id, element: DomElement(tagName: "span", attributes: attrs), children: children)
    }

    /// Ownership comes from ARIA, which is what select2, Radix, Headless UI and every hand-rolled
    /// combobox already publish for screen readers -- so this fixes the class, not one site.
    private var select2Shape: [DomNode] {
        [node("body", [:], children: ["form", "footer", "portal"]),
         node("form", [:], children: ["combo"]),
         node("combo", ["aria-expanded": "true", "aria-owns": "sel2-results"]),
         node("footer"),
         node("portal", [:], children: ["ul"]),
         node("ul", ["id": "sel2-results"], children: ["opt1"]),
         node("opt1")]
    }

    private func children(_ nodes: [DomNode], _ id: String) -> [String] {
        nodes.first { $0.id == id }?.children ?? []
    }

    @Test func theOpenListMovesUnderTheComboboxThatOwnsIt() {
        let out = reattachOpenPopups(select2Shape)
        #expect(children(out, "combo") == ["ul"])
        #expect(children(out, "portal").isEmpty)
    }

    /// And it stops being a stray root -- which is how it came to be rendered after the footer.
    @Test func theListIsNoLongerAnOrphan() {
        let out = reattachOpenPopups(select2Shape)
        let referenced = Set(out.flatMap(\.children))
        #expect(referenced.contains("ul"))
    }

    /// The serializer is tree-driven, so the moved list renders under its owner in the text.
    @Test func theOptionsRenderUnderTheComboboxInTheMarkdown() {
        var nodes = select2Shape
        func interactive(_ id: String, _ text: String) {
            guard let i = nodes.firstIndex(where: { $0.id == id }) else { return }
            nodes[i].element.textContent = text
            nodes[i].content.comprehensiveText = text
            nodes[i].interactivity = DomInteractivity(isInteractive: true, isHighlighted: true, isTopElement: true)
        }
        interactive("combo", "Choose one")
        interactive("footer", "Postmill")
        interactive("opt1", "allentown")
        let markdown = serializeFullMarkdown(reattachOpenPopups(nodes))
        let combo = markdown.range(of: "Choose one")
        let footer = markdown.range(of: "Postmill")
        let option = markdown.range(of: "allentown")
        #expect(combo != nil && footer != nil && option != nil)
        if let combo, let footer, let option {
            #expect(combo.lowerBound < option.lowerBound)
            #expect(option.lowerBound < footer.lowerBound)
        }
    }

    /// A closed popup is where it belongs already: `aria-expanded="false"` must move nothing, so a
    /// page with no dropdown open serializes exactly as before.
    @Test func aClosedPopupIsUntouched() {
        let input = [node("body", [:], children: ["combo", "portal"]),
                     node("combo", ["aria-expanded": "false", "aria-owns": "x"]),
                     node("portal", ["id": "x"])]
        let out = reattachOpenPopups(input)
        #expect(children(out, "combo").isEmpty)
        #expect(children(out, "body") == ["combo", "portal"])
    }

    /// A page with no `id` attributes at all cannot have a resolvable owner, and returns unchanged
    /// without doing any work.
    @Test func aPageWithNoIdsIsUntouched() {
        let input = [node("body", [:], children: ["combo"]),
                     node("combo", ["aria-expanded": "true", "aria-controls": "missing"])]
        #expect(children(reattachOpenPopups(input), "combo").isEmpty)
    }

    /// Already nested: the DOM and the screen agree, so nothing moves and nothing duplicates.
    @Test func aPopupAlreadyInsideItsOwnerIsLeftAlone() {
        let input = [node("body", [:], children: ["combo"]),
                     node("combo", ["aria-expanded": "true", "aria-controls": "x"], children: ["ul"]),
                     node("ul", ["id": "x"])]
        #expect(children(reattachOpenPopups(input), "combo") == ["ul"])
    }

    /// Never pull an ANCESTOR of the owner underneath it: the serializer walks `children`, so a
    /// cycle would not merely misrender, it would not terminate.
    @Test func anAncestorIsNeverPulledUnderItsOwnDescendant() {
        let input = [node("wrap", ["id": "w"], children: ["combo"]),
                     node("combo", ["aria-expanded": "true", "aria-controls": "w"])]
        let out = reattachOpenPopups(input)
        #expect(children(out, "combo").isEmpty)
        #expect(children(out, "wrap") == ["combo"])
    }

    /// `aria-controls` is a token LIST. The popup is the first token that resolves to a real node.
    @Test func theFirstResolvableTokenWins() {
        let input = [node("body", [:], children: ["combo", "panel"]),
                     node("combo", ["aria-expanded": "true", "aria-controls": "gone alsogone real"]),
                     node("panel", ["id": "real"])]
        #expect(children(reattachOpenPopups(input), "combo") == ["panel"])
    }

    /// A page claiming more open popups than `maxReattachedPopups` is pathological or mid-animation;
    /// moving dozens of subtrees would reorder the document more than it clarifies it.
    @Test func theNumberOfMovesIsCapped() {
        var input = [node("body", [:], children: (0..<6).map { "c\($0)" } + (0..<6).map { "u\($0)" })]
        for i in 0..<6 { input.append(node("c\(i)", ["aria-expanded": "true", "aria-controls": "d\(i)"])) }
        for i in 0..<6 { input.append(node("u\(i)", ["id": "d\(i)"])) }
        let out = reattachOpenPopups(input)
        let movedCount = (0..<6).filter { !children(out, "c\($0)").isEmpty }.count
        #expect(movedCount == maxReattachedPopups)
    }
}
