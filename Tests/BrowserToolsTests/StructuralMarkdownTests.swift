import Testing
import Foundation
@testable import BrowserTools
import ToolABI

// MARK: - Golden tests for the NEW structural-markdown READ observation.
//
// These pin the format the renderer rewrite (plan: warm-soaring-wadler, Part A) must
// produce from `serializeFullMarkdown(nodes, options)`:
//   - content (headings / list items / table rows / paragraphs) is CLEAN, id-free markdown
//   - every actionable element keeps a parseable trailing marker  {aloha-id="ID" tag}
//     so navigation never degrades (tab.click(id) / findByText still resolve)
//   - occlusion legend + [occ:id] markers and scroll markers are preserved
//
// They are RED against the current element-dump renderer (which emits <tag aloha-id="ID" />).
// The Green phase must make serializeFullMarkdown emit EXACTLY the strings asserted here.

private func mkNode(
    _ id: String,
    tag: String,
    attributes: [String: String] = [:],
    textContent: String? = nil,
    comprehensiveText: String? = nil,
    nodeType: String? = nil,
    interactivity: DomInteractivity = DomInteractivity(),
    positioning: DomPositioning = DomPositioning(),
    inputData: DomInputData? = nil,
    optionData: DomOptionData? = nil,
    children: [String] = []
) -> DomNode {
    DomNode(
        id: id,
        nodeType: nodeType,
        element: DomElement(tagName: tag, attributes: attributes, textContent: textContent),
        content: DomContent(comprehensiveText: comprehensiveText, inputData: inputData, optionData: optionData),
        interactivity: interactivity,
        positioning: positioning,
        children: children
    )
}

/// A visible, in-viewport TEXT_NODE carrying `text`. Content text only renders when it
/// passes the `isInViewport` gate, so set it explicitly.
private func textNode(_ id: String, _ text: String) -> DomNode {
    mkNode(id, tag: "span", textContent: text, comprehensiveText: text, nodeType: "TEXT_NODE",
           positioning: DomPositioning(distanceToViewportBorder: 0, isInViewport: true, isVisible: true))
}

/// An in-viewport, hit-testable interactive element (passes the keep-gate: highlighted + top).
private func interactive(
    _ id: String,
    tag: String,
    attributes: [String: String] = [:],
    text: String? = nil,
    inputData: DomInputData? = nil,
    optionData: DomOptionData? = nil,
    children: [String] = []
) -> DomNode {
    mkNode(
        id, tag: tag, attributes: attributes, textContent: text, comprehensiveText: text,
        interactivity: DomInteractivity(isInteractive: true, isHighlighted: true, isTopElement: true),
        positioning: DomPositioning(distanceToViewportBorder: 0, isInViewport: true, isVisible: true),
        inputData: inputData, optionData: optionData, children: children)
}

/// The trailing actionable marker the parser keys on, e.g. `{aloha-id="b1" button}`.
private func trailer(_ id: String, _ tag: String) -> String { "{aloha-id=\"\(id)\" \(tag)}" }

@Suite struct StructuralMarkdownGoldenTests {

    // MARK: heading -> "## text" (content, no id)

    @Test func h2HeadingRendersAsMarkdownHeadingWithoutId() {
        let h = mkNode("h2a", tag: "h2", comprehensiveText: "Featured Products",
                       positioning: DomPositioning(isVisible: true))
        let out = serializeFullMarkdown([h])
        #expect(out == "## Featured Products")
        #expect(!out.contains("aloha-id"))
        #expect(!out.contains("<h2"))
    }

    // MARK: ul with three li -> three "- item" lines (id-free)

    @Test func unorderedListRendersOneDashItemPerLine() {
        let ul = mkNode("ul1", tag: "ul",
                        positioning: DomPositioning(isVisible: true),
                        children: ["li1", "li2", "li3"])
        let li1 = mkNode("li1", tag: "li", comprehensiveText: "Red", positioning: DomPositioning(isVisible: true))
        let li2 = mkNode("li2", tag: "li", comprehensiveText: "Green", positioning: DomPositioning(isVisible: true))
        let li3 = mkNode("li3", tag: "li", comprehensiveText: "Blue", positioning: DomPositioning(isVisible: true))
        let out = serializeFullMarkdown([ul, li1, li2, li3])
        #expect(out == "- Red\n- Green\n- Blue")
        #expect(!out.contains("aloha-id"))
        #expect(!out.contains("<li"))
    }

    // MARK: 2-col table with <th> header + 2 data rows

    @Test func tableRendersPipeRowsWithSeparatorAfterHeader() {
        let table = mkNode("t1", tag: "table", positioning: DomPositioning(isVisible: true),
                           children: ["hr", "r1", "r2"])
        let hr = mkNode("hr", tag: "tr", positioning: DomPositioning(isVisible: true), children: ["thA", "thB"])
        let thA = mkNode("thA", tag: "th", comprehensiveText: "A", positioning: DomPositioning(isVisible: true))
        let thB = mkNode("thB", tag: "th", comprehensiveText: "B", positioning: DomPositioning(isVisible: true))
        let r1 = mkNode("r1", tag: "tr", positioning: DomPositioning(isVisible: true), children: ["a1", "b1"])
        let a1 = mkNode("a1", tag: "td", comprehensiveText: "a", positioning: DomPositioning(isVisible: true))
        let b1 = mkNode("b1", tag: "td", comprehensiveText: "b", positioning: DomPositioning(isVisible: true))
        let r2 = mkNode("r2", tag: "tr", positioning: DomPositioning(isVisible: true), children: ["c2", "d2"])
        let c2 = mkNode("c2", tag: "td", comprehensiveText: "c", positioning: DomPositioning(isVisible: true))
        let d2 = mkNode("d2", tag: "td", comprehensiveText: "d", positioning: DomPositioning(isVisible: true))
        let out = serializeFullMarkdown([table, hr, thA, thB, r1, a1, b1, r2, c2, d2])
        #expect(out == "| A | B |\n| --- | --- |\n| a | b |\n| c | d |")
        #expect(!out.contains("aloha-id"))
        #expect(!out.contains("<t"))
    }

    // MARK: product card -> [Acme](/p/9) {aloha-id="..." a} + price text

    @Test func productCardLinkCarriesMarkdownLinkPriceAndTrailer() {
        // <li><a href="/p/9">Acme</a><span>$19.99</span></li>
        let li = mkNode("card1", tag: "li", positioning: DomPositioning(isVisible: true),
                        children: ["lnk", "price"])
        let lnk = interactive("lnk", tag: "a", attributes: ["href": "/p/9"], text: "Acme")
        let price = textNode("price", "$19.99")
        let out = serializeFullMarkdown([li, lnk, price], DomSerializeOptions(includeUrls: true))
        // The link renders as a markdown link with the actionable trailer, and the
        // sibling price text is present so findByText("Acme") resolves the link id.
        #expect(out.contains("[Acme](/p/9)"))
        #expect(out.contains(trailer("lnk", "a")))
        #expect(out.contains("$19.99"))
        // The id appears ONLY in the trailer (no <a aloha-id=...> dump).
        #expect(!out.contains("<a "))
    }

    // MARK: button -> "[Buy] {aloha-id="..." button}"

    @Test func buttonRendersBracketLabelWithTrailer() {
        let b = interactive("b1", tag: "button", text: "Buy")
        let out = serializeFullMarkdown([b])
        #expect(out == "[Buy] \(trailer("b1", "button"))")
        #expect(!out.contains("<button"))
    }

    // MARK: input -> input(...) with {aloha-id="..." input}

    @Test func inputRendersControlFormWithTrailer() {
        let input = interactive("in1", tag: "input",
                                inputData: DomInputData(type: "text", placeholder: "Search"))
        let out = serializeFullMarkdown([input])
        #expect(out.hasPrefix("input("))
        #expect(out.contains("Search"))
        #expect(out.contains(trailer("in1", "input")))
        #expect(!out.contains("<input"))
    }

    // MARK: occluded interactive -> line + " [occ:<id>]" + legend lists overlay once

    @Test func occludedInteractiveKeepsLineMarkerAndLegend() {
        let occ = OccluderRef(alohaId: "ov9", tag: "div", role: "dialog", text: "Cookie consent")
        let btn = mkNode(
            "b1", tag: "button", textContent: "Buy now", comprehensiveText: "Buy now",
            interactivity: DomInteractivity(
                isInteractive: true, isHighlighted: false, isTopElement: false, occludedBy: occ),
            positioning: DomPositioning(distanceToViewportBorder: 0, isInViewport: true, isVisible: true))
        let body = serializeFullMarkdown([btn])
        // The covered button still emits its actionable line and the short [occ:ov9] marker.
        #expect(body.contains(trailer("b1", "button")))
        #expect(body.contains("[occ:ov9]"))
        // The overlay is described exactly once in the legend (built from the same data).
        let legend = occlusionLegend([btn])
        #expect(legend.filter { $0.contains("[occ:ov9] = overlay") }.count == 1)
        #expect(legend.contains { $0.contains("Cookie consent") })
    }

    // MARK: INVARIANT — every interactive node appears with an aloha-id="..." token on its line

    @Test func everyInteractiveNodeKeepsItsAlohaIdToken() {
        let link = interactive("lnk1", tag: "a", attributes: ["href": "/p/9"], text: "Acme")
        let button = interactive("btn1", tag: "button", text: "Buy")
        let input = interactive("inp1", tag: "input",
                                inputData: DomInputData(type: "text", placeholder: "Search"))
        let out = serializeFullMarkdown([link, button, input], DomSerializeOptions(includeUrls: true))
        // Navigation preserved: each actionable id must survive into the observation text,
        // each on its own line (findAlohaIdsInMarkdown parses the trailer per line).
        for id in ["lnk1", "btn1", "inp1"] {
            #expect(out.contains("aloha-id=\"\(id)\""), "missing aloha-id token for \(id)")
            let onSomeLine = out.split(separator: "\n").contains { $0.contains("aloha-id=\"\(id)\"") }
            #expect(onSomeLine, "aloha-id for \(id) not on a single observation line")
        }
    }

    // MARK: COVERAGE — a product card surfaces its price (a non-highlighted content <div>) once,
    // without re-printing the title the <li>/<a> already shows, and keeps every actionable id.

    /// A non-highlighted, in-viewport, visible content leaf (e.g. `<div class="price">£399</div>`).
    /// It carries no actionable trailer, so `renderFullNode` drops it; `contentLeafLine` surfaces it.
    private func contentDiv(_ id: String, _ text: String) -> DomNode {
        mkNode(id, tag: "div", comprehensiveText: text, nodeType: "ELEMENT_NODE",
               interactivity: DomInteractivity(isInteractive: false, isHighlighted: false, isTopElement: true),
               positioning: DomPositioning(isInViewport: true, isVisible: true))
    }

    @Test func productCardSurfacesPriceOnceAndKeepsActionableIds() {
        let name = "Smaug the Dragon 5oz Silver"
        let li = interactive("liS", tag: "li", text: name, children: ["aS", "titleS", "priceS", "btnS"])
        let link = interactive("aS", tag: "a", attributes: ["href": "/p/13"], text: name)
        let title = contentDiv("titleS", name)        // duplicates the card title -> must be deduped
        let price = contentDiv("priceS", "£399.00")    // new value -> must be surfaced
        let buy = interactive("btnS", tag: "button", text: "Add to basket")
        let out = serializeFullMarkdown([li, link, title, price, buy], DomSerializeOptions(includeUrls: true))

        // 1. the price now reaches the model
        #expect(out.contains("£399.00"), "price content was dropped:\n\(out)")
        // 2. the price line is plain content — no actionable trailer fabricated for it
        let priceLine = out.split(separator: "\n").first { $0.contains("£399.00") }.map(String.init) ?? ""
        #expect(!priceLine.contains("aloha-id"), "price line should be id-free content: \(priceLine)")
        // 3. the title is not reprinted by the content-leaf path (li + a already show it = 2, not 3)
        let nameCount = out.components(separatedBy: name).count - 1
        #expect(nameCount == 2, "title duplicated \(nameCount)x (expected 2: li + a):\n\(out)")
        // 4. navigation preserved: every actionable id still present
        for id in ["liS", "aS", "btnS"] {
            #expect(out.contains("aloha-id=\"\(id)\""), "missing actionable id \(id)")
        }
    }

    // MARK: a content <div> whose text merely repeats an ancestor adds nothing (no noise).

    @Test func contentLeafDedupsAgainstEmittedAncestor() {
        let li = interactive("liD", tag: "li", text: "Blue Widget", children: ["dupD"])
        let dup = contentDiv("dupD", "Blue Widget")
        let out = serializeFullMarkdown([li, dup])
        #expect(out.components(separatedBy: "Blue Widget").count - 1 == 1, "duplicate content not deduped:\n\(out)")
    }

    // MARK: trivial micro-tokens (bare "0"/"." vote-and-count chrome) are not surfaced as content.

    @Test func contentLeafSkipsTrivialMicroTokens() {
        let li = interactive("liT", tag: "li", text: "Question title here", children: ["voteT", "dotT", "priceT"])
        let vote = contentDiv("voteT", "0")             // vote count chrome -> drop
        let dot = contentDiv("dotT", ".")               // separator -> drop
        let price = contentDiv("priceT", "£399.00")      // real value -> keep
        let out = serializeFullMarkdown([li, vote, dot, price])
        #expect(out.contains("£399.00"), "real value dropped by the noise gate:\n\(out)")
        let lines = out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(!lines.contains("0"), "bare vote-count '0' leaked as content:\n\(out)")
        #expect(!lines.contains("."), "bare separator '.' leaked as content:\n\(out)")
    }

    // MARK: an aggregating container (<ul>) is never collapsed into one joined content line.

    @Test func contentLeafSkipsAggregatingContainers() {
        let ul = mkNode("ulA", tag: "ul", comprehensiveText: "Red Green Blue",
                        positioning: DomPositioning(isInViewport: true, isVisible: true),
                        children: ["liA1", "liA2"])
        let li1 = mkNode("liA1", tag: "li", comprehensiveText: "Red", positioning: DomPositioning(isVisible: true))
        let li2 = mkNode("liA2", tag: "li", comprehensiveText: "Green", positioning: DomPositioning(isVisible: true))
        let out = serializeFullMarkdown([ul, li1, li2])
        // the <ul>'s joined text must not appear as its own line
        #expect(!out.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == "Red Green Blue" },
                "aggregating container collapsed into a content line:\n\(out)")
    }

    // MARK: a price that is a SUBSTRING of the card title must still be surfaced (exact-key dedup,
    // not substring) — guards the over-dedup bug where "£399" was dropped under a title "Coin 399".

    @Test func contentLeafSurfacesPriceThatIsSubstringOfTitle() {
        let li = interactive("liP", tag: "li", text: "Coin 399 Anniversary", children: ["pP"])
        let price = contentDiv("pP", "£399")
        let out = serializeFullMarkdown([li, price])
        #expect(out.contains("£399"), "price wrongly deduped as a substring of the title:\n\(out)")
    }

    // MARK: even when the card title is long enough to be truncated in the emitted label and itself
    // contains the price digits, the price <div> is still surfaced (dedup is exact key, not substring).

    @Test func contentLeafSurfacesPriceWhenTitleIsLongAndContainsIt() {
        let longTitle = String(repeating: "Premium Collector Edition Coin ", count: 6) + "priced at £399.00 today"
        let li = interactive("liL", tag: "li", text: longTitle, children: ["pL"])
        let price = contentDiv("pL", "£399.00")
        let out = serializeFullMarkdown([li, price])
        #expect(out.contains("£399.00"), "price dropped because the long title contained it:\n\(out)")
    }

    // MARK: a short value carrying a currency symbol ("£5") survives the min-length gate.

    @Test func contentLeafKeepsShortCurrencyValue() {
        let li = interactive("liC", tag: "li", text: "Bargain Widget", children: ["cheapC", "voteC"])
        let cheap = contentDiv("cheapC", "£5")   // 2 chars but a real price -> keep
        let vote = contentDiv("voteC", "0")      // bare count -> drop
        let out = serializeFullMarkdown([li, cheap, vote])
        #expect(out.contains("£5"), "short currency value dropped by min-length gate:\n\(out)")
        #expect(!out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.contains("0"),
                "bare count leaked:\n\(out)")
    }
}
