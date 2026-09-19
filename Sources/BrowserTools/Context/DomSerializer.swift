import Foundation
import ToolABI

// MARK: - DOM serialization model

public struct DomElement: Sendable {
    public var tagName: String
    public var attributes: [String: String]
    public var textContent: String?
    public var childText: String?
    public init(tagName: String, attributes: [String: String] = [:], textContent: String? = nil, childText: String? = nil) {
        self.tagName = tagName
        self.attributes = attributes
        self.textContent = textContent
        self.childText = childText
    }
}

public struct DomInputData: Sendable {
    public var type: String?
    public var placeholder: String?
    public var required: Bool
    public var disabled: Bool?
    public init(type: String? = nil, placeholder: String? = nil, required: Bool = false, disabled: Bool? = nil) {
        self.type = type
        self.placeholder = placeholder
        self.required = required
        self.disabled = disabled
    }
}

public struct DomSelectOption: Sendable {
    public var text: String?
    public var value: String?
    public var selected: Bool
    public init(text: String? = nil, value: String? = nil, selected: Bool = false) {
        self.text = text
        self.value = value
        self.selected = selected
    }
}

public struct DomOptionData: Sendable {
    public var options: [DomSelectOption]
    public var multiple: Bool
    public init(options: [DomSelectOption] = [], multiple: Bool = false) {
        self.options = options
        self.multiple = multiple
    }
}

public struct DomContent: Sendable {
    public var comprehensiveText: String?
    public var inputData: DomInputData?
    public var optionData: DomOptionData?
    public init(comprehensiveText: String? = nil, inputData: DomInputData? = nil, optionData: DomOptionData? = nil) {
        self.comprehensiveText = comprehensiveText
        self.inputData = inputData
        self.optionData = optionData
    }
}

/// Identity of the element that visually covers an interactive node at its click point,
/// as determined by the in-page hit-test (`document.elementFromPoint`, pointer-events aware).
/// Present only on interactive nodes the serializer found occluded; `nil` otherwise.
public struct OccluderRef: Sendable, Equatable {
    /// The covering element's `aloha-id`, when it is itself a tracked node the agent can act on.
    public var alohaId: String?
    public var tag: String
    public var role: String?
    public var text: String?
    public init(alohaId: String? = nil, tag: String, role: String? = nil, text: String? = nil) {
        self.alohaId = alohaId
        self.tag = tag
        self.role = role
        self.text = text
    }
}

/// One scroll axis of a scrollable container, in CSS pixels.
public struct ScrollAxis: Sendable, Equatable {
    public var offset: Int
    public var scrollSize: Int
    public var clientSize: Int
    public init(offset: Int, scrollSize: Int, clientSize: Int) {
        self.offset = offset
        self.scrollSize = scrollSize
        self.clientSize = clientSize
    }
}

/// Scroll state of a container the walker found scrollable. `vertical`/`horizontal` are present
/// only for the axes that actually overflow. `centeredChild` holds the trimmed text of the child
/// sitting at the container's center when it looks like a value-selector wheel (e.g. "22:00"),
/// giving the agent the current selection in addition to the scroll position.
public struct ScrollDescriptor: Sendable, Equatable {
    public var vertical: ScrollAxis?
    public var horizontal: ScrollAxis?
    public var centeredChild: String?
    public init(vertical: ScrollAxis? = nil, horizontal: ScrollAxis? = nil, centeredChild: String? = nil) {
        self.vertical = vertical
        self.horizontal = horizontal
        self.centeredChild = centeredChild
    }
}

public struct DomInteractivity: Sendable {
    public var isInteractive: Bool
    public var isInput: Bool
    public var isSelect: Bool
    public var isHighlighted: Bool
    public var isTopElement: Bool
    public var isFileInput: Bool
    /// What covers this interactive node, when the hit-test found it occluded. Drives the
    /// `[occluded …]` annotation.
    public var occludedBy: OccluderRef?
    public init(isInteractive: Bool = false, isInput: Bool = false, isSelect: Bool = false, isHighlighted: Bool = false, isTopElement: Bool = false, isFileInput: Bool = false, occludedBy: OccluderRef? = nil) {
        self.isInteractive = isInteractive
        self.isInput = isInput
        self.isSelect = isSelect
        self.isHighlighted = isHighlighted
        self.isTopElement = isTopElement
        self.isFileInput = isFileInput
        self.occludedBy = occludedBy
    }
}

public struct DomPositioning: Sendable {
    public var distanceToViewportBorder: Int
    public var isInViewport: Bool
    public var isVisible: Bool
    /// Scroll geometry when this element is a scrollable container; drives the `[scrollable …]`
    /// annotation.
    public var scroll: ScrollDescriptor?
    public init(distanceToViewportBorder: Int = 0, isInViewport: Bool = true, isVisible: Bool = true, scroll: ScrollDescriptor? = nil) {
        self.distanceToViewportBorder = distanceToViewportBorder
        self.isInViewport = isInViewport
        self.isVisible = isVisible
        self.scroll = scroll
    }
}

public struct DomNode: Sendable {
    public var id: String
    public var nodeType: String?
    public var element: DomElement
    public var content: DomContent
    public var interactivity: DomInteractivity
    public var positioning: DomPositioning
    public var children: [String]
    /// A statement that this node stands for a region the page walker was REFUSED access
    /// to — a cross-origin frame, or a closed shadow root, both of which read back null to
    /// page JavaScript — pre-rendered as the `[sealed: …]` suffix its line carries.
    ///
    /// Pre-rendered rather than structured because two producers write it and only one of
    /// them knows very much: the in-page walker can say no more than which boundary it hit,
    /// while the host runtime — which alone can look past a closed shadow root — adds the
    /// region's origin and whatever it identified about it.
    ///
    /// The serializer reads it for two jobs, and the SECOND IS LOAD-BEARING. The obvious one
    /// is rendering the suffix. The one easy to miss is that it RESCUES THE NODE FROM BEING
    /// DROPPED: two keep tests (the early filter in ``renderInteractiveNode`` and
    /// ``nodeIsKeptInteractive``) would otherwise discard a node that is neither
    /// highlighted-and-on-top nor carrying text — exactly the shape of an `<iframe>` whose
    /// content the walker could not read — putting it straight back into the silence the
    /// marker exists to break. Visibility is still required in both, on the same grounds as
    /// the occlusion and scrollable rules beside them: a `display: none` frame occupies no
    /// pixels and must not be offered as clickable. So removing this field means replacing
    /// two things, not one.
    public var sealedMarker: String?
    public init(
        id: String,
        nodeType: String? = nil,
        element: DomElement,
        content: DomContent = DomContent(),
        interactivity: DomInteractivity = DomInteractivity(),
        positioning: DomPositioning = DomPositioning(),
        children: [String] = [],
        sealedMarker: String? = nil
    ) {
        self.id = id
        self.nodeType = nodeType
        self.element = element
        self.content = content
        self.interactivity = interactivity
        self.positioning = positioning
        self.children = children
        self.sealedMarker = sealedMarker
    }
}

// MARK: - DOM pre-cleaning
//
// A purely subtractive pass over the parsed tree, targeting the categories that dominate
// raw page bytes: stylesheet and script bodies, inline vector geometry, comment nodes, and
// presentational/framework attributes. OFF by default; the serialization path runs it only
// when the caller opts in.

/// Tags whose entire subtree is dropped: none contributes readable content, all of them
/// inflate the serialization.
public let CLEAN_DOM_DROPPED_TAGS: Set<String> = ["style", "script", "noscript", "svg"]

/// Everything not matched here is preserved, so the attributes a reader needs — `href`,
/// `src`, `alt`, `aria-label`, and the interactive/aria attributes the serializer consults
/// — survive untouched.
public func cleanDomDropsAttribute(_ name: String) -> Bool {
    let lowered = name.lowercased()
    if lowered == "class" || lowered == "style" { return true }
    if lowered.hasPrefix("data-") { return true }
    return false
}

/// Whether a value would serialize an inline `data:` URI. Such values embed entire assets
/// (images, fonts) as base64 and are never useful to a reading agent, so a clean-DOM pass
/// drops the attribute carrying one rather than emit kilobytes of opaque payload.
public func cleanDomIsDataUri(_ value: String) -> Bool {
    value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("data:")
}

public func cleanDomIsHidden(_ node: DomNode) -> Bool {
    if !node.positioning.isVisible { return true }
    return cleanDomIsMarkedHidden(node)
}

/// The subset of ``cleanDomIsHidden`` that a subtree INHERITS: the author's explicit
/// hide markers. Split out because the layout signal does not inherit and this does.
///
/// `hidden` / `aria-hidden="true"` / inline `display:none` state something about a
/// region, so everything beneath goes with it. `isVisible == false` states only that
/// THIS element's own border box measured zero — which is routinely true of a container
/// whose visible children are floated, absolutely positioned, or simply measured before
/// layout settled. The live CDP walker reports exactly that for `<body>` on an ordinary
/// page (verified against a real Chromium: `body` invisible, its `h1`/`p`/`button`
/// visible), and since `body` is the walk's ROOT, treating the layout signal as
/// inherited deleted every node on the page and serialized an empty document.
public func cleanDomIsMarkedHidden(_ node: DomNode) -> Bool {
    let attrs = node.element.attributes
    if attrs["hidden"] != nil { return true }
    if attrs["aria-hidden"]?.lowercased() == "true" { return true }
    if let style = attrs["style"] {
        let compact = style.lowercased().replacingOccurrences(of: " ", with: "")
        if compact.contains("display:none") || compact.contains("visibility:hidden") { return true }
    }
    return false
}

/// Pre-clean a parsed DOM forest before serialization. Surviving nodes keep their
/// parent/child links, with references to dropped children removed, so the serializer walks
/// the same (lighter) tree.
public func cleanDomTree(_ nodes: [DomNode]) -> [DomNode] {
    // Walking from the roots (rather than filtering the flat array) is what prevents an
    // orphaned subtree under a dropped parent from leaking back in.
    var byId: [String: DomNode] = [:]
    for node in nodes { byId[node.id] = node }

    /// Dropped along with everything beneath it — all three cases describe a whole region.
    func dropsSubtree(_ node: DomNode) -> Bool {
        if node.nodeType == "COMMENT_NODE" { return true }
        let tag = node.element.tagName.lowercased()
        if CLEAN_DOM_DROPPED_TAGS.contains(tag) { return true }
        if cleanDomIsMarkedHidden(node) { return true }
        return false
    }

    var childIds = Set<String>()
    for node in nodes { for child in node.children { childIds.insert(child) } }
    let rootIds = nodes.filter { !childIds.contains($0.id) }.map { $0.id }

    var keep = Set<String>()
    var visited = Set<String>()
    var stack = rootIds
    while let id = stack.popLast() {
        guard let node = byId[id], !visited.contains(id) else { continue }
        visited.insert(id)
        if dropsSubtree(node) { continue }
        // A zero-box container is dropped ON ITS OWN, but the descent continues: its
        // children are judged by their own boxes. A genuinely `display:none` subtree
        // measures zero all the way down, so every node in it still drops; a wrapper
        // that merely measures zero no longer takes its visible content with it.
        if !node.positioning.isVisible {
            stack.append(contentsOf: node.children)
            continue
        }
        keep.insert(id)
        stack.append(contentsOf: node.children)
    }

    var result: [DomNode] = []
    for node in nodes where keep.contains(node.id) {
        var cleaned = node
        cleaned.children = node.children.filter { keep.contains($0) }
        var attrs = cleaned.element.attributes
        for (name, value) in attrs {
            if cleanDomDropsAttribute(name) || cleanDomIsDataUri(value) {
                attrs.removeValue(forKey: name)
            }
        }
        cleaned.element.attributes = attrs
        result.append(cleaned)
    }
    return result
}

// MARK: - Site-embedded structured data

// Many commerce and content pages publish their canonical facts as machine-readable
// JSON the renderer also consumes — schema.org JSON-LD in <script type="application/ld+json">,
// the framework hydration payload in <script id="__NEXT_DATA__">, and the Shopify
// /products.json feed. Reading that directly sidesteps the blind-selector problem: a
// product's name/price never lands in the visual serialization because it is painted by a
// component the DOM walk does not surface as text.
//
// OFF by default; the read path collects the raw JSON only when the caller opts in.

public struct SiteJsonProduct: Equatable, Sendable {
    public var name: String
    public var price: String?
    public var currency: String?
    public var availability: String?
    public init(name: String, price: String? = nil, currency: String? = nil, availability: String? = nil) {
        self.name = name
        self.price = price
        self.currency = currency
        self.availability = availability
    }
}

/// Reduce a schema.org availability value to a short token. The value is usually a URL
/// (`https://schema.org/InStock`) but pages also write the bare term, so we keep only the
/// final path segment and trust the page's own spelling otherwise.
public func siteJsonNormalizeAvailability(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if let slash = trimmed.lastIndex(where: { $0 == "/" || $0 == "#" }) {
        let tail = String(trimmed[trimmed.index(after: slash)...])
        return tail.isEmpty ? trimmed : tail
    }
    return trimmed
}

/// Render a JSON scalar as its plain string, so a `price` that a page writes as either
/// `"19.99"` or `19.99` reads the same in the summary. Booleans/objects/arrays/null yield `nil`.
private func siteJsonScalarString(_ value: Any?) -> String? {
    switch value {
    case let s as String:
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    case let n as NSNumber:
        // Distinguish a real boolean (CFBoolean) from a numeric value.
        #if canImport(Darwin)
        if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
        #else
        if n.objCType.pointee == CChar(99) /* 'c' */ { return nil }
        #endif
        if n.doubleValue == n.doubleValue.rounded() && abs(n.doubleValue) < 1e15 {
            return String(n.intValue)
        }
        return n.stringValue
    default:
        return nil
    }
}

/// The `@type` of a JSON-LD node, which may be a single string or an array of strings.
private func siteJsonTypes(_ node: [String: Any]) -> [String] {
    if let one = node["@type"] as? String { return [one] }
    if let many = node["@type"] as? [Any] { return many.compactMap { $0 as? String } }
    return []
}

/// Pull a product's price + currency from a schema.org `offers` value, which may be a single
/// Offer object, an array of Offers, or an AggregateOffer carrying `lowPrice`/`priceCurrency`.
private func siteJsonOffer(_ offers: Any?) -> (price: String?, currency: String?, availability: String?) {
    func fromObject(_ o: [String: Any]) -> (String?, String?, String?) {
        let price = siteJsonScalarString(o["price"]) ?? siteJsonScalarString(o["lowPrice"])
        let currency = siteJsonScalarString(o["priceCurrency"])
        let availability = (o["availability"] as? String).flatMap(siteJsonNormalizeAvailability)
        return (price, currency, availability)
    }
    if let o = offers as? [String: Any] { return fromObject(o) }
    if let arr = offers as? [Any] {
        for case let o as [String: Any] in arr {
            let (p, c, a) = fromObject(o)
            if p != nil || c != nil || a != nil { return (p, c, a) }
        }
    }
    return (nil, nil, nil)
}

private func siteJsonProduct(from node: [String: Any]) -> SiteJsonProduct? {
    let types = siteJsonTypes(node).map { $0.lowercased() }
    let looksLikeProduct = types.contains { $0.hasSuffix("product") }
    guard let name = siteJsonScalarString(node["name"]), looksLikeProduct || node["offers"] != nil else {
        return nil
    }
    let (price, currency, availability) = siteJsonOffer(node["offers"])
    return SiteJsonProduct(name: name, price: price, currency: currency, availability: availability)
}

/// Walk a JSON-LD payload collecting products, in document order. Pages nest these freely:
/// a top-level array of nodes, a single node, an `ItemList` whose `itemListElement` holds
/// `ListItem`/`Product` entries, and the `@graph` envelope — all four shapes are descended.
private func siteJsonCollect(_ value: Any, into out: inout [SiteJsonProduct]) {
    if let arr = value as? [Any] {
        for element in arr { siteJsonCollect(element, into: &out) }
        return
    }
    guard let node = value as? [String: Any] else { return }

    if let graph = node["@graph"] {
        siteJsonCollect(graph, into: &out)
    }

    let types = siteJsonTypes(node).map { $0.lowercased() }
    if types.contains(where: { $0.hasSuffix("itemlist") }), let items = node["itemListElement"] {
        // A ListItem wraps the real entity in `item`; a bare Product may also appear directly.
        if let arr = items as? [Any] {
            for element in arr {
                if let li = element as? [String: Any], let item = li["item"] {
                    siteJsonCollect(item, into: &out)
                } else {
                    siteJsonCollect(element, into: &out)
                }
            }
        }
    }

    if let product = siteJsonProduct(from: node) {
        out.append(product)
    }
}

/// Parse Shopify's `/products.json` feed (`{ "products": [ { title, variants:[{price}] } ] }`)
/// into product facts. Shopify prices are strings in the shop's currency, which the feed does
/// not name, so currency is left unset.
private func siteJsonShopifyProducts(_ value: Any) -> [SiteJsonProduct] {
    guard let root = value as? [String: Any], let products = root["products"] as? [Any] else { return [] }
    var out: [SiteJsonProduct] = []
    for case let p as [String: Any] in products {
        guard let title = siteJsonScalarString(p["title"]) else { continue }
        var price: String?
        if let variants = p["variants"] as? [Any], let first = variants.first as? [String: Any] {
            price = siteJsonScalarString(first["price"])
        }
        out.append(SiteJsonProduct(name: title, price: price))
    }
    return out
}

/// One line per product, e.g. `- Acme Widget — 19.99 USD — InStock`, dropping any missing
/// field so the line carries only what the page actually published.
private func siteJsonProductLine(_ product: SiteJsonProduct) -> String {
    var parts: [String] = [product.name]
    if let price = product.price {
        if let currency = product.currency {
            parts.append("\(price) \(currency)")
        } else {
            parts.append(price)
        }
    }
    if let availability = product.availability {
        parts.append(availability)
    }
    return "- " + parts.joined(separator: " — ")
}

/// The compact structured block prepended to an observation, built from the raw JSON the page
/// published. Returns `nil` when nothing usable is found, so the observation stays exactly as
/// it would be with extraction off.
///
/// Malformed JSON in any single source is skipped, not fatal — pages routinely ship one broken
/// block among several good ones.
public func siteJsonStructuredBlock(
    jsonLdScripts: [String],
    nextData: String? = nil,
    shopifyProductsJson: String? = nil
) -> String? {
    func decode(_ raw: String?) -> Any? {
        guard let raw, let data = raw.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              !data.isEmpty else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    var products: [SiteJsonProduct] = []
    for script in jsonLdScripts {
        if let decoded = decode(script) { siteJsonCollect(decoded, into: &products) }
    }
    if let decoded = decode(nextData) { siteJsonCollect(decoded, into: &products) }
    if let decoded = decode(shopifyProductsJson) { products.append(contentsOf: siteJsonShopifyProducts(decoded)) }

    // De-duplicate on the full fact (name + price + currency + availability), preserving order,
    // since the same product is often present in both an ItemList and a standalone Product node.
    var seen = Set<String>()
    var unique: [SiteJsonProduct] = []
    for product in products {
        let key = "\(product.name)\u{1F}\(product.price ?? "")\u{1F}\(product.currency ?? "")\u{1F}\(product.availability ?? "")"
        if seen.insert(key).inserted { unique.append(product) }
    }
    guard !unique.isEmpty else { return nil }

    var lines = ["[site data]"]
    lines.append(contentsOf: unique.map(siteJsonProductLine))
    return lines.joined(separator: "\n")
}

public let INLINE_TEXT_TAGS: Set<String> = ["legend", "h1", "h2", "h3", "h4", "h5", "h6", "figcaption", "caption", "dt", "p"]
public let STRUCTURE_TAGS: Set<String> = ["header", "footer", "aside", "main", "article", "section", "nav", "fieldset"]

public func normalizeWhitespace(_ raw: String?) -> String {
    let collapsed = (raw ?? "").replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return stripLoneSurrogates(collapsed)
}

public func collectDescendantText(_ node: DomNode, _ nodesById: [String: DomNode], _ visited: inout Set<String>) -> String {
    var collected: [String] = []
    for childId in node.children {
        if visited.contains(childId) { continue }
        visited.insert(childId)
        guard let child = nodesById[childId] else { continue }
        let tag = child.element.tagName.lowercased()
        if child.nodeType == "TEXT_NODE" || INLINE_TEXT_TAGS.contains(tag) || (child.interactivity.isHighlighted && child.interactivity.isTopElement) {
            let text = normalizeWhitespace(child.content.comprehensiveText ?? child.element.textContent ?? "")
            if !text.isEmpty { collected.append(text) }
        } else {
            let text = collectDescendantText(child, nodesById, &visited)
            if !text.isEmpty { collected.append(text) }
        }
    }
    return collected.joined(separator: " ")
}

public func textDuplicatesDescendants(_ text: String, _ node: DomNode, _ nodesById: [String: DomNode]) -> Bool {
    if node.children.isEmpty { return false }
    var visited = Set<String>()
    let descendantText = collectDescendantText(node, nodesById, &visited)
    if descendantText.isEmpty { return false }
    return normalizeWhitespace(text) == normalizeWhitespace(descendantText)
}

public func truncateText(_ raw: String?, _ maxLength: Int = 3000) -> String {
    let text = stripLoneSurrogates(raw ?? "")
    let count = text.count
    if count <= maxLength { return text }
    let hidden = count - maxLength
    if hidden > 100 {
        let marker = "... [content truncated, \(hidden) chars hidden] ..."
        let budget = maxLength - marker.count
        let head = budget / 2
        let tail = budget - head
        let chars = Array(text)
        let start = String(chars[0..<head])
        let end = String(chars[(count - tail)...])
        return "\(start)\(marker)\(end)"
    }
    return text
}

public func truncateLabel(_ raw: String, _ maxLength: Int = 20) -> String {
    if raw.count <= maxLength { return raw }
    return "\(String(raw.prefix(maxLength - 3)))..."
}

// MARK: - Structural-markdown read observation
//
// The READ observation (serializeFullMarkdown → renderFullNode) renders page CONTENT as
// clean, id-free markdown (headings `#`, list items `- `, table rows `| a | b |`, paragraphs)
// while every ACTIONABLE element keeps a trailing `{aloha-id="ID" tag}` marker so navigation
// never degrades (tab.click(id) / findByText still resolve).

public let FULL_CONTENT_TEXT_CAP = 1000
/// Shortest standalone content-leaf text worth surfacing. Below this it's almost always UI chrome
/// (a bare vote/count "0", a separator "."), never a price or label the reader needs.
let CONTENT_LEAF_MIN_CHARS = 3
public let INTERACTIVE_LABEL_CAP = 120

/// The trailing actionable marker appended to every interactive element's line, e.g.
/// ` {aloha-id="7959-1f3a9c2b" button}`. The literal `aloha-id="…"` token is a contract: id capture
/// in `findAlohaIdsInMarkdown` reads it back.
public func interactiveTrailer(_ node: DomNode, _ tag: String) -> String {
    return " {aloha-id=\"\(node.id)\" \(tag)}"
}

public let SELECT_OPTIONS_VISIBLE_CAP = 1000
public let SELECT_SELECTED_BEYOND_CAP = 50

public func renderSelectOptions(_ id: String, _ options: [DomSelectOption], _ multiple: Bool) -> String {
    if options.isEmpty { return "[options: empty]" }
    let multiLabel = multiple ? " (multi)" : ""
    let visibleCount = min(options.count, SELECT_OPTIONS_VISIBLE_CAP)
    var selectedBeyondCap: [(idx: Int, opt: DomSelectOption)] = []
    var y = SELECT_OPTIONS_VISIBLE_CAP
    while y < options.count {
        if options[y].selected {
            selectedBeyondCap.append((idx: y, opt: options[y]))
        }
        y += 1
    }
    let selectedBeyondShown = min(selectedBeyondCap.count, SELECT_SELECTED_BEYOND_CAP)
    var rendered: [String] = []
    var v = 0
    while v < visibleCount {
        let option = options[v]
        let normalized = normalizeWhitespace(option.text ?? option.value)
        let label = truncateLabel(normalized, 20)
        let marker = option.selected ? "*" : ""
        rendered.append("[\(id).\(v)] \(marker)\(label)")
        v += 1
    }
    var w = 0
    while w < selectedBeyondShown {
        let entry = selectedBeyondCap[w]
        let normalized = normalizeWhitespace(entry.opt.text ?? entry.opt.value)
        let label = truncateLabel(normalized, 20)
        rendered.append("[\(id).\(entry.idx)] *\(label)")
        w += 1
    }
    let moreCount = options.count - visibleCount - selectedBeyondShown
    let beyondOmitted = selectedBeyondCap.count - selectedBeyondShown
    if moreCount > 0 { rendered.append("... (+\(moreCount) more)") }
    if beyondOmitted > 0 { rendered.append("... (+\(beyondOmitted) selected beyond cap omitted)") }
    return "[options: \(rendered.joined(separator: ", "))\(multiLabel)]"
}

public func hasAccessibleNameAttribute(_ node: DomNode) -> Bool {
    let ariaLabel = node.element.attributes["aria-label"]
    let ariaPlaceholder = node.element.attributes["aria-placeholder"]
    return (ariaLabel != nil && !ariaLabel!.isEmpty) || (ariaPlaceholder != nil && !ariaPlaceholder!.isEmpty)
}

public func appendAnchorMetadata(_ rendered: String, _ node: DomNode, _ tag: String, _ includeUrls: Bool) -> String {
    var result = rendered
    if tag == "a" {
        if includeUrls, let href = node.element.attributes["href"], !href.isEmpty {
            result += " href=\"\(href)\""
        }
        if node.element.attributes["target"] == "_blank" {
            result += " [new tab]"
        }
        if node.element.attributes["download"] != nil {
            result += " [download]"
        }
    }
    return result
}

public func isElementDisabled(_ node: DomNode) -> Bool {
    let attributes = node.element.attributes
    let ariaDisabled = attributes["aria-disabled"]
    let hasDisabledAttr = attributes.keys.contains("disabled")
    return node.content.inputData?.disabled == true || hasDisabledAttr || ariaDisabled == "true"
}

private func appendAriaAttributes(_ rendered: String, _ node: DomNode, _ tag: String) -> String {
    var c = rendered
    let attrs = node.element.attributes
    var collected: [String] = []
    if let role = attrs["role"], !role.isEmpty { collected.append("role=\"\(role)\"") }
    if let v = attrs["aria-label"], !v.isEmpty { collected.append("aria-label=\"\(v)\"") }
    if let v = attrs["aria-placeholder"], !v.isEmpty { collected.append("aria-placeholder=\"\(v)\"") }
    if let v = attrs["aria-checked"], !v.isEmpty { collected.append("aria-checked=\"\(v)\"") }
    if let v = attrs["aria-expanded"], !v.isEmpty { collected.append("aria-expanded=\"\(v)\"") }
    if let v = attrs["aria-selected"], !v.isEmpty { collected.append("aria-selected=\"\(v)\"") }
    if let v = attrs["aria-pressed"], !v.isEmpty { collected.append("aria-pressed=\"\(v)\"") }
    if let v = attrs["aria-current"], !v.isEmpty { collected.append("aria-current=\"\(v)\"") }
    if let v = attrs["aria-haspopup"], !v.isEmpty { collected.append("aria-haspopup=\"\(v)\"") }
    if attrs["contenteditable"] == "true" { collected.append("contenteditable") }
    if let v = attrs["data-state"], !v.isEmpty { collected.append("data-state=\"\(v)\"") }
    if tag == "label", let forAttr = attrs["for"], !forAttr.isEmpty { collected.append("for=\"\(forAttr)\"") }
    if collected.count > 0 { c += " " + collected.joined(separator: " ") }
    return c
}

private func appendAriaStateMarkers(_ rendered: String, _ node: DomNode) -> String {
    var c = rendered
    let attrs = node.element.attributes
    if attrs["aria-expanded"] == "true" {
        c += " [aria: EXPANDED]"
    } else if attrs["aria-expanded"] == "false" {
        c += " [aria: COLLAPSED]"
    }
    if attrs["aria-selected"] == "true" { c += " [aria: SELECTED]" }
    if attrs["aria-pressed"] == "true" { c += " [aria: PRESSED]" }
    if attrs["aria-invalid"] == "true" { c += " [aria: INVALID]" }
    if attrs["aria-busy"] == "true" { c += " [aria: LOADING]" }
    return c
}

private func openInteractiveTag(_ node: DomNode, _ tag: String) -> String {
    var c = "<\(tag) aloha-id=\"\(node.id)\""
    if tag == "input" {
        if let inputData = node.content.inputData {
            var attrs: [String] = []
            if let placeholder = inputData.placeholder, !placeholder.isEmpty {
                attrs.append("placeholder=\"\(placeholder)\"")
            }
            if inputData.required { attrs.append("required=true") }
            c += " " + attrs.joined(separator: " ")
        }
    } else if tag == "select", node.content.optionData != nil {
        c += " name=\"\(node.element.attributes["name"] ?? "")\""
    } else if tag == "option" {
        let hasSelected = node.content.optionData?.options.contains { $0.selected } ?? false
        c += hasSelected ? " selected" : ""
    }
    return c
}

/// The overlay's own aloha-id, or `nil` when it has none.
///
/// It used to fall back to the covering element's TAG NAME, which put `[occ:div]` into the slot an
/// aloha-id occupies, under a legend reading "dismiss it to interact with [occ:div]-marked elements".
/// A tag name addresses nothing, and every unidentified `<div>` overlay on a page shared one key, so
/// the legend described the first and marked all of them. An overlay with no id is reported as
/// covered and named by its text instead.
func occlusionKey(_ occ: OccluderRef) -> String? {
    guard let id = occ.alohaId, !id.isEmpty else { return nil }
    return id
}

func occlusionMarker(_ node: DomNode) -> String {
    // `occludedBy` is set only by the hit-test probe when the element is fully covered, so it is
    // the authoritative signal here — independent of the lenient `isTopElement` heuristic, which
    // a sibling overlay can slip past.
    guard let occ = node.interactivity.occludedBy else { return "" }
    // Short, deduplicated reference: the overlay is described ONCE in the occlusion legend
    // `getInteractMarkdown` prepends (keyed by this same id), instead of repeating a ~60-char
    // "[occluded by … dismiss to interact]" suffix on every covered element.
    guard let key = occlusionKey(occ) else { return " [occluded]" }
    return " [occ:\(key)]"
}

/// One legend line per distinct overlay covering the page, built from the same
/// `occludedBy` data the per-node `[occ:id]` markers reference. Empty when nothing is
/// occluded. Lets the model see "one banner covers everything → dismiss it" at a glance.
public func occlusionLegend(_ nodes: [DomNode]) -> [String] {
    var lines: [String] = []
    var seen = Set<String>()
    for node in nodes {
        guard let occ = node.interactivity.occludedBy else { continue }
        let key = occlusionKey(occ)
        let marker = key.map { "[occ:\($0)]" } ?? "[occluded]"
        var d = "\(marker) = overlay <\(occ.tag.isEmpty ? "element" : occ.tag.lowercased())>"
        if let role = occ.role, !role.isEmpty { d += " role=\"\(role)\"" }
        if let raw = occ.text?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let safe = raw.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
            d += " \"\(truncateText(safe, 60))\""
        }
        d += key == nil
            ? " — no aloha-id to address it by; dismiss it to interact with [occluded]-marked elements below"
            : " — dismiss/close it to interact with \(marker)-marked elements below"
        if seen.contains(d) { continue }
        seen.insert(d)
        lines.append(d)
    }
    if lines.isEmpty { return [] }
    return ["--- overlays covering the page (dismiss to interact) ---"] + lines + ["---"]
}

/// Maps a vertical scroll axis to a directional phrase the model can act on, with a 4px
/// tolerance at each end.
func scrollPositionPhrase(_ axis: ScrollAxis) -> String {
    let maxOffset = axis.scrollSize - axis.clientSize
    if axis.offset <= 4 { return "top" }
    if axis.offset >= maxOffset - 4 { return "bottom" }
    // Past the midpoint there is more above than below, so point the agent the shorter way.
    return axis.offset * 2 > maxOffset ? "more above" : "more below"
}

/// Horizontal analogue of `scrollPositionPhrase`.
func scrollPositionPhraseH(_ axis: ScrollAxis) -> String {
    let maxOffset = axis.scrollSize - axis.clientSize
    if axis.offset <= 4 { return "left" }
    if axis.offset >= maxOffset - 4 { return "right" }
    return axis.offset * 2 > maxOffset ? "more left" : "more right"
}

/// The `[scrollable …]` suffix for a container the walker found scrollable: the scroll fraction
/// per overflowing axis and a direction hint, plus — for value-selector wheels — the centered
/// child so the agent sees the current selection. Replaces a blind run of values with a directed
/// readout it can step toward a target. Empty for non-scrollable nodes, so callers append it
/// unconditionally (same contract as `occlusionMarker`).
func scrollMarker(_ node: DomNode) -> String {
    guard let s = node.positioning.scroll else { return "" }
    func fraction(_ axis: ScrollAxis) -> Int {
        guard axis.scrollSize > axis.clientSize else { return 0 }
        return Int((Double(axis.offset) / Double(axis.scrollSize - axis.clientSize) * 100).rounded())
    }
    var parts: [String] = []
    if let v = s.vertical {
        parts.append("\u{2195} \(fraction(v))% \u{00B7} \(scrollPositionPhrase(v))")
    }
    if let h = s.horizontal {
        parts.append("\u{2194} \(fraction(h))% \u{00B7} \(scrollPositionPhraseH(h))")
    }
    if parts.isEmpty { return "" }
    var out = " [scrollable " + parts.joined(separator: " ") + "]"
    if let centered = s.centeredChild?.trimmingCharacters(in: .whitespacesAndNewlines), !centered.isEmpty {
        // Neutralize characters that would break the marker's own delimiters when this
        // page-controlled text is quoted back into the observation.
        let safe = centered
            .replacingOccurrences(of: "]", with: " ")
            .replacingOccurrences(of: "\"", with: "'")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        let t = truncateText(safe, 40)
        if !t.isEmpty { out += " [scroll selector \u{00B7} centered: \"\(t)\"]" }
    }
    return out
}

private func interactiveLabel(_ node: DomNode, _ nodesById: [String: DomNode]) -> String {
    if let ariaLabel = node.element.attributes["aria-label"], !ariaLabel.isEmpty {
        return truncateText(normalizeWhitespace(ariaLabel), INTERACTIVE_LABEL_CAP)
    }
    if let ariaPlaceholder = node.element.attributes["aria-placeholder"], !ariaPlaceholder.isEmpty {
        return truncateText(normalizeWhitespace(ariaPlaceholder), INTERACTIVE_LABEL_CAP)
    }
    let raw = (node.content.comprehensiveText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? node.content.comprehensiveText : nil) ?? node.element.textContent ?? ""
    let text = normalizeWhitespace(raw)
    if text.isEmpty { return "" }
    return truncateText(text, INTERACTIVE_LABEL_CAP)
}

private func renderInputControl(_ node: DomNode) -> String {
    var parts: [String] = []
    let data = node.content.inputData
    if let type = data?.type, !type.isEmpty { parts.append(type) }
    if let placeholder = data?.placeholder, !placeholder.isEmpty {
        parts.append("placeholder=\"\(normalizeWhitespace(placeholder))\"")
    }
    if data?.required == true { parts.append("required") }
    let label = interactiveLabel(node, [:])
    if !label.isEmpty { parts.append("\"\(label)\"") }
    return "input(\(parts.joined(separator: ", ")))"
}

/// Renders an interactive element as compact markdown plus its actionable trailer, so the
/// model reads page-shaped text yet every id survives for `tab.click(id)` / `findByText`.
func emitInViewportElement(_ node: DomNode, _ depth: Int, _ nodesById: [String: DomNode], _ options: DomSerializeOptions = DomSerializeOptions()) -> String {
    let tag = node.element.tagName.lowercased()
    if tag == "code" { return "" }
    // Dedup a promoted text wrapper whose ENTIRE label is already carried by an interactive
    // descendant that renders its own line (e.g. `<h1><a>Post title</a></h1>` would emit
    // `[Post title]{h1}` AND `[Post title]{a}`). The descendant keeps the aloha-id, so drop
    // the wrapper's duplicate line. An EXACT text match is required, so a wrapper with its
    // own text ("Submitted by <a>user</a>") and genuinely-actionable tags (a/button/…) are
    // untouched. This is the shared choke point of both render paths.
    if dedupWrapperTags.contains(tag) {
        let dupText = normalizeWhitespace(node.content.comprehensiveText ?? node.element.textContent ?? "")
        if !dupText.isEmpty,
           textDuplicatesDescendants(dupText, node, nodesById),
           hasInteractiveDescendant(node, nodesById) {
            return ""
        }
    }
    var c: String
    switch tag {
    case "a":
        let label = interactiveLabel(node, nodesById)
        if options.includeUrls, let href = node.element.attributes["href"], !href.isEmpty {
            c = "[\(label)](\(href))"
        } else {
            c = "[\(label)]"
        }
        // includeUrls=false: the href is already folded into the markdown link above.
        c = appendAnchorMetadata(c, node, tag, false)
    case "input":
        c = renderInputControl(node)
    case "select":
        let current = node.content.optionData?.options.first(where: { $0.selected }).map { normalizeWhitespace($0.text ?? $0.value ?? "") } ?? ""
        c = current.isEmpty ? "select" : "select \"\(truncateLabel(current, 40))\""
    case "textarea":
        let label = interactiveLabel(node, nodesById)
        c = label.isEmpty ? "textarea" : "textarea(\"\(label)\")"
    default:
        let label = interactiveLabel(node, nodesById)
        c = "[\(label)]"
    }
    if node.interactivity.isFileInput { c += " [uploadable]" }
    if isElementDisabled(node) { c += " [DISABLED]" }
    c = appendAriaStateMarkers(c, node)
    if tag == "select", let optionData = node.content.optionData {
        c += " " + renderSelectOptions(node.id, optionData.options, optionData.multiple)
    }
    c += interactiveTrailer(node, tag)
    return String(repeating: " ", count: min(depth, 4) * 2) + c
}

func emitOutOfViewElement(_ node: DomNode, _ depth: Int, _ nodesById: [String: DomNode], _ options: DomSerializeOptions = DomSerializeOptions()) -> String {
    let tag = node.element.tagName.lowercased()
    if tag == "code" { return "" }
    let text = node.content.comprehensiveText ?? node.element.textContent
    let isHeading = tag.hasPrefix("h") && tag.count == 2
    let isButton = tag == "button"
    let isInteractive = node.interactivity.isInteractive || node.interactivity.isInput || node.interactivity.isSelect
    let hasText = !(text ?? "").isEmpty
    if !hasText && !isHeading && !isButton && !isInteractive && tag != "nav" {
        return ""
    }
    var c = "<\(tag) aloha-id=\"\(node.id)\""
    if tag == "input" {
        if let placeholder = node.content.inputData?.placeholder, !placeholder.isEmpty {
            c += " placeholder=\"\(placeholder)\""
        }
    }
    c = appendAriaAttributes(c, node, tag)
    c += " />"
    if isElementDisabled(node) { c += " [DISABLED]" }
    c = appendAriaStateMarkers(c, node)
    c = appendAnchorMetadata(c, node, tag, options.includeUrls)
    if tag == "select", let optionData = node.content.optionData {
        c += " " + renderSelectOptions(node.id, optionData.options, optionData.multiple)
    }
    if !hasAccessibleNameAttribute(node) {
        let bodyText = (node.content.comprehensiveText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? node.content.comprehensiveText : nil) ?? node.element.textContent ?? ""
        if !bodyText.isEmpty && !textDuplicatesDescendants(bodyText, node, nodesById) {
            let truncated = truncateText(bodyText, 50)
            if !truncated.isEmpty { c += " " + truncated }
        }
    }
    return String(repeating: " ", count: min(depth, 6)) + c
}

func emitNearViewportElement(_ node: DomNode, _ depth: Int, _ nodesById: [String: DomNode], _ options: DomSerializeOptions = DomSerializeOptions()) -> String {
    let tag = node.element.tagName.lowercased()
    if tag == "code" { return "" }
    var c = openInteractiveTag(node, tag)
    c = appendAriaAttributes(c, node, tag)
    c += " />"
    if node.interactivity.isFileInput { c += " [uploadable]" }
    if isElementDisabled(node) { c += " [DISABLED]" }
    c = appendAriaStateMarkers(c, node)
    c = appendAnchorMetadata(c, node, tag, options.includeUrls)
    if tag == "select", let optionData = node.content.optionData {
        c += " " + renderSelectOptions(node.id, optionData.options, optionData.multiple)
    }
    if !hasAccessibleNameAttribute(node) {
        let text = (node.content.comprehensiveText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? node.content.comprehensiveText : nil) ?? node.element.textContent ?? ""
        if !text.isEmpty && !textDuplicatesDescendants(text, node, nodesById) {
            let truncated = truncateText(text, 50)
            if !truncated.isEmpty { c += " " + truncated }
        }
    }
    return String(repeating: " ", count: min(depth, 6)) + c
}

func emitFarViewportElement(_ node: DomNode, _ depth: Int, _ nodesById: [String: DomNode], _ options: DomSerializeOptions = DomSerializeOptions()) -> String {
    let tag = node.element.tagName.lowercased()
    if tag == "code" { return "" }
    var c = openInteractiveTag(node, tag)
    c = appendAriaAttributes(c, node, tag)
    c += " />"
    if node.interactivity.isFileInput { c += " [uploadable]" }
    if isElementDisabled(node) { c += " [DISABLED]" }
    c = appendAriaStateMarkers(c, node)
    c = appendAnchorMetadata(c, node, tag, options.includeUrls)
    if tag == "select", let optionData = node.content.optionData {
        c += " " + renderSelectOptions(node.id, optionData.options, optionData.multiple)
    }
    if !hasAccessibleNameAttribute(node) {
        let text = (node.content.comprehensiveText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? node.content.comprehensiveText : nil) ?? node.element.textContent ?? ""
        if !text.isEmpty && !textDuplicatesDescendants(text, node, nodesById) {
            let truncated = truncateText(text, 20)
            if !truncated.isEmpty { c += " " + truncated }
        }
    }
    return String(repeating: " ", count: min(depth, 6)) + c
}

/// Tags that get PROMOTED to "interactive" purely because they carry text (the
/// text-content promotion in the DOM walker), so they emit a `[label]` line. When such a
/// wrapper's entire label is already carried by an interactive descendant, both lines
/// duplicate the same text — this set marks the wrappers eligible to be deduped away.
private let dedupWrapperTags: Set<String> = [
    "h1", "h2", "h3", "h4", "h5", "h6", "span", "li", "p", "strong", "em", "small", "label", "div"
]

/// The descendant that keeps the aloha-id when a pure text wrapper around it is deduped.
private func hasInteractiveDescendant(_ node: DomNode, _ nodesById: [String: DomNode]) -> Bool {
    for childId in node.children {
        guard let child = nodesById[childId] else { continue }
        let tag = child.element.tagName.lowercased()
        if ["a", "button", "input", "select", "textarea", "summary"].contains(tag) { return true }
        if hasInteractiveDescendant(child, nodesById) { return true }
    }
    return false
}

func renderInteractiveNode(_ node: DomNode, _ depth: Int, _ nodesById: [String: DomNode], _ options: DomSerializeOptions = DomSerializeOptions()) -> String {
    if node.nodeType == "TEXT_NODE" {
        if node.positioning.distanceToViewportBorder > 0 || !node.positioning.isInViewport || !node.positioning.isVisible {
            return ""
        }
        let text = truncateText(node.element.textContent ?? node.element.childText ?? "", 200)
        return text.isEmpty ? "" : String(repeating: " ", count: min(depth, 6)) + text
    }
    let tag = node.element.tagName.lowercased()
    if STRUCTURE_TAGS.contains(tag) && node.children.count > 0 {
        var c = "<\(tag) aloha-id=\"\(node.id)\""
        if let role = node.element.attributes["role"], !role.isEmpty {
            c += " role=\"\(role)\""
        }
        if let ariaLabel = node.element.attributes["aria-label"], !ariaLabel.isEmpty {
            c += " aria-label=\"\(ariaLabel)\""
        }
        if tag == "fieldset" {
            if let name = node.element.attributes["name"], !name.isEmpty {
                c += " name=\"\(name)\""
            }
            if isElementDisabled(node) { c += " [DISABLED]" }
        }
        c += " />"
        return String(repeating: " ", count: min(depth, 6)) + c
    }
    if INLINE_TEXT_TAGS.contains(tag) && node.positioning.isVisible {
        let text = truncateText(node.content.comprehensiveText ?? node.element.textContent ?? "", 200)
        if !text.isEmpty {
            var c = "<\(tag) aloha-id=\"\(node.id)\""
            if let role = node.element.attributes["role"], !role.isEmpty {
                c += " role=\"\(role)\""
            }
            c += " /> " + text
            return String(repeating: " ", count: min(depth, 6)) + c
        }
    }
    let isCheckOrRadio = tag == "input" && (node.content.inputData?.type == "checkbox" || node.content.inputData?.type == "radio")
    let isTop = node.interactivity.isTopElement || isCheckOrRadio
    // An interactive element the hit-test found covered is KEPT and annotated rather than
    // silently dropped, so the model can see it and dismiss whatever overlays it. Decorative /
    // non-interactive occluded nodes still fall through to the drop below.
    let occludedInteractive = node.interactivity.occludedBy != nil
        && node.interactivity.isInteractive
        && node.positioning.isVisible
    // A scrollable container is often a plain non-interactive div that the keep test would drop;
    // keep it so its tag and `[scrollable …]` readout reach the model alongside its aloha-id.
    let scrollableKept = node.positioning.scroll != nil && node.positioning.isVisible
    // A sealed region is kept for the same reason an occluded element is: an <iframe>
    // carrying no text would otherwise be dropped right back into the silent gap the marker
    // exists to break. Visibility is required as in the two rules above — a display:none
    // tracking frame occupies no pixels and must not be offered as clickable.
    let sealedKept = node.sealedMarker != nil && node.positioning.isVisible
    if (!node.interactivity.isHighlighted || !isTop) && !occludedInteractive && !scrollableKept && !sealedKept { return "" }
    let distance = abs(node.positioning.distanceToViewportBorder)
    let line: String
    if distance == 0 {
        line = emitInViewportElement(node, depth, nodesById, options)
    } else if distance > 0 && distance < 3000 {
        line = emitNearViewportElement(node, depth, nodesById, options)
    } else if distance >= 3000 && distance < 5000 {
        line = emitFarViewportElement(node, depth, nodesById, options)
    } else {
        line = ""
    }
    if line.isEmpty { return "" }
    return line + occlusionMarker(node) + scrollMarker(node) + (node.sealedMarker ?? "")
}

private func headingPrefix(_ tag: String) -> String? {
    guard tag.count == 2, tag.hasPrefix("h"), let n = Int(tag.dropFirst()), n >= 1, n <= 6 else { return nil }
    return String(repeating: "#", count: n)
}

private func contentText(_ node: DomNode) -> String {
    let raw = node.content.comprehensiveText ?? node.element.textContent ?? ""
    return truncateText(normalizeWhitespace(raw), FULL_CONTENT_TEXT_CAP)
}

/// Tags whose own line is suppressed because the walker renders their content via children
/// (list containers descend to `<li>`; table containers descend to `<tr>`; cells are folded
/// into their row).
private let STRUCTURAL_CONTAINER_TAGS: Set<String> = ["ul", "ol", "table", "thead", "tbody", "tfoot", "th", "td", "colgroup", "col"]

/// A header row (cells are `<th>`) is followed by a `| --- |` separator.
private func renderTableRow(_ node: DomNode, _ nodesById: [String: DomNode]) -> String {
    var cells: [String] = []
    var sawTh = false
    for childId in node.children {
        guard let cell = nodesById[childId] else { continue }
        let cellTag = cell.element.tagName.lowercased()
        guard cellTag == "th" || cellTag == "td" else { continue }
        if !cell.positioning.isVisible { continue }
        if cellTag == "th" { sawTh = true }
        cells.append(contentText(cell))
    }
    if cells.isEmpty { return "" }
    let row = "| " + cells.joined(separator: " | ") + " |"
    if sawTh {
        let sep = "| " + cells.map { _ in "---" }.joined(separator: " | ") + " |"
        return row + "\n" + sep
    }
    return row
}

/// Whether a node renders as a kept interactive element (gets an actionable `{aloha-id …}` trailer).
func nodeIsKeptInteractive(_ node: DomNode) -> Bool {
    let tag = node.element.tagName.lowercased()
    let isCheckOrRadio = tag == "input" && (node.content.inputData?.type == "checkbox" || node.content.inputData?.type == "radio")
    let isTop = node.interactivity.isTopElement || isCheckOrRadio
    let occludedInteractive = node.interactivity.occludedBy != nil
        && node.interactivity.isInteractive
        && node.positioning.isVisible
    let scrollableKept = node.positioning.scroll != nil && node.positioning.isVisible
    // A sealed region is always an <iframe> — the only two places that set `sealedMarker`
    // both produce one — so it reaches the serializer through the two branches that admit
    // an iframe: here, and the early keep test in `renderInteractiveNode`. The structural
    // landmark branch of `renderFullNode` is gated on STRUCTURE_TAGS (header, footer,
    // aside, main, article, section, nav, fieldset) and can never see one, so it appends
    // no sealed marker. That asymmetry is deliberate; verified by instrumenting that
    // branch to shout and running every suite, including real Chrome — it never fired.
    let sealedKept = node.sealedMarker != nil && node.positioning.isVisible
    return (node.interactivity.isHighlighted && isTop) || occludedInteractive || scrollableKept || sealedKept
}

/// Lowercased letters+digits only, so the same title text matches whether or not
/// punctuation/whitespace differ.
private func dedupKey(_ s: String) -> String {
    return s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
}

/// Value symbols that make a short string worth keeping even under the min-length gate — a "£5"
/// price or "20%" must survive while a bare vote-count "0"/"19" is dropped.
private let VALUE_SYMBOLS: Set<Character> = ["£", "$", "€", "¥", "₽", "₹", "%"]

/// A content-bearing leaf that `renderFullNode` would otherwise drop — a non-highlighted element
/// with no content branch, e.g. `<div class="price">£89.95</div>`. Its text is surfaced **once**,
/// and only when it is a leaf among the KEPT nodes (never an aggregating container like
/// `<ul>`/`<table>`, whose text is just its children joined).
///
/// `emittedAncestorKeys` holds the dedup keys of the *emitted* ancestor lines (the enclosing card).
/// Dedup is EXACT key membership, not substring containment: a title is dropped because it equals an
/// emitted ancestor's text, while a price like "£399" is never equal to the title and so is always
/// kept — even when the ancestor's label was truncated or the price is a substring of the title.
private func contentLeafLine(_ node: DomNode, _ listLevel: Int, _ nodesById: [String: DomNode], _ emittedAncestorKeys: Set<String>) -> String? {
    guard node.nodeType != "TEXT_NODE" else { return nil }   // text nodes are handled by renderFullNode
    guard node.positioning.isInViewport, node.positioning.isVisible else { return nil }
    let tag = node.element.tagName.lowercased()
    if STRUCTURAL_CONTAINER_TAGS.contains(tag) { return nil }
    if STRUCTURE_TAGS.contains(tag) { return nil }
    // Leaf among kept nodes only: if any child resolves to a kept node, that child carries the text.
    for childId in node.children where nodesById[childId] != nil { return nil }
    let raw = (node.content.comprehensiveText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
               ? node.content.comprehensiveText : nil) ?? node.element.textContent ?? ""
    let text = normalizeWhitespace(raw)
    guard text.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
    let hasValueSymbol = text.contains(where: { VALUE_SYMBOLS.contains($0) })
    guard text.count >= CONTENT_LEAF_MIN_CHARS || hasValueSymbol else { return nil }
    let key = dedupKey(text)
    if !key.isEmpty, emittedAncestorKeys.contains(key) { return nil }
    let indent = String(repeating: " ", count: min(max(listLevel, 0), 4) * 2)
    return indent + truncateText(text, FULL_CONTENT_TEXT_CAP)
}

/// Punctuation that never takes a space before it when prose parts are rejoined.
private let CLINGING_PUNCTUATION: Set<Character> = [".", ",", ";", ":", "!", "?", ")", "]", "}", "%", "\u{2019}"]

/// Renders a PROSE block as ONE line in document order, keeping inline link/button text IN
/// PLACE with its `{aloha-id …}` trailer, and reporting every node id it consumed so the walker
/// does not re-emit the same sentence as loose fragments. Returns nil when the node has no
/// serializable children, in which case the caller falls back to `contentText`.
///
/// The walker's own `comprehensiveText` cannot carry prose: the in-page collector builds it from
/// the element's direct text nodes PLUS `getFirstDescendantText`, which deliberately stops at
/// every interactive descendant (right for a control's label, fatal for a sentence). So a
/// paragraph with inline `<a>`s came back as the sentence TWICE — once without `<b>`, once with —
/// and with every link's words deleted from both, then a third time as one line per fragment.
private func proseLine(
    _ node: DomNode,
    _ nodesById: [String: DomNode],
    _ options: DomSerializeOptions,
    _ consumed: inout Set<String>
) -> String? {
    var parts: [String] = []
    var seen = Set<String>()    // recursion guard
    var taken = Set<String>()   // ids folded into this line — the walker must not print them again
    func visit(_ id: String) {
        guard let child = nodesById[id], !seen.contains(id) else { return }
        seen.insert(id)
        taken.insert(id)
        if child.nodeType == "TEXT_NODE" {
            let text = normalizeWhitespace(child.element.textContent ?? child.element.childText ?? "")
            if !text.isEmpty { parts.append(text) }
            return
        }
        let childTag = child.element.tagName.lowercased()
        if nodeIsKeptInteractive(child) {
            // A PROMOTED text wrapper (a `<span>`/`<div>` "interactive" only because it carries
            // text) is left to the walker, which already dedups its redundant `{aloha-id}` label
            // line against the content line above it. Only a genuinely actionable element is
            // folded in here.
            if dedupWrapperTags.contains(childTag) {
                taken.remove(id)
                return
            }
            let line = emitInViewportElement(child, 0, nodesById, options)
            if !line.isEmpty {
                parts.append(line + occlusionMarker(child) + scrollMarker(child) + (child.sealedMarker ?? ""))
                return
            }
            // `emitInViewportElement` returns "" for `<code>` and for a wrapper whose label an
            // interactive descendant already carries — descend rather than swallow the subtree.
        }
        for grandchild in child.children { visit(grandchild) }
    }
    for childId in node.children { visit(childId) }
    if parts.isEmpty { return nil }
    consumed.formUnion(taken)
    // The whitespace that separated the original nodes is already gone (`normalizeWhitespace`),
    // so the parts are rejoined with a single space — except before clinging punctuation
    // ("… the community. It uses …", not "… the community . It …").
    var joined = ""
    for part in parts {
        if !joined.isEmpty, !(part.first.map { CLINGING_PUNCTUATION.contains($0) } ?? false) { joined += " " }
        joined += part
    }
    return truncateText(joined, FULL_CONTENT_TEXT_CAP)
}

func renderFullNode(
    _ node: DomNode,
    _ depth: Int,
    _ nodesById: [String: DomNode],
    _ options: DomSerializeOptions = DomSerializeOptions(),
    _ consumed: inout Set<String>
) -> String {
    if node.nodeType == "TEXT_NODE" {
        if !node.positioning.isInViewport { return "" }
        let text = truncateText(normalizeWhitespace(node.element.textContent ?? node.element.childText ?? ""), FULL_CONTENT_TEXT_CAP)
        return text.isEmpty ? "" : text
    }
    let tag = node.element.tagName.lowercased()

    // Interactive elements take priority: they always render with their actionable trailer so
    // navigation never degrades, even when they sit inside a heading / list item / cell.
    if nodeIsKeptInteractive(node) && !STRUCTURE_TAGS.contains(tag) {
        let line = emitInViewportElement(node, depth, nodesById, options)
        return line.isEmpty ? "" : line + occlusionMarker(node) + scrollMarker(node) + (node.sealedMarker ?? "")
    }

    if let prefix = headingPrefix(tag), node.positioning.isVisible {
        let text = proseLine(node, nodesById, options, &consumed) ?? contentText(node)
        return text.isEmpty ? "" : "\(prefix) \(text)"
    }

    // `depth` here is the list-nesting level supplied by the walker (1 inside the outermost
    // <ul>/<ol>), so the indent is `(level - 1)` clamped to [0, 4].
    if tag == "li" && node.positioning.isVisible {
        let text = contentText(node)
        let indentLevel = min(max(depth - 1, 0), 4)
        return String(repeating: " ", count: indentLevel * 2) + "- " + text
    }

    // Containers and cells render nothing on their own line; their content is folded into the row.
    if tag == "tr" {
        return renderTableRow(node, nodesById)
    }
    if STRUCTURAL_CONTAINER_TAGS.contains(tag) { return "" }

    // Structural landmarks (nav/main/header/…) keep a minimal line + trailer so their ids stay
    // clickable and occlusion/scroll keep keying off them.
    if STRUCTURE_TAGS.contains(tag) && node.children.count > 0 {
        var c = "[\(tag)"
        if let role = node.element.attributes["role"], !role.isEmpty { c += " role=\"\(role)\"" }
        if let ariaLabel = node.element.attributes["aria-label"], !ariaLabel.isEmpty { c += " \"\(normalizeWhitespace(ariaLabel))\"" }
        c += "]"
        if tag == "fieldset", isElementDisabled(node) { c += " [DISABLED]" }
        // Expose the aloha-id ONLY on a landmark that is genuinely actionable (a clickable
        // nav/header — rare). A PURE structural landmark keeps its line for page-shape context
        // but drops the id trailer: the agent never clicks a `[nav]` / `[header]` / `[article]`
        // container, yet those accounted for ~1/3 of a snapshot's id markers (~800 tok on a
        // forum listing). The node keeps its INTERNAL id, so occlusion / scroll / findByText
        // keying is unaffected — only the redundant on-screen marker is dropped.
        if node.interactivity.isInteractive || node.interactivity.isInput || node.interactivity.isSelect {
            c += interactiveTrailer(node, tag)
        }
        return c + occlusionMarker(node) + scrollMarker(node)
    }

    if INLINE_TEXT_TAGS.contains(tag) && node.positioning.isVisible {
        let text = proseLine(node, nodesById, options, &consumed) ?? contentText(node)
        return text.isEmpty ? "" : text
    }
    return ""
}

public func serializeFullMarkdown(_ nodes: [DomNode], _ options: DomSerializeOptions = DomSerializeOptions()) -> String {
    var nodesById: [String: DomNode] = [:]
    for node in nodes { nodesById[node.id] = node }
    var childIds = Set<String>()
    for node in nodes {
        for childId in node.children { childIds.insert(childId) }
    }
    let roots = nodes.filter { !childIds.contains($0.id) }
    var output: [String] = []
    var visited = Set<String>()
    // `listLevel` is the list-nesting depth (number of <ul>/<ol> ancestors), which drives `<li>`
    // indentation; other structural lines render flush-left and ignore it. `emittedAncestorKeys`
    // holds the dedup keys of ancestors that actually emitted a line (the enclosing "card"), so a
    // content leaf can skip reprinting text the card already showed — by EXACT key match, never
    // substring, so values like prices are never mistaken for the title.
    func walk(_ id: String, _ listLevel: Int, _ emittedAncestorKeys: Set<String>, _ shownTextKeys: Set<String>) {
        guard let node = nodesById[id], !visited.contains(id) else { return }
        visited.insert(id)
        let tag = node.element.tagName.lowercased()
        // Drop a PROMOTED text wrapper (span/div/p/h*/li/…) whose whole text an ancestor
        // already SHOWED as a content line — e.g. a byline `<span>` promoted to a label line
        // that just repeats the `<p>` content rendered above it. `shownTextKeys` holds ONLY
        // the keys of ancestors whose rendered line genuinely displayed the text, so a
        // landmark `[header]` line (which shows the tag, not its subtree text) never triggers
        // this. Genuinely-actionable tags (a/button/input) are NOT in `dedupWrapperTags`, so
        // their ids are never dropped; the wrapper's own interactive children still render.
        if node.interactivity.isHighlighted, node.nodeType != "TEXT_NODE", dedupWrapperTags.contains(tag) {
            let key = dedupKey(normalizeWhitespace(node.content.comprehensiveText ?? node.element.textContent ?? ""))
            if !key.isEmpty, shownTextKeys.contains(key) {
                for childId in node.children { walk(childId, listLevel, emittedAncestorKeys, shownTextKeys) }
                return
            }
        }
        // A prose block renders its whole subtree into ONE line and reports those ids here, so
        // the walker does not print the same sentence again fragment by fragment.
        var consumed = Set<String>()
        let rendered = renderFullNode(node, listLevel, nodesById, options, &consumed)
        visited.formUnion(consumed)
        if !rendered.isEmpty {
            output.append(rendered)
        } else if let contentLine = contentLeafLine(node, listLevel, nodesById, emittedAncestorKeys) {
            output.append(contentLine)
        }
        var nextKeys = emittedAncestorKeys
        var nextShown = shownTextKeys
        if !rendered.isEmpty {
            let own = dedupKey(normalizeWhitespace(node.content.comprehensiveText ?? node.element.textContent ?? ""))
            if !own.isEmpty {
                nextKeys.insert(own)
                // Register as "shown" ONLY when the rendered line genuinely contains this text
                // (a content line or a promoted label) — never a landmark tag-line, whose
                // comprehensiveText is the whole subtree and would wrongly suppress content.
                if dedupKey(rendered).contains(own) { nextShown.insert(own) }
            }
        }
        let childListLevel = (tag == "ul" || tag == "ol") ? listLevel + 1 : listLevel
        for childId in node.children {
            walk(childId, childListLevel, nextKeys, nextShown)
        }
    }
    for root in roots {
        walk(root.id, 0, [], [])
    }
    return output.joined(separator: "\n")
}

public func buildOutOfViewSummary(_ nodes: [DomNode], _ direction: String, _ nodesById: [String: DomNode], _ options: DomSerializeOptions = DomSerializeOptions()) -> [String] {
    if nodes.isEmpty { return [] }
    let priorityOrder = ["h1", "h2", "h3", "h4", "h5", "h6", "nav", "button", "input", "select", "textarea", "p", "a"]
    let sorted = nodes.sorted { a, b in
        let aTag = a.element.tagName.lowercased()
        let bTag = b.element.tagName.lowercased()
        let aIndex = priorityOrder.firstIndex(of: aTag) ?? -1
        let bIndex = priorityOrder.firstIndex(of: bTag) ?? -1
        if aIndex != -1 && bIndex != -1 {
            if aIndex != bIndex { return aIndex < bIndex }
            return abs(a.positioning.distanceToViewportBorder) < abs(b.positioning.distanceToViewportBorder)
        }
        if aIndex != -1 { return true }
        if bIndex != -1 { return false }
        return abs(a.positioning.distanceToViewportBorder) < abs(b.positioning.distanceToViewportBorder)
    }
    let maxElements = 15
    var picked: [DomNode] = []
    let headingsAndControls = sorted.filter { node in
        let tag = node.element.tagName.lowercased()
        return ["h1", "h2", "h3", "h4", "h5", "h6", "nav", "button", "input", "select", "textarea"].contains(tag)
    }
    let paragraphsAndLinks = sorted.filter { node in
        let tag = node.element.tagName.lowercased()
        return ["p", "a"].contains(tag)
    }
    let others = sorted.filter { node in
        let tag = node.element.tagName.lowercased()
        return !["h1", "h2", "h3", "h4", "h5", "h6", "button", "input", "select", "textarea", "p", "a"].contains(tag)
    }
    picked.append(contentsOf: headingsAndControls.prefix(8))
    if picked.count < maxElements {
        picked.append(contentsOf: paragraphsAndLinks.prefix(min(4, maxElements - picked.count)))
    }
    if picked.count < maxElements {
        picked.append(contentsOf: others.prefix(maxElements - picked.count))
    }
    let rendered = picked.map { emitOutOfViewElement($0, 0, nodesById, options) }
    let total = nodes.count
    let shown = picked.count
    if total - shown > 0 {
        let suffix = "... and \(total - shown) more elements (\(direction == "above" ? "scroll up" : "scroll down") to see all)"
        return rendered + [suffix]
    }
    return rendered
}
