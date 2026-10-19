import Foundation
import Testing
import CDP
import ToolABI
@testable import BrowserTools

// WHAT A VALUE IS, NOT ONLY WHAT IT SAYS. Four native shapes reached the read as unlabelled text:
// an image's alt printed as a bare line, indistinguishable from the `<figcaption>` under it; an
// `<abbr title>` lost its expansion in a sentence ("handled by the DCN team"); two "Riga" options
// under different `<optgroup>`s read as the same choice; and a closed `<details>` printed its
// answer exactly like an open one, with no id on an unstyled summary to open it by. Measured on
// a fixture in headless Chromium and in WKWebView (the desktop's engine), same output in both.
// Each fix ADDS a label; no text the read carried before is removed.

private func node(
    _ id: String, _ tag: String,
    attributes: [String: String] = [:],
    text: String? = nil,
    childText: String? = nil,
    comprehensive: String? = nil,
    nodeType: String? = nil,
    interactive: Bool = false,
    options: DomOptionData? = nil,
    children: [String] = []
) -> DomNode {
    DomNode(
        id: id,
        nodeType: nodeType,
        element: DomElement(tagName: tag, attributes: attributes, textContent: text, childText: childText),
        content: DomContent(comprehensiveText: comprehensive ?? text, optionData: options),
        interactivity: DomInteractivity(isInteractive: interactive, isHighlighted: interactive, isTopElement: true),
        positioning: DomPositioning(distanceToViewportBorder: 0, isInViewport: true, isVisible: true),
        children: children)
}

private func textNode(_ id: String, _ text: String) -> DomNode {
    node(id, "span", text: text, nodeType: "TEXT_NODE")
}

private func lines(_ out: String) -> [String] {
    out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
}

@Suite("the read says what a value is: image, abbreviation, option group, open or closed")
struct ReadAttributionTests {

    /// A standalone image reads `![alt]`; the caption beside it stays a plain line. An image
    /// inside a link is still the link's text.
    @Test func anImageReadsAsAnImageNotAsACaption() {
        let fig = node("fig", "figure", comprehensive: "Pallet count: 184 on hand Figure 1. Last month: 120 on hand",
                       children: ["img", "cap"])
        let img = node("img", "img", comprehensive: "Pallet count: 184 on hand")
        let cap = node("cap", "figcaption", comprehensive: "Figure 1. Last month: 120 on hand", children: ["capt"])
        let capt = textNode("capt", "Figure 1. Last month: 120 on hand")
        let link = node("a", "a", attributes: ["href": "/p/1"], text: "Blue running shoe", interactive: true, children: ["limg"])
        let limg = node("limg", "img", comprehensive: "Blue running shoe")
        let out = serializeFullMarkdown([fig, img, cap, capt, link, limg])
        let l = lines(out)
        #expect(l.contains("![Pallet count: 184 on hand]"), "\(out)")
        #expect(l.contains("Figure 1. Last month: 120 on hand"), "\(out)")
        #expect(!l.contains("Pallet count: 184 on hand"), "the alt is not a bare line:\n\(out)")
        #expect(l.contains(#"[Blue running shoe] {aloha-id="a" a}"#), "\(out)")
        #expect(!out.contains("![Blue running shoe]"), "\(out)")
    }

    /// An abbreviation keeps its expansion in a sentence and on its own; the walker's own text
    /// for it (title glued in front) is never printed.
    @Test func anAbbreviationKeepsItsExpansion() {
        let p = node("p", "p", comprehensive: "Shipping is handled by the DCN team.", children: ["t1", "ab", "t2"])
        let t1 = textNode("t1", "Shipping is handled by the")
        let ab = node("ab", "abbr", attributes: ["title": "Distribution Center North"],
                      text: "Distribution Center North DCN", childText: "DCN",
                      comprehensive: "Distribution Center North DCN", children: ["abt"])
        let abt = textNode("abt", "DCN")
        let t2 = textNode("t2", "team.")
        let star = node("star", "abbr", attributes: ["title": "required"], text: "required *", childText: "*",
                        comprehensive: "required *")
        let same = node("same", "abbr", attributes: ["title": "NASA"], text: "NASA NASA", childText: "NASA",
                        comprehensive: "NASA NASA")
        let out = serializeFullMarkdown([p, t1, ab, abt, t2, star, same])
        let l = lines(out)
        #expect(l.contains("Shipping is handled by the DCN (Distribution Center North) team."), "\(out)")
        #expect(l.contains("* (required)"), "\(out)")
        #expect(l.contains("NASA"), "a title that repeats the text is not said twice:\n\(out)")
        #expect(!out.contains("Distribution Center North DCN"), "\(out)")
        #expect(l.filter { $0.contains("DCN") }.count == 1, "\(out)")
    }

    /// A `<details>` summary says whether its section is open; the page's own `aria-expanded`
    /// wins; the closed section's text is still read.
    @Test func aSummarySaysWhetherItsSectionIsOpen() {
        let d1 = node("d1", "details", attributes: ["id": "d1"], children: ["s1", "p1"])
        let s1 = node("s1", "summary", attributes: ["aloha-details": "closed"], text: "Return policy", interactive: true)
        let p1 = node("p1", "p", text: "Returns accepted within 30 days.")
        let d2 = node("d2", "details", attributes: ["open": ""], children: ["s2"])
        let s2 = node("s2", "summary", attributes: ["aloha-details": "open"], text: "Warranty", interactive: true)
        let d3 = node("d3", "details", children: ["s3"])
        let s3 = node("s3", "summary", attributes: ["aloha-details": "closed", "aria-expanded": "true"], text: "Sizes", interactive: true)
        let out = serializeFullMarkdown([d1, s1, p1, d2, s2, d3, s3])
        let l = lines(out)
        #expect(l.contains(#"[Return policy] [aria: COLLAPSED] {aloha-id="s1" summary}"#), "\(out)")
        #expect(l.contains("Returns accepted within 30 days."), "\(out)")
        #expect(l.contains(#"[Warranty] [aria: EXPANDED] {aloha-id="s2" summary}"#), "\(out)")
        #expect(l.contains(#"[Sizes] [aria: EXPANDED] {aloha-id="s3" summary}"#), "\(out)")
        #expect(!out.contains("aloha-details"), "the walker's attribute is not printed:\n\(out)")
    }

    /// Options under an `<optgroup>` read under the group's label, said once per group; a select
    /// without groups reads exactly as before.
    @Test func anOptionReadsUnderItsGroup() {
        let grouped = renderSelectOptions("s", [
            DomSelectOption(text: "Tallinn", group: "Europe"),
            DomSelectOption(text: "Riga", selected: true, group: "Europe"),
            DomSelectOption(text: "Osaka", group: "Asia"),
            DomSelectOption(text: "Riga", group: "Asia"),
            DomSelectOption(text: "Elsewhere"),
        ], false)
        #expect(grouped == "[options: Europe: [s.0] Tallinn, [s.1] *Riga, Asia: [s.2] Osaka, [s.3] Riga, [s.4] Elsewhere]", "\(grouped)")
        let plain = renderSelectOptions("s", [DomSelectOption(text: "A"), DomSelectOption(text: "B", selected: true)], false)
        #expect(plain == "[options: [s.0] A, [s.1] *B]", "\(plain)")
    }
}

// The same, end to end: the walker's half (summary always a toggle, `aloha-details`, the abbr's
// title, the option's group) in a real headless Chromium. Skipped without a browser, like
// `RealBrowserE2ETests`.

private nonisolated let attributionBrowserIsAvailable = ChromeLauncher().isAvailable

private let attributionHTML = """
<!doctype html><html><head><title>Attribution</title></head><body>
<h1>Warehouse report</h1>
<figure><img src="data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7" width="160" height="90" alt="Pallet count: 184 on hand">
<figcaption>Figure 1. Last month's pallet count: 120 on hand</figcaption></figure>
<p>Shipping is handled by the <abbr title="Distribution Center North">DCN</abbr> team.</p>
<label for="wh">Warehouse</label>
<select id="wh"><optgroup label="Europe"><option>Tallinn</option><option selected>Riga</option></optgroup>
<optgroup label="Asia"><option>Osaka</option><option>Riga</option></optgroup></select>
<details id="d1"><summary>Return policy</summary><p>Returns accepted within 30 days.</p></details>
<details id="d2" open><summary>Warranty</summary><p>Two-year limited warranty.</p></details>
</body></html>
"""

@MainActor
private func pageLines(_ output: String) -> [String] {
    guard let start = output.range(of: "<interactive_page_markdown>"),
          let end = output.range(of: "</interactive_page_markdown>") else { return [] }
    return output[start.upperBound..<end.lowerBound].split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
}

@MainActor
private func alohaId(of line: String) -> String? {
    guard let marker = line.range(of: "{aloha-id=\"") else { return nil }
    let rest = line[marker.upperBound...]
    return rest.firstIndex(of: "\"").map { String(rest[..<$0]) }
}

@Suite("end to end, real browser: the read says what a value is", .serialized, .enabled(if: attributionBrowserIsAvailable))
struct RealBrowserReadAttributionTests {
    @Test func theWalkerCarriesWhatTheSerializerLabels() async throws {
        let server = LocalPageServer(html: attributionHTML)
        try server.start()
        defer { server.stop() }
        try await withHeadlessBrowser { session in
            let opened = await session.run("manage_tabs", arguments: ["action": "open", "url": server.url])
            #expect(opened.isError != true, "\(opened.output)")
            let l = pageLines(opened.output)
            #expect(l.contains("![Pallet count: 184 on hand]"), "\(opened.output)")
            #expect(l.contains("Figure 1. Last month's pallet count: 120 on hand"), "\(opened.output)")
            #expect(l.contains("Shipping is handled by the DCN (Distribution Center North) team."), "\(opened.output)")
            #expect(l.contains { $0.contains("[options: Europe: [") && $0.contains("*Riga, Asia: [") }, "\(opened.output)")
            #expect(l.contains { $0.hasPrefix("[Return policy] [aria: COLLAPSED] {aloha-id=") }, "\(opened.output)")
            #expect(l.contains { $0.hasPrefix("[Warranty] [aria: EXPANDED] {aloha-id=") }, "\(opened.output)")
            #expect(l.contains("Returns accepted within 30 days."), "a closed section is still read:\n\(opened.output)")

            // The unstyled summary's id opens it, and the re-read says so.
            let summary = try #require(l.first { $0.hasPrefix("[Return policy]") }.flatMap(alohaId))
            let click = await session.run("page_click", arguments: ["aloha_id": summary])
            #expect(click.isError != true, "\(click.output)")
            let reread = await session.run("manage_tabs", arguments: ["action": "read"])
            #expect(pageLines(reread.output).contains { $0.hasPrefix("[Return policy] [aria: EXPANDED] {aloha-id=") }, "\(reread.output)")
        }
    }
}
