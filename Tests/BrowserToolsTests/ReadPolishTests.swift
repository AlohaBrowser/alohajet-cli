import Testing
import Foundation
import ToolABI
@testable import BrowserTools

// THE READ AND THE RECEIPTS, polished after the 2026-10-18 e2e run (W4 backlog + W5 client review).
// Unit level; the real-browser half is `RealBrowserReadPolishTests`; the receipts half `ReceiptPolishTests`.

private func node(
    _ id: String, tag: String, text: String? = nil, nodeType: String? = nil,
    interactive: Bool = false, attributes: [String: String] = [:], inputData: DomInputData? = nil,
    children: [String] = []
) -> DomNode {
    DomNode(
        id: id, nodeType: nodeType,
        element: DomElement(tagName: tag, attributes: attributes, textContent: text),
        content: DomContent(comprehensiveText: text, inputData: inputData),
        interactivity: DomInteractivity(isInteractive: interactive, isHighlighted: interactive, isTopElement: true),
        positioning: DomPositioning(distanceToViewportBorder: 0, isInViewport: true, isVisible: true),
        children: children)
}

private func text(_ id: String, _ value: String) -> DomNode { node(id, tag: "span", text: value, nodeType: "TEXT_NODE") }

@Suite("read polish: checked state, short leaves, preformatted text")
struct ReadPolishSerializerTests {

    /// A checkbox says whether it is ticked, never the "on" its form would submit
    /// (the-internet /checkboxes, W4: 11 rounds for a 4-round task).
    @Test func aCheckboxSaysWhetherItIsTicked() {
        let unticked = node("c1", tag: "input", text: "on", interactive: true,
                            inputData: DomInputData(type: "checkbox", value: "on", checked: false))
        let ticked = node("c2", tag: "input", text: "on", interactive: true,
                          inputData: DomInputData(type: "checkbox", value: "on", checked: true))
        let radio = node("r1", tag: "input", text: "Large", interactive: true,
                         inputData: DomInputData(type: "radio", value: "large", checked: true))
        let out = serializeFullMarkdown([unticked, ticked, radio])
        #expect(out.contains(#"input(checkbox, unchecked) {aloha-id="c1" input}"#), "\(out)")
        #expect(out.contains(#"input(checkbox, checked) {aloha-id="c2" input}"#), "\(out)")
        #expect(out.contains(#"input(radio, checked, "Large") {aloha-id="r1" input}"#), "\(out)")
        #expect(!out.contains("value=\"on\""), "\(out)")
        // A text field is untouched.
        let field = node("t1", tag: "input", text: "Name", interactive: true, inputData: DomInputData(value: "Jane"))
        #expect(serializeFullMarkdown([field]).contains(#"input("Name", value="Jane")"#))
    }

    /// A custom checkbox / switch states `aria-checked` like a native one.
    @Test func anAriaCheckboxStatesItsState() {
        let on = node("a1", tag: "div", text: "Remember me", interactive: true, attributes: ["role": "checkbox", "aria-checked": "true"])
        let off = node("a2", tag: "div", text: "Dark mode", interactive: true, attributes: ["role": "switch", "aria-checked": "false"])
        let out = serializeFullMarkdown([on, off])
        #expect(out.contains("[Remember me] [aria: CHECKED]"), "\(out)")
        #expect(out.contains("[Dark mode] [aria: NOT CHECKED]"), "\(out)")
    }

    /// TodoMVC's `<span class="todo-count"><strong>1</strong> item left</span>` read "item left".
    /// A span of text and inline formatting is read as one sentence.
    @Test func aCountInsideItsSentenceIsReadWithIt() {
        let span = node("s", tag: "span", text: "1 item left", children: ["strong", "rest"])
        let strong = node("strong", tag: "strong", text: "1")     // its one-character text node was not kept
        let rest = text("rest", "item left")
        let out = serializeFullMarkdown([span, strong, rest])
        #expect(out.split(separator: "\n").map(String.init) == ["1 item left"], "\(out)")
        // A sentence with a control in it is left to the walker, as before.
        let wrap = node("w", tag: "span", text: "by André Gide (about)", children: ["by", "a"])
        let by = text("by", "by")
        let link = node("a", tag: "a", text: "(about)", interactive: true, attributes: ["href": "/a"])
        let out2 = serializeFullMarkdown([wrap, by, link])
        #expect(out2.split(separator: "\n").first == "by", "\(out2)")
    }

    /// A short number standing on its own (a cart badge "1") is kept; a bare "0" is still chrome.
    @Test func aShortNumberIsKeptAndABareZeroIsNot() {
        #expect(isShortNumber("1"))
        #expect(isShortNumber("12"))
        #expect(isShortNumber("2/9"))
        #expect(!isShortNumber("0"))
        #expect(!isShortNumber("00"))
        #expect(!isShortNumber("."))
        #expect(!isShortNumber("ab"))
        let card = node("li", tag: "li", text: "Cart", interactive: true, children: ["badge"])
        let badge = node("badge", tag: "span", text: "3")
        #expect(serializeFullMarkdown([card, badge]).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.contains("3"))
    }

    /// `<pre>` text keeps its lines (the walker marks it `aloha-pre`).
    @Test func preformattedTextKeepsItsLines() {
        #expect(preformattedText("line one\n    line two\t\tend   \n\n\n\nline three\n\n") == "line one\n line two end\n\nline three")
        let pre = node("p", tag: "span", text: "a\nb\nc", nodeType: "TEXT_NODE", attributes: ["aloha-pre": "1"])
        #expect(serializeFullMarkdown([pre]) == "a\nb\nc")
        let plain = node("q", tag: "span", text: "a\nb", nodeType: "TEXT_NODE")
        #expect(serializeFullMarkdown([plain]) == "a b")
    }
}

@Suite("a screenshot's media type is what its bytes are")
struct DataUrlImageMediaTypeTests {
    /// The desktop's capture: PNG bytes labelled JPEG (W6 e2e). The bytes win.
    @Test func theBytesDecideTheMediaType() {
        #expect(parseDataUrlImage("data:image/jpeg;base64,iVBORw0KGgoAAAANS")?.mediaType == "image/png")
        #expect(parseDataUrlImage("data:image/png;base64,/9j/4AAQSkZJRg")?.mediaType == "image/jpeg")
        #expect(parseDataUrlImage("data:image/png;base64,R0lGODlhAQAB")?.mediaType == "image/gif")
        #expect(parseDataUrlImage("data:image/jpeg;base64,UklGRiQAAABXRUJQ")?.mediaType == "image/webp")
        // Unknown bytes: the label, as before.
        #expect(parseDataUrlImage("data:image/png;base64,AAAA")?.mediaType == "image/png")
        #expect(parseDataUrlImage("data:image/svg+xml;base64,AAAA")?.mediaType == "image/jpeg")
        #expect(parseDataUrlImage("not a data url") == nil)
    }
}
