import Testing
@testable import BrowserTools

// The shape the live CDP walker actually produces: `body` is the walk's ROOT and its own
// border box measures zero (`isVisible == false`) while its children are visible. Before
// the fix, the root-drop took the whole page with it and every clean-DOM serialization
// came back EMPTY — which is what `AgentWebExtractionOptions.enriched` (cleanDom ON)
// would have shipped. Verified against a real Chromium; pinned here without one.
private func node(
    _ id: String, _ tag: String,
    attributes: [String: String] = [:],
    visible: Bool = true,
    children: [String] = []
) -> DomNode {
    DomNode(
        id: id,
        element: DomElement(tagName: tag, attributes: attributes),
        positioning: DomPositioning(isVisible: visible),
        children: children)
}

@Test @MainActor func cleanDomKeepsVisibleContentUnderAZeroBoxRoot() {
    let kept = Set(cleanDomTree([
        node("body", "body", visible: false, children: ["h1", "button"]),
        node("h1", "h1"),
        node("button", "button"),
    ]).map(\.id))
    #expect(kept == ["h1", "button"])
}

@Test @MainActor func cleanDomStillDropsAuthoredHiddenSubtrees() {
    let kept = Set(cleanDomTree([
        node("root", "div", children: ["hidden", "gone", "kept"]),
        node("hidden", "div", attributes: ["aria-hidden": "true"], children: ["child"]),
        node("child", "span"),
        node("gone", "p", attributes: ["style": "display: none"]),
        node("kept", "p"),
    ]).map(\.id))
    #expect(kept == ["root", "kept"])
}
