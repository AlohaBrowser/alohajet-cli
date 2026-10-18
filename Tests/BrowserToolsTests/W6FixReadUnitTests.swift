import Testing
import Foundation
import ToolABI
@testable import BrowserTools

// THE W6 CLIENT REVIEW'S READ FINDINGS, unit level; the real-browser half is
// `RealBrowserW6FixReadTests`.

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

@Suite("W6 review: short leaves, checkbox states, secret fields")
struct W6FixReadUnitTests {

    @Test func aLoneZeroOrGlyphIsChromeAndANumberOrLetterIsNot() {
        #expect(isBareZeroOrGlyph("0"))
        #expect(isBareZeroOrGlyph("00"))
        #expect(isBareZeroOrGlyph("--"))
        #expect(isBareZeroOrGlyph("»"))
        #expect(!isBareZeroOrGlyph("1"))
        #expect(!isBareZeroOrGlyph("#1"))
        #expect(!isBareZeroOrGlyph("A"))
        #expect(!isBareZeroOrGlyph("$0"))
        // A text node standing alone: "0" is dropped, "1" and "A" are lines.
        let zero = node("z", tag: "div", children: ["zt"])
        let one = node("o", tag: "div", children: ["ot"])
        let grade = node("g", tag: "span", children: ["gt"])
        let out = serializeFullMarkdown([zero, text("zt", "0"), one, text("ot", "1"), grade, text("gt", "A")])
        #expect(out.split(separator: "\n").map(String.init) == ["1", "A"], "\(out)")
        // A token of a code listing keeps its zero (`border-spacing: 0`).
        let code = node("c", tag: "span", children: ["ct"])
        let token = node("ct", tag: "span", text: "0", nodeType: "TEXT_NODE", attributes: ["aloha-code": "1"])
        #expect(serializeFullMarkdown([code, token]) == "0")
    }

    @Test func aSeparatorBetweenTwoNumbersJoinsThem() {
        let p = node("p", tag: "p", text: "Rating: 4/5", children: ["t1", "s4", "sl", "s5"])
        let out = serializeFullMarkdown([p, text("t1", "Rating:"), node("s4", tag: "span", children: ["n4"]), text("n4", "4"),
                                         text("sl", "/"), node("s5", tag: "span", children: ["n5"]), text("n5", "5")])
        #expect(out == "Rating: 4/5", "\(out)")
    }

    @Test func aSentenceHoldingALinkIsOneLineAndAMenuIsNot() {
        let div = node("d", tag: "div", text: "Step 3 of 4: Edit", children: ["t1", "b3", "t2", "b4", "a"])
        let nodes = [div, text("t1", "Step"), node("b3", tag: "b", children: ["n3"]), text("n3", "3"), text("t2", "of"),
                     node("b4", tag: "b", children: ["n4"]), text("n4", "4"),
                     node("a", tag: "a", text: "Edit", interactive: true, attributes: ["href": "#edit"])]
        let out = serializeFullMarkdown(nodes)
        #expect(out == #"Step 3 of 4 [Edit] {aloha-id="a" a}"#, "\(out)")
        // Three links: a menu, read link by link.
        let menu = node("m", tag: "div", text: "Go Home About Contact", children: ["g", "a1", "a2", "a3"])
        let links = (1...3).map { node("a\($0)", tag: "a", text: "L\($0)", interactive: true, attributes: ["href": "/\($0)"]) }
        let menuOut = serializeFullMarkdown([menu, text("g", "Go")] + links)
        #expect(menuOut.split(separator: "\n").count == 4, "\(menuOut)")
    }

    @Test func aTriStateBoxIsPartlyCheckedAndAnUnlabelledBoxPrintsNoValue() {
        let ind = node("i", tag: "input", text: "on", interactive: true, attributes: ["aria-label": "Select all"],
                       inputData: DomInputData(type: "checkbox", value: "on", checked: false, indeterminate: true))
        let yes = node("y", tag: "input", text: "yes", interactive: true,
                       inputData: DomInputData(type: "checkbox", value: "yes", checked: false))
        let out = serializeFullMarkdown([ind, yes])
        #expect(out.contains(#"input(checkbox, partly checked, "Select all") {aloha-id="i" input}"#), "\(out)")
        #expect(out.contains(#"input(checkbox, unchecked) {aloha-id="y" input}"#), "\(out)")
        #expect(checkState(DomInputData(type: "radio", checked: true)) == "checked")
        #expect(checkState(DomInputData(type: "text", value: "x")) == nil)
    }

    /// A label standing in for a hidden box says its state and keeps its id; it is never deduped
    /// against the text around it.
    @Test func aLabelStandingInForAHiddenBoxSaysItsState() {
        let p = node("p", tag: "p", text: "[x] Home folder", children: ["l"])
        let label = node("l", tag: "label", text: "[x] Home folder", interactive: true,
                         inputData: DomInputData(type: "checkbox", value: "", checked: true), children: ["s1", "s2"])
        let out = serializeFullMarkdown([p, label, node("s1", tag: "span", text: "[x]"), node("s2", tag: "span", text: "Home folder")])
        #expect(out.contains(#"[[x] Home folder] [checkbox: checked] {aloha-id="l" label}"#), "\(out)")
    }

    /// A key, a token, a secret, a recovery code or a seed phrase is a secret by its words or by
    /// the shape of its value; a word that only contains one is not.
    @Test func keysTokensAndRecoveryCodesAreSecrets() {
        func secret(_ attributes: [String: String], value: String = "x1y2z3", placeholder: String? = nil) -> Bool {
            isSecretInputField(type: "text", autocomplete: "", attributes: attributes, placeholder: placeholder, value: value)
        }
        #expect(secret(["name": "api_key"]))
        #expect(secret(["aria-label": "API key"]))
        #expect(secret(["id": "accessToken"]))
        #expect(secret(["name": "client-secret"]))
        #expect(secret(["aria-label": "Recovery codes"]))
        #expect(secret(["aria-label": "Seed phrase"]))
        #expect(secret([:], placeholder: "Your mnemonic"))
        #expect(secret(["aria-label": "Paste here"], value: "sk-live-abcdef123456"))
        #expect(secret([:], value: "ghp_abcdefghijklmnopqrstuvwxyz0123"))
        #expect(secret([:], value: "AKIAABCDEFGHIJKLMNOP"))
        #expect(!secret(["name": "secretary_name"]))
        #expect(!secret(["name": "city"], value: "Tokyo"))
        #expect(!secret(["aria-label": "Recovery email"], value: "a@b.test"))
        #expect(!secret(["name": "tokenizer"]))
    }
}
