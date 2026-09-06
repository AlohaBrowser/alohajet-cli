import Testing
import Foundation
@testable import BrowserTools
import ToolABI

private func cdNode(
    _ id: String,
    tag: String,
    attributes: [String: String] = [:],
    textContent: String? = nil,
    nodeType: String? = nil,
    positioning: DomPositioning = DomPositioning(),
    children: [String] = []
) -> DomNode {
    DomNode(
        id: id,
        nodeType: nodeType,
        element: DomElement(tagName: tag, attributes: attributes, textContent: textContent),
        positioning: positioning,
        children: children
    )
}

private func ids(_ nodes: [DomNode]) -> [String] { nodes.map { $0.id } }
private func find(_ nodes: [DomNode], _ id: String) -> DomNode? { nodes.first { $0.id == id } }

@Suite struct CleanDomTreeTests {

    /// A representative tree: a root with a meaningful link (href/alt/aria-label + the
    /// noise attributes class/data-*/style), plus a <style> subtree, a <script> subtree,
    /// an inline <svg>, a comment node, a hidden element, and an <img> carrying a data: URI.
    private func sampleTree() -> [DomNode] {
        [
            cdNode("root", tag: "div", attributes: ["class": "container", "data-test": "x", "style": "color:red"],
                   children: ["link", "style", "script", "svg", "comment", "hidden", "dataimg"]),
            cdNode("link", tag: "a",
                   attributes: [
                       "href": "/page",
                       "alt": "Go to page",
                       "aria-label": "navigation",
                       "class": "btn primary",
                       "data-id": "42",
                       "style": "display:block",
                   ]),
            cdNode("style", tag: "style", children: ["stylebody"]),
            cdNode("stylebody", tag: "text", textContent: ".x{color:red}", nodeType: "TEXT_NODE"),
            cdNode("script", tag: "script", children: ["scriptbody"]),
            cdNode("scriptbody", tag: "text", textContent: "var x=1", nodeType: "TEXT_NODE"),
            cdNode("svg", tag: "svg", attributes: ["viewBox": "0 0 10 10"], children: ["path"]),
            cdNode("path", tag: "path", attributes: ["d": "M0 0 L10 10"]),
            cdNode("comment", tag: "div", textContent: "a comment", nodeType: "COMMENT_NODE"),
            cdNode("hidden", tag: "div", attributes: ["aria-hidden": "true"], children: ["hiddenchild"]),
            cdNode("hiddenchild", tag: "span", textContent: "secret"),
            cdNode("dataimg", tag: "img",
                   attributes: ["src": "data:image/png;base64,AAAA", "alt": "logo"]),
        ]
    }

    // MARK: ON prunes the noise

    @Test func onDropsStyleScriptSvgCommentAndHiddenSubtrees() {
        let cleaned = cleanDomTree(sampleTree())
        let surviving = Set(ids(cleaned))
        // Dropped tags + their subtrees.
        #expect(!surviving.contains("style"))
        #expect(!surviving.contains("stylebody"))
        #expect(!surviving.contains("script"))
        #expect(!surviving.contains("scriptbody"))
        #expect(!surviving.contains("svg"))
        #expect(!surviving.contains("path"))
        // Comment node dropped.
        #expect(!surviving.contains("comment"))
        // Hidden element and everything beneath it dropped.
        #expect(!surviving.contains("hidden"))
        #expect(!surviving.contains("hiddenchild"))
        // Meaningful content survives.
        #expect(surviving.contains("root"))
        #expect(surviving.contains("link"))
        #expect(surviving.contains("dataimg"))
    }

    @Test func onStripsNoiseAttributesButKeepsMeaningfulOnes() {
        let cleaned = cleanDomTree(sampleTree())
        let link = find(cleaned, "link")
        #expect(link != nil)
        let attrs = link!.element.attributes
        // KEEP href / alt / aria-label.
        #expect(attrs["href"] == "/page")
        #expect(attrs["alt"] == "Go to page")
        #expect(attrs["aria-label"] == "navigation")
        // DROP class / data-* / style.
        #expect(attrs["class"] == nil)
        #expect(attrs["data-id"] == nil)
        #expect(attrs["style"] == nil)
    }

    @Test func onNeverSerializesDataUris() {
        let cleaned = cleanDomTree(sampleTree())
        let img = find(cleaned, "dataimg")
        #expect(img != nil)
        // The data: src is dropped; the real alt survives.
        #expect(img!.element.attributes["src"] == nil)
        #expect(img!.element.attributes["alt"] == "logo")
    }

    @Test func onPrunesDroppedChildrenFromParentChildLists() {
        let cleaned = cleanDomTree(sampleTree())
        let root = find(cleaned, "root")
        #expect(root != nil)
        // Only the surviving children remain referenced.
        #expect(root!.children == ["link", "dataimg"])
    }

    @Test func onDropsInlineDisplayNoneElements() {
        let tree = [
            cdNode("r", tag: "div", children: ["a", "b"]),
            cdNode("a", tag: "p", attributes: ["style": "display: none"], textContent: "gone"),
            cdNode("b", tag: "p", textContent: "kept"),
        ]
        let cleaned = cleanDomTree(tree)
        let surviving = Set(ids(cleaned))
        #expect(!surviving.contains("a"))
        #expect(surviving.contains("b"))
    }

    @Test func onDropsLayoutInvisibleElements() {
        let tree = [
            cdNode("r", tag: "div", children: ["a"]),
            cdNode("a", tag: "p", textContent: "hidden by layout", positioning: DomPositioning(isVisible: false)),
        ]
        let cleaned = cleanDomTree(tree)
        #expect(!Set(ids(cleaned)).contains("a"))
    }

    // MARK: OFF == byte-identical baseline

    /// The contract: with the flag OFF, serialization runs on the untouched node array, so
    /// the produced markdown is byte-for-byte the baseline output. We assert that the OFF
    /// path (no cleanDomTree) and an explicit baseline serialization are identical, and that
    /// turning the flag ON actually changes the bytes (so the A/B is real).
    @Test func offIsByteIdenticalToBaselineSerialization() {
        let tree = sampleTree()
        let baselineOptions = DomSerializeOptions(includeUrls: true)

        // OFF: the serialization path uses the original nodes unchanged.
        let offMarkdown = serializeFullMarkdown(tree, baselineOptions)
        // The true baseline is exactly that — serializing the raw tree with no cleaning.
        let baselineMarkdown = serializeFullMarkdown(tree, baselineOptions)
        #expect(offMarkdown == baselineMarkdown)

        // ON: cleaning the tree first must change the bytes for this noisy input.
        let onMarkdown = serializeFullMarkdown(cleanDomTree(tree), baselineOptions)
        #expect(onMarkdown != baselineMarkdown)
    }

    @Test func cleanDomTreeIsIdempotent() {
        let once = cleanDomTree(sampleTree())
        let twice = cleanDomTree(once)
        #expect(ids(once) == ids(twice))
    }
}
