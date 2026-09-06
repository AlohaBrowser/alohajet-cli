import Testing
import Foundation
@testable import BrowserTools
import ToolABI

private func node(
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

// MARK: - Whitespace & text helpers

@Suite struct DomTextHelperTests {
    @Test func normalizeWhitespaceCollapsesAndTrims() {
        #expect(normalizeWhitespace("  a   b\n c  ") == "a b c")
        #expect(normalizeWhitespace(nil) == "")
    }

    @Test func truncateTextShortPassesThrough() {
        #expect(truncateText("hello", 3000) == "hello")
        #expect(truncateText(nil) == "")
    }

    @Test func truncateTextInsertsMarkerForLongInput() {
        let long = String(repeating: "x", count: 500)
        let result = truncateText(long, 200)
        #expect(result.contains("[content truncated"))
        #expect(result.count < 500)
    }

    @Test func truncateLabelEllipsizes() {
        #expect(truncateLabel("short", 20) == "short")
        #expect(truncateLabel("this is a very long label", 10) == "this is...")
    }

    @Test func collectDescendantTextGathersTextNodes() {
        let parent = node("p", tag: "div", children: ["t1", "t2"])
        let t1 = node("t1", tag: "span", textContent: "hello", comprehensiveText: "hello", nodeType: "TEXT_NODE")
        let t2 = node("t2", tag: "span", textContent: "world", comprehensiveText: "world", nodeType: "TEXT_NODE")
        let byId = ["p": parent, "t1": t1, "t2": t2]
        var visited = Set<String>()
        #expect(collectDescendantText(parent, byId, &visited) == "hello world")
    }

    @Test func textDuplicatesDescendantsTrueWhenEqual() {
        let parent = node("p", tag: "div", children: ["t1"])
        let t1 = node("t1", tag: "span", textContent: "hello", comprehensiveText: "hello", nodeType: "TEXT_NODE")
        let byId = ["p": parent, "t1": t1]
        #expect(textDuplicatesDescendants("hello", parent, byId))
        #expect(!textDuplicatesDescendants("different", parent, byId))
    }

    @Test func textDuplicatesDescendantsFalseWhenNoChildren() {
        let leaf = node("p", tag: "div")
        #expect(!textDuplicatesDescendants("hi", leaf, ["p": leaf]))
    }
}

// MARK: - Select rendering & attribute helpers

@Suite struct DomAttributeTests {
    @Test func renderSelectOptionsEmpty() {
        #expect(renderSelectOptions("s1", [], false) == "[options: empty]")
    }

    @Test func renderSelectOptionsMarksSelectedAndMulti() {
        let options = [
            DomSelectOption(text: "One", value: "1", selected: false),
            DomSelectOption(text: "Two", value: "2", selected: true)
        ]
        let result = renderSelectOptions("s1", options, true)
        #expect(result.contains("[s1.0] One"))
        #expect(result.contains("[s1.1] *Two"))
        #expect(result.contains("(multi)"))
    }

    @Test func hasAccessibleNameAttributeDetectsAriaLabel() {
        #expect(hasAccessibleNameAttribute(node("n", tag: "button", attributes: ["aria-label": "Submit"])))
        #expect(!hasAccessibleNameAttribute(node("n", tag: "button")))
    }

    @Test func appendAnchorMetadataIncludesHrefAndMarkers() {
        let n = node("a1", tag: "a", attributes: ["href": "https://x.com", "target": "_blank", "download": ""])
        let result = appendAnchorMetadata("<a aloha-id=\"a1\" />", n, "a", true)
        #expect(result.contains("href=\"https://x.com\""))
        #expect(result.contains("[new tab]"))
        #expect(result.contains("[download]"))
    }

    @Test func appendAnchorMetadataOmitsHrefWhenDisabled() {
        let n = node("a1", tag: "a", attributes: ["href": "https://x.com"])
        let result = appendAnchorMetadata("<a aloha-id=\"a1\" />", n, "a", false)
        #expect(!result.contains("href="))
    }

    @Test func isElementDisabledFromAttributeOrInput() {
        #expect(isElementDisabled(node("n", tag: "button", attributes: ["disabled": ""])))
        #expect(isElementDisabled(node("n", tag: "button", attributes: ["aria-disabled": "true"])))
        #expect(isElementDisabled(node("n", tag: "input", inputData: DomInputData(disabled: true))))
        #expect(!isElementDisabled(node("n", tag: "button")))
    }
}

// MARK: - Per-node emit functions

@Suite struct DomEmitTests {
    private func highlightedButton(distance: Int, text: String) -> DomNode {
        node(
            "b1",
            tag: "button",
            textContent: text,
            comprehensiveText: text,
            interactivity: DomInteractivity(isInteractive: true, isHighlighted: true, isTopElement: true),
            positioning: DomPositioning(distanceToViewportBorder: distance)
        )
    }

    @Test func emitInViewportElementRendersTagAndText() {
        let n = highlightedButton(distance: 0, text: "Click me")
        let result = emitInViewportElement(n, 0, ["b1": n])
        // Structural control: a bracketed label plus the actionable trailer.
        #expect(result.contains("[Click me]"))
        #expect(result.contains("{aloha-id=\"b1\" button}"))
    }

    @Test func emitCodeTagYieldsEmpty() {
        let n = node("c", tag: "code")
        #expect(emitInViewportElement(n, 0, ["c": n]).isEmpty)
        #expect(emitNearViewportElement(n, 0, ["c": n]).isEmpty)
        #expect(emitFarViewportElement(n, 0, ["c": n]).isEmpty)
        #expect(emitOutOfViewElement(n, 0, ["c": n]).isEmpty)
    }

    @Test func emitInViewportElementIndentsByDepth() {
        let n = highlightedButton(distance: 0, text: "X")
        let result = emitInViewportElement(n, 2, ["b1": n])
        // Indent is min(depth,4)*2 spaces (the structural list-nesting indent), not tabs.
        #expect(result.hasPrefix("    "))
        #expect(!result.hasPrefix("\t"))
    }

    @Test func emitInViewportElementMarksDisabled() {
        var n = highlightedButton(distance: 0, text: "X")
        n.element.attributes["disabled"] = ""
        let result = emitInViewportElement(n, 0, ["b1": n])
        #expect(result.contains("[DISABLED]"))
    }

    @Test func emitOutOfViewSkipsEmptyNonInteractive() {
        let n = node("d", tag: "div")
        #expect(emitOutOfViewElement(n, 0, ["d": n]).isEmpty)
    }
}

// MARK: - Wrapper text-dedup (title <h1><a> duplication)

@Suite struct WrapperDedupTests {
    private func kept(_ id: String, tag: String, text: String, attrs: [String: String] = [:], children: [String] = []) -> DomNode {
        node(id, tag: tag, attributes: attrs, comprehensiveText: text,
             interactivity: DomInteractivity(isInteractive: true, isHighlighted: true, isTopElement: true),
             positioning: DomPositioning(distanceToViewportBorder: 0), children: children)
    }

    /// `<h1><a>Post title</a></h1>` must emit ONE line (the link with its aloha-id), not the
    /// h1 duplicate — the wrapper's entire text is carried by the interactive descendant.
    @Test func wrapperWhoseTextIsCarriedByInteractiveChildIsDropped() {
        let h1 = kept("h1", tag: "h1", text: "Post title", children: ["a1"])
        let a1 = kept("a1", tag: "a", text: "Post title", attrs: ["href": "/f/books/1"])
        let byId = ["h1": h1, "a1": a1]
        #expect(emitInViewportElement(h1, 0, byId).isEmpty)
        let link = emitInViewportElement(a1, 0, byId)
        #expect(link.contains("[Post title]"))
        #expect(link.contains("aloha-id=\"a1\""))
    }

    /// `<span>Submitted by <a>user</a></span>` — the span has its OWN text, so it is NOT an
    /// exact duplicate of its descendants and must be kept.
    @Test func wrapperWithItsOwnTextIsKept() {
        let span = kept("s", tag: "span", text: "Submitted by user", children: ["a2"])
        let a2 = kept("a2", tag: "a", text: "user", attrs: ["href": "/user/u"])
        #expect(!emitInViewportElement(span, 0, ["s": span, "a2": a2]).isEmpty)
    }

    /// A standalone genuinely-actionable link is never deduped.
    @Test func genuineLinkNeverDeduped() {
        let a = kept("a", tag: "a", text: "Home", attrs: ["href": "/"])
        #expect(emitInViewportElement(a, 0, ["a": a]).contains("[Home]"))
    }
}

// MARK: - renderInteractiveNode dispatch

@Suite struct RenderInteractiveNodeTests {
    @Test func textNodeInViewportReturnsText() {
        let n = node("t", tag: "span", textContent: "Hello", nodeType: "TEXT_NODE",
                     positioning: DomPositioning(distanceToViewportBorder: 0, isInViewport: true, isVisible: true))
        let result = renderInteractiveNode(n, 0, ["t": n])
        #expect(result == "Hello")
    }

    @Test func textNodeOutOfViewportSuppressed() {
        let n = node("t", tag: "span", textContent: "Hello", nodeType: "TEXT_NODE",
                     positioning: DomPositioning(distanceToViewportBorder: 0, isInViewport: false))
        #expect(renderInteractiveNode(n, 0, ["t": n]).isEmpty)
    }

    @Test func structureTagWithChildrenRendersSelfClosing() {
        let n = node("nav1", tag: "nav", attributes: ["aria-label": "Main"], children: ["c1"])
        let result = renderInteractiveNode(n, 0, ["nav1": n])
        #expect(result.contains("<nav aloha-id=\"nav1\""))
        #expect(result.contains("aria-label=\"Main\""))
    }

    @Test func inlineTextTagRendersWithText() {
        let n = node("h", tag: "h1", comprehensiveText: "Title",
                     positioning: DomPositioning(isVisible: true))
        let result = renderInteractiveNode(n, 0, ["h": n])
        #expect(result.contains("<h1 aloha-id=\"h\""))
        #expect(result.contains("Title"))
    }

    @Test func nonHighlightedInteractiveSuppressed() {
        let n = node("b", tag: "button", textContent: "x",
                     interactivity: DomInteractivity(isInteractive: true, isHighlighted: false, isTopElement: false))
        #expect(renderInteractiveNode(n, 0, ["b": n]).isEmpty)
    }

    @Test func farViewportBeyondRangeSuppressed() {
        let n = node("b", tag: "button", textContent: "x",
                     interactivity: DomInteractivity(isHighlighted: true, isTopElement: true),
                     positioning: DomPositioning(distanceToViewportBorder: 6000))
        #expect(renderInteractiveNode(n, 0, ["b": n]).isEmpty)
    }
}

// MARK: - Full document serialization

@Suite struct SerializeMarkdownTests {
    @Test func serializeFullMarkdownWalksTree() {
        let root = node("r", tag: "h1", comprehensiveText: "Heading", positioning: DomPositioning(isVisible: true), children: [])
        let result = serializeFullMarkdown([root])
        // Structural markdown: a heading renders as clean id-free `# Heading`.
        #expect(result == "# Heading")
    }

    @Test func serializeFullMarkdownEmitsHighlightedInteractiveWithTrailer() {
        let button = node(
            "b1",
            tag: "button",
            textContent: "Submit",
            comprehensiveText: "Submit",
            interactivity: DomInteractivity(isInteractive: true, isHighlighted: true, isTopElement: true),
            positioning: DomPositioning(distanceToViewportBorder: 0)
        )
        let result = serializeFullMarkdown([button])
        // The interactive element keeps a parseable trailing aloha-id marker.
        #expect(result.contains("{aloha-id=\"b1\" button}"))
        #expect(result.contains("Submit"))
    }

    /// A promoted text wrapper (a byline `<span>`) whose whole text a rendered ancestor
    /// (`<p>`) already SHOWED as content must not re-emit it as a duplicate label line — the
    /// clean content line stays (once), the redundant `{aloha-id}` span label is dropped.
    @Test func promotedWrapperDuplicatingShownAncestorTextIsDropped() {
        let byline = "Submitted by t3_x 3 years ago"
        let p = node("p", tag: "p", comprehensiveText: byline,
                     positioning: DomPositioning(isVisible: true), children: ["sp"])
        let span = node("sp", tag: "span", comprehensiveText: byline,
                        interactivity: DomInteractivity(isInteractive: true, isHighlighted: true, isTopElement: true),
                        positioning: DomPositioning(distanceToViewportBorder: 0))
        let result = serializeFullMarkdown([p, span])
        let occurrences = result.components(separatedBy: byline).count - 1
        #expect(occurrences == 1)                       // byline shown exactly once
        #expect(!result.contains("aloha-id=\"sp\""))    // redundant span label dropped
    }

    /// The dedup is keyed on an ancestor that genuinely SHOWED the text: a landmark line
    /// (`[header]`, tag only) must NOT suppress a promoted descendant carrying real text.
    @Test func landmarkAncestorDoesNotSuppressPromotedDescendant() {
        let text = "Some standalone promoted text here"
        let header = node("h", tag: "header", comprehensiveText: text,
                          positioning: DomPositioning(isVisible: true), children: ["sp2"])
        let span = node("sp2", tag: "span", comprehensiveText: text,
                        interactivity: DomInteractivity(isInteractive: true, isHighlighted: true, isTopElement: true),
                        positioning: DomPositioning(distanceToViewportBorder: 0))
        let result = serializeFullMarkdown([header, span])
        // The header renders only `[header]` (not the text), so the span is NOT deduped.
        #expect(result.contains(text))
    }
}

@Suite struct DomAxtreeHelperTests {
    @Test func buildOutOfViewSummaryEmptyForNoNodes() {
        #expect(buildOutOfViewSummary([], "below", [:]).isEmpty)
    }

    @Test func buildOutOfViewSummaryAppendsMoreSuffixWhenTruncated() {
        var nodes: [DomNode] = []
        for i in 0..<20 {
            nodes.append(node("h\(i)", tag: "h2", comprehensiveText: "Heading \(i)",
                              positioning: DomPositioning(distanceToViewportBorder: 1000)))
        }
        var byId: [String: DomNode] = [:]
        for n in nodes { byId[n.id] = n }
        let summary = buildOutOfViewSummary(nodes, "below", byId)
        #expect(summary.contains { $0.contains("more elements") && $0.contains("scroll down") })
    }
}

// MARK: - Occlusion annotation

@Suite struct OcclusionAnnotationTests {
    private func occludedButton(occludedBy: OccluderRef?) -> DomNode {
        // An interactive in-view button the hit-test found NOT to be the top element:
        // isTopElement = false, and (when occluded) isHighlighted is false too — exactly the
        // node the old gate silently dropped.
        node(
            "b1",
            tag: "button",
            textContent: "Buy now",
            comprehensiveText: "Buy now",
            interactivity: DomInteractivity(
                isInteractive: true, isHighlighted: false, isTopElement: false,
                occludedBy: occludedBy),
            positioning: DomPositioning(distanceToViewportBorder: 0, isInViewport: true, isVisible: true)
        )
    }

    @Test func occludedInteractiveIsKeptAndAnnotated() {
        let n = occludedButton(occludedBy: OccluderRef(
            alohaId: "ov9", tag: "div", role: "dialog", text: "Cookie consent"))
        let result = renderInteractiveNode(n, 0, ["b1": n])
        // Kept (not dropped): the structural control line carries its actionable trailer plus the
        // short [occ:id] reference; the overlay is described ONCE in the occlusion legend.
        #expect(result.contains("[Buy now]"))
        #expect(result.contains("{aloha-id=\"b1\" button}"))
        #expect(result.contains("[occ:ov9]"))
        let legend = occlusionLegend([n])
        #expect(legend.contains { $0.contains("[occ:ov9] = overlay <div> role=\"dialog\" \"Cookie consent\"") })
        #expect(legend.contains { $0.contains("dismiss/close it to interact") })
    }

    @Test func unoccludedInteractiveHasNoMarker() {
        let n = node(
            "b1", tag: "button", textContent: "Buy now", comprehensiveText: "Buy now",
            interactivity: DomInteractivity(isInteractive: true, isHighlighted: true, isTopElement: true),
            positioning: DomPositioning(distanceToViewportBorder: 0))
        let result = renderInteractiveNode(n, 0, ["b1": n])
        #expect(result.contains("{aloha-id=\"b1\" button}"))
        #expect(!result.contains("[occ:"))
        #expect(occlusionLegend([n]).isEmpty)
    }

    @Test func occludedInteractiveWithoutOccluderRefStaysDropped() {
        // No occludedBy reference → baseline behavior is preserved (silently dropped).
        let n = occludedButton(occludedBy: nil)
        #expect(renderInteractiveNode(n, 0, ["b1": n]).isEmpty)
    }

    @Test func occludedNonInteractiveIsNotAnnotated() {
        // A decorative (non-interactive) node carrying an occluder ref is still dropped, never
        // annotated — only genuinely interactive elements are surfaced as occluded.
        let n = node(
            "d1", tag: "div", textContent: "x",
            interactivity: DomInteractivity(
                isInteractive: false, isHighlighted: false, isTopElement: false,
                occludedBy: OccluderRef(tag: "div")),
            positioning: DomPositioning(distanceToViewportBorder: 0))
        #expect(renderInteractiveNode(n, 0, ["d1": n]).isEmpty)
    }

    @Test func anOverlayWithNoIdIsReportedAsCoveredAndNamedByItsText() {
        // It used to be keyed by its TAG, which put [occ:section] into the slot an aloha-id
        // occupies under a legend telling the model to dismiss "[occ:section]-marked elements".
        // A tag addresses nothing and every unidentified <div> on a page shared one key, so the
        // legend described the first and marked all of them.
        let n = occludedButton(occludedBy: OccluderRef(tag: "section", role: nil, text: "Newsletter"))
        let result = renderInteractiveNode(n, 0, ["b1": n])
        #expect(result.contains("[occluded]"))
        #expect(!result.contains("[occ:section]"))
        let legend = occlusionLegend([n])
        #expect(legend.contains { $0.contains("[occluded] = overlay <section> \"Newsletter\"") })
        #expect(legend.contains { $0.contains("no aloha-id to address it by") })
        #expect(!legend.contains { $0.contains("aloha-id=\"\"") })
    }

    /// Two different unidentified overlays stay two lines rather than collapsing onto one tag key.
    @Test func twoUnidentifiedOverlaysAreDescribedSeparately() {
        let a = occludedButton(occludedBy: OccluderRef(tag: "div", role: nil, text: "Pay yearly"))
        let b = occludedButton(occludedBy: OccluderRef(tag: "div", role: nil, text: "Cookie notice"))
        let legend = occlusionLegend([a, b])
        #expect(legend.contains { $0.contains("\"Pay yearly\"") })
        #expect(legend.contains { $0.contains("\"Cookie notice\"") })
    }

    @Test func renderInteractiveNodeSurfacesOccludedButton() {
        let n = occludedButton(occludedBy: OccluderRef(alohaId: "modal1", tag: "div", text: "Sign up"))
        let result = renderInteractiveNode(n, 0, ["b1": n])
        #expect(result.contains("{aloha-id=\"b1\" button}"))
        #expect(result.contains("[occ:modal1]"))
    }

    @Test func occluderLegendNeutralizesNewlinesAndTabs() {
        // Page-controlled occluder text is folded onto a single legend line: newlines and tabs
        // become spaces so the multi-line legend block stays one line per overlay.
        let n = occludedButton(occludedBy: OccluderRef(tag: "div", text: "Buy now\ndeal\there"))
        let legend = occlusionLegend([n])
        // Each legend entry is its own element; the overlay's description must contain no raw
        // newline/tab that would split it across lines.
        #expect(legend.contains { $0.contains("Buy now deal here") })
        #expect(!legend.contains { $0.contains("\n") || $0.contains("\t") })
    }

}

// MARK: - Scroll annotation

@Suite struct ScrollAnnotationTests {
    /// A non-interactive scrollable container — a plain `div` the keep test would otherwise drop —
    /// carrying the given scroll descriptor.
    private func scrollableDiv(_ scroll: ScrollDescriptor) -> DomNode {
        node(
            "s1",
            tag: "div",
            interactivity: DomInteractivity(isInteractive: false, isHighlighted: false, isTopElement: false),
            positioning: DomPositioning(distanceToViewportBorder: 0, isInViewport: true, isVisible: true, scroll: scroll)
        )
    }

    @Test func scrollableContainerIsKeptAndAnnotated() {
        // Scrolled 300 of (600 - 120) = 480 max = 62.5% → 63%, past the midpoint, so "more above".
        let n = scrollableDiv(ScrollDescriptor(
            vertical: ScrollAxis(offset: 300, scrollSize: 600, clientSize: 120)))
        let result = renderInteractiveNode(n, 0, ["s1": n])
        #expect(result.contains("{aloha-id=\"s1\" div}"))
        #expect(result.contains("[scrollable \u{2195} 63% \u{00B7} more above]"))
    }

    @Test func scrollAtTopReadsTop() {
        let n = scrollableDiv(ScrollDescriptor(
            vertical: ScrollAxis(offset: 0, scrollSize: 600, clientSize: 120)))
        let result = renderInteractiveNode(n, 0, ["s1": n])
        #expect(result.contains("[scrollable \u{2195} 0% \u{00B7} top]"))
    }

    @Test func scrollAtBottomReadsBottom() {
        let n = scrollableDiv(ScrollDescriptor(
            vertical: ScrollAxis(offset: 480, scrollSize: 600, clientSize: 120)))
        let result = renderInteractiveNode(n, 0, ["s1": n])
        #expect(result.contains("[scrollable \u{2195} 100% \u{00B7} bottom]"))
    }

    @Test func scrollBelowMidpointReadsMoreBelow() {
        // 100 of 480 max ≈ 21% — below the midpoint, so "more below".
        let n = scrollableDiv(ScrollDescriptor(
            vertical: ScrollAxis(offset: 100, scrollSize: 600, clientSize: 120)))
        let result = renderInteractiveNode(n, 0, ["s1": n])
        #expect(result.contains("\u{00B7} more below]"))
    }

    @Test func valueSelectorEmitsCenteredChild() {
        let n = scrollableDiv(ScrollDescriptor(
            vertical: ScrollAxis(offset: 150, scrollSize: 600, clientSize: 90),
            centeredChild: "22:00"))
        let result = renderInteractiveNode(n, 0, ["s1": n])
        #expect(result.contains("[scrollable \u{2195}"))
        #expect(result.contains("[scroll selector \u{00B7} centered: \"22:00\"]"))
    }

    @Test func horizontalScrollIsAnnotated() {
        let n = scrollableDiv(ScrollDescriptor(
            horizontal: ScrollAxis(offset: 160, scrollSize: 800, clientSize: 400)))
        let result = renderInteractiveNode(n, 0, ["s1": n])
        // 160 of (800 - 400) = 400 max = 40% — below the midpoint, so "more right".
        #expect(result.contains("[scrollable \u{2194} 40% \u{00B7} more right]"))
    }

    @Test func nonScrollableHasNoMarker() {
        let n = node(
            "b1", tag: "button", textContent: "Buy", comprehensiveText: "Buy",
            interactivity: DomInteractivity(isInteractive: true, isHighlighted: true, isTopElement: true),
            positioning: DomPositioning(distanceToViewportBorder: 0))
        let result = renderInteractiveNode(n, 0, ["b1": n])
        #expect(!result.contains("[scrollable"))
        #expect(!result.contains("[scroll selector"))
    }

    @Test func centeredChildSanitizesDelimiterChars() {
        // Page-controlled centered text must not break the scroll marker's own ']'/quote delimiters.
        // Assert on the scrollMarker suffix directly so the element's own label/trailer brackets
        // don't confound the count.
        let n = scrollableDiv(ScrollDescriptor(
            vertical: ScrollAxis(offset: 100, scrollSize: 600, clientSize: 120),
            centeredChild: "22:00 ] \"x\"\nline"))
        let marker = scrollMarker(n)
        // exactly two ']' — the two markers' terminators — and no raw double-quote inside the value.
        #expect(marker.filter { $0 == "]" }.count == 2)
        #expect(marker.hasSuffix("]"))
        #expect(!marker.contains("\"x\""))
        #expect(!marker.contains("\n"))
    }
}
