import Testing
import Foundation
@testable import BrowserTools
import ToolABI

// DEFECT #1: `read` deleted every inline link's words from a paragraph and printed the
// paragraph up to three times — once as `comprehensiveText`'s direct-text pass, once as its
// `getFirstDescendantText` pass (both with the link text missing), then once more as one line
// per text fragment. The result was fluent, grammatical English with the nouns removed, which
// is the worst possible failure mode for a page reader.
//
// Live shape reproduced against real Chromium 152 (headless, `--cdp`), on
//   <p>Swift is a <b>compiled</b> language created by <a>Chris Lattner</a> in 2010 for
//      <a>Apple Inc.</a> and maintained by <a>the community</a>. It uses an <a>LLVM</a>-based
//      compiler.</p>
// Before: 13 lines, no link text in the paragraph. After: one line, every noun present.

private func node(
    _ id: String, _ tag: String,
    attributes: [String: String] = [:],
    text: String? = nil,
    comprehensive: String? = nil,
    nodeType: String? = nil,
    interactive: Bool = false,
    children: [String] = []
) -> DomNode {
    DomNode(
        id: id,
        nodeType: nodeType,
        element: DomElement(tagName: tag, attributes: attributes, textContent: text),
        content: DomContent(comprehensiveText: comprehensive ?? text),
        interactivity: DomInteractivity(isInteractive: interactive, isHighlighted: interactive, isTopElement: interactive),
        positioning: DomPositioning(distanceToViewportBorder: 0, isInViewport: true, isVisible: true),
        children: children)
}

private func textNode(_ id: String, _ text: String) -> DomNode {
    node(id, "span", text: text, nodeType: "TEXT_NODE")
}

/// The paragraph exactly as the live walker reports it: the `<p>`'s own `comprehensiveText` is
/// the DOUBLED, link-stripped string the in-page collector produces (direct text nodes, then
/// `getFirstDescendantText`, which stops at every interactive descendant). The real text only
/// exists in the children, which is why the renderer must compose the line from them.
private func swiftParagraph() -> [DomNode] {
    let broken = "Swift is a language created by in 2010 for and maintained by . It uses an -based compiler."
        + " Swift is a compiled language created by in 2010 for and maintained by . It uses an -based compiler."
    return [
        node("p1", "p", comprehensive: broken,
             children: ["t1", "b1", "t2", "a1", "t3", "a2", "t4", "a3", "t5", "a4", "t6"]),
        textNode("t1", "Swift is a"),
        node("b1", "b", children: ["bt"]),
        textNode("bt", "compiled"),
        textNode("t2", "language created by"),
        node("a1", "a", attributes: ["href": "/lattner"], text: "Chris Lattner", interactive: true),
        textNode("t3", "in 2010 for"),
        node("a2", "a", attributes: ["href": "/apple"], text: "Apple Inc.", interactive: true),
        textNode("t4", "and maintained by"),
        node("a3", "a", attributes: ["href": "/community"], text: "the community", interactive: true),
        textNode("t5", ". It uses an"),
        node("a4", "a", attributes: ["href": "/llvm"], text: "LLVM", interactive: true),
        textNode("t6", "-based compiler."),
    ]
}

@Suite struct ProseWithInlineLinksTests {

    @Test func inlineLinkTextSurvivesInTheParagraph() {
        let out = serializeFullMarkdown(swiftParagraph())
        // Every noun must be IN THE SENTENCE, not merely somewhere in the output: the old
        // renderer re-emitted the link text on lines of its own while deleting it from the
        // prose, which is precisely the wreckage a reader hallucinates over.
        let sentence = out.split(separator: "\n").first { $0.contains("Swift is a") }.map(String.init) ?? ""
        for noun in ["Chris Lattner", "Apple Inc.", "the community", "LLVM", "compiled"] {
            #expect(sentence.contains(noun), "inline text \"\(noun)\" was deleted from the prose:\n\(out)")
        }
    }

    @Test func theParagraphIsEmittedExactlyOnce() {
        let out = serializeFullMarkdown(swiftParagraph())
        let lines = out.split(separator: "\n").map(String.init)
        #expect(lines.count == 1, "paragraph emitted as \(lines.count) lines:\n\(out)")
        // Each fragment appears once, not two or three times.
        for fragment in ["Swift is a", "Chris Lattner", "-based compiler."] {
            let n = out.components(separatedBy: fragment).count - 1
            #expect(n == 1, "\"\(fragment)\" emitted \(n)x:\n\(out)")
        }
        // And the doubled, link-stripped `comprehensiveText` never reaches the output.
        #expect(!out.contains("Swift is a language created by"), "link-stripped text leaked:\n\(out)")
    }

    @Test func inlineLinksKeepTheirActionableIdsInTheSentence() {
        let out = serializeFullMarkdown(swiftParagraph(), DomSerializeOptions(includeUrls: true))
        for id in ["a1", "a2", "a3", "a4"] {
            #expect(out.contains("aloha-id=\"\(id)\""), "link \(id) lost its actionable id:\n\(out)")
        }
        #expect(out.contains("[Chris Lattner](/lattner)"), "link markup lost:\n\(out)")
        // The whole sentence, ids included, stays on ONE line so the trailer parser sees them.
        #expect(out.split(separator: "\n").count == 1)
    }

    @Test func sentencePunctuationDoesNotDriftOffTheWord() {
        let out = serializeFullMarkdown(swiftParagraph())
        #expect(out.contains("}. It uses an"), "space inserted before the full stop:\n\(out)")
    }

    /// A heading is prose too: `<h2><a>Title</a></h2>` must keep the title and the link id.
    @Test func headingKeepsItsInlineLinkText() {
        let nodes = [
            node("h", "h2", comprehensive: "", children: ["ha"]),
            node("ha", "a", attributes: ["href": "/post/1"], text: "The Swift compiler", interactive: true),
        ]
        let out = serializeFullMarkdown(nodes)
        #expect(out.hasPrefix("## "), "heading prefix lost:\n\(out)")
        #expect(out.contains("The Swift compiler"))
        #expect(out.contains("aloha-id=\"ha\""))
        #expect(out.split(separator: "\n").count == 1, "heading emitted twice:\n\(out)")
    }

    /// A leaf paragraph (no child nodes) still renders from its own text — the fallback path.
    @Test func plainParagraphWithNoChildrenIsUnchanged() {
        let p = node("p2", "p", comprehensive: "A plain paragraph with no links at all.")
        #expect(serializeFullMarkdown([p]) == "A plain paragraph with no links at all.")
    }
}
