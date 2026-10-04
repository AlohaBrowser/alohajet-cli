import Foundation
import ToolABI

// MARK: - Stable CSS selector derivation (step trace)

/// Derives a STABLE CSS selector for one serialized DOM node, or `nil` when
/// nothing on the node justifies one.
///
/// WHY this exists: the page tools address elements by `aloha_id`, which
/// the walker's `alohaIdFor` derives by hashing either an authored name
/// (`#id`, `[data-testid]`) or the node's frame-scoped xpath. That is stable
/// across walks of the same page, but it is a HASH, not a selector: a consumer of
/// the step trace — a tool turning a recorded trajectory into a replayable
/// script, or a human reading it — has no page to resolve it against
/// and no way to compute it. A real CSS selector re-resolves on the live page.
///
/// The walker ports this ladder's ORDERING (authored name before position) and
/// deliberately NOT its validation. The two cannot drift, because they share no
/// invariant: this output is a CSS selector pasted into `querySelector`
/// unescaped, so it needs `isValidCSSIdentifier` / `isSafeAttributeValue`; the
/// walker's output is a hash preimage that nothing pastes and nothing escapes.
/// Duplicating these ~120 lines into JS to make them "the same everywhere" would
/// be the drift hazard, not the protection against it.
///
/// The derivation is deliberately CONSERVATIVE: it returns `nil` rather than a
/// selector it cannot justify. A guessed selector is worse than no selector,
/// because a replay built on it would silently target the wrong element.
///
/// Priority order, most stable first:
/// 1. `#id` — when `id` is a valid CSS identifier AND a person plausibly wrote it. An id a
///    framework generated per render (`#JV2FMF8`) is skipped: measured across two runs of the
///    same preset, Magento's admin gave the SAME quantity field `#CD26XAH` in one session and
///    `#JV2FMF8` in the next, and a scenario minted on either failed to replay. Skipped rather
///    than demoted — a selector that cannot resolve is worth less than the position path below it.
/// 2. `[data-testid="…"]`, then `[data-test="…"]` — put there on purpose by the
///    site's own authors, precisely so automation can find the element.
/// 3. `[name="…"]` — form-field identity, part of the site's wire contract.
/// 4. `input[type="…"]` — weak but real for form controls.
/// 4b. `a[href="/path"]` — a link's RELATIVE destination, no query and no fragment. Where a link
///    goes is what it IS: `a[href="/v2ray/v2ray-core"]` outlives any re-layout, where the
///    25-segment position path the same link got before did not (github-ss r5, 2026-09-22). An
///    absolute or parametrised href is refused here: a host or a tracking parameter is not
///    identity (the anchor rule may still name it verbatim when it is unique on the page).
/// 4c. `tag[role="…"]` — an interactive ARIA role (`menuitemradio`, `tab`, `option`, …). Weak on
///    its own, and that is fine: the receipt says which of the matches it was (`[index=i/N]`).
///    A component library's list item usually has nothing else authored on it (GitHub's "Most
///    stars": a generated id, hashed classes, this role).
/// 5. `tag.classA.classB` — only STABLE-LOOKING classes; build-time hashed classes
///    (`css-1x2y3z`, `sc-AbCdEf`, `Button_root__2xY3z`, Primer's `…-KBb8-`, a CSS-modules
///    `…___zQrEw`) are refused because they change on every build of the site.
/// 6. The element's POSITION: `body>div:nth-of-type(3)>form>input:nth-of-type(2)`,
///    converted segment for segment from the xpath the walker computed against the live
///    document (`DomElement.xpath`). Exact for the page as it was, and re-resolvable by
///    `querySelector` on any later visit to a page of the same shape. It is a guess about
///    the NEXT visit only in the sense that every selector is: a site that reorders its
///    markup breaks a path the way it breaks a class, and a replayer that waits on the
///    selector fails loudly rather than clicking elsewhere. Measured need: over 273
///    successful WebArena trajectories the first five rules left most clicks with no
///    selector (page_click named one in 4370 of 8703 receipts, page_type in 270 of 2120).
///
/// Nothing matched → `nil`. In particular the `aloha-id` attribute is never used
/// — it is stable but not re-resolvable off the page — and a bare tag selector is
/// never emitted on its own (a path always begins at `body`).
public func stableCSSSelector(for node: DomNode) -> String? {
    StepTraceSelector.selector(for: node)
}

/// The pure helpers behind ``stableCSSSelector(for:)`` plus the step-trace's
/// tool-arg lookup for the element a page tool addressed. Namespaced so the
/// identifier-validation rules are individually reachable from tests.
public enum StepTraceSelector {

    /// The tool-argument keys a page tool names its target element with.
    /// `page_click` / `page_type` / `get_text` / `page_select` / `page_press_keys` /
    /// `page_wait_for` / `upload_file` all use `aloha_id`; the camelCase spelling is
    /// tolerated because models occasionally emit it.
    public static let alohaIdArgKeys = ["aloha_id", "alohaId"]

    /// At most this many class tokens go into the class fallback, so the selector
    /// stays short and does not over-constrain on incidental state classes.
    public static let maxClassTokens = 2

    /// Values longer than this are refused — a selector built from a paragraph of
    /// text is not a handle, it is noise.
    public static let maxValueLength = 120

    /// The longest position path emitted, in segments. Thirty-two: deeper than any
    /// page the walker has shipped a node from, and a bound so a pathological document
    /// cannot put a kilobyte of selector on a receipt.
    public static let maxPathSegments = 32

    // MARK: Entry points

    /// The element id a page tool addressed in its arguments, when any.
    public static func alohaId(inArgs args: JSValue) -> String? {
        for key in alohaIdArgKeys {
            if let value = args.string(key), !value.isEmpty { return value }
        }
        return nil
    }

    /// The derivation itself; see ``stableCSSSelector(for:)`` for the contract.
    static func selector(for node: DomNode) -> String? {
        let attributes = node.element.attributes
        let tag = normalizedTag(node.element.tagName)

        // 1. #id — unless a GENERATOR wrote it, in which case it is a handle only for
        //    this render and re-resolves to nothing on the next visit.
        if let id = attributes["id"], isValidCSSIdentifier(id), !looksGenerated(id) {
            return "#" + id
        }
        // 2. explicit test hooks, screened like an id: a hook the framework numbers per render
        //    (`data-testid="radix-3"`) resolves to nothing on the next visit either (2026-10-04 audit).
        for key in ["data-testid", "data-test"] {
            if let value = attributes[key], isSafeAttributeValue(value), !looksGenerated(value) {
                return "[\(key)=\"\(value)\"]"
            }
        }
        // 3. form-field name
        if let name = attributes["name"], isSafeAttributeValue(name) {
            return "[name=\"\(name)\"]"
        }
        // 4. input type (scoped to the tag — `type` alone is not an identity)
        if let tag, tag == "input", let type = attributes["type"], isSafeAttributeValue(type) {
            return "\(tag)[type=\"\(type)\"]"
        }
        // 4b. a link's relative destination
        if let tag, tag == "a", let href = attributes["href"], isRelativePathHref(href) {
            return "\(tag)[href=\"\(href)\"]"
        }
        // 4c. an interactive ARIA role
        if let role = attributes["role"]?.trimmingCharacters(in: .whitespaces).lowercased(),
           interactiveRoles.contains(role) {
            return (tag ?? "") + "[role=\"\(role)\"]"
        }
        // 5. tag + stable classes
        if let tag {
            let classes = stableClassTokens(attributes["class"])
            if !classes.isEmpty {
                return ([tag] + classes).joined(separator: ".")
            }
        }
        // 6. the element's position, from the walker's xpath
        if let xpath = node.element.xpath, let path = structuralSelector(fromXPath: xpath) {
            return path
        }
        return nil
    }

    /// `/body/div[3]/form/input[2]` -> `body>div:nth-of-type(3)>form>input:nth-of-type(2)`.
    ///
    /// The walker writes an index only where the parent has several children of the same
    /// tag (`getSiblingIndex`), so a bare segment IS the only child of its tag and needs no
    /// `:nth-of-type`; an indexed one maps exactly to `nth-of-type`, never `nth-child`. Refused
    /// outright -- `nil`, never a partial path -- when the xpath does not start at a root, any
    /// segment's tag is not a plain identifier (a `text()` node, a namespaced tag), an index is
    /// not a positive integer, or the path is longer than `maxPathSegments`.
    static func structuralSelector(fromXPath xpath: String) -> String? {
        let trimmed = xpath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        var segments: [String] = []
        for raw in trimmed.split(separator: "/", omittingEmptySubsequences: false) {
            let part = String(raw)
            if part.isEmpty { continue }
            var tagPart = part
            var index: String?
            if let open = part.firstIndex(of: "[") {
                guard part.hasSuffix("]") else { return nil }
                tagPart = String(part[part.startIndex..<open])
                index = String(part[part.index(after: open)..<part.index(before: part.endIndex)])
            }
            guard let tag = normalizedTag(tagPart) else { return nil }
            if let index {
                guard !index.isEmpty, index.allSatisfy({ $0.isASCII && $0.isNumber }),
                      Int(index).map({ $0 >= 1 }) == true else { return nil }
                segments.append("\(tag):nth-of-type(\(index))")
            } else {
                segments.append(tag)
            }
        }
        guard !segments.isEmpty, segments.count <= maxPathSegments else { return nil }
        // NO WHITESPACE, by the same contract `isSafeAttributeValue` keeps: a consumer must be
        // able to tokenize a step line without quoting rules. The space around a child combinator
        // is optional in CSS, so `body>div:nth-of-type(3)` is the same selector as the spaced one.
        return segments.joined(separator: ">")
    }

    // MARK: Validation

    /// The tag name lowercased, or `nil` when the walker reported none / a tag that
    /// is not a plain identifier (a selector must never carry raw junk).
    static func normalizedTag(_ tagName: String) -> String? {
        let lower = tagName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lower.isEmpty, isValidCSSIdentifier(lower) else { return nil }
        return lower
    }

    /// Whether `value` is a CSS identifier that can be written into a selector
    /// UNESCAPED: ASCII letters / digits / `-` / `_` / non-ASCII, not starting with
    /// a digit (nor with `-` followed by a digit). Everything else — a colon (React
    /// `useId` emits `:r3:`), whitespace, a quote, a dot, a bracket — is refused
    /// rather than escaped: the trace's job is to record a selector a consumer can
    /// paste into `querySelector`, and a hand-escaped one invites a parser mismatch.
    public static func isValidCSSIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= maxValueLength else { return false }
        let scalars = Array(value.unicodeScalars)
        func isNameChar(_ scalar: Unicode.Scalar) -> Bool {
            if scalar.value >= 0x80 { return true }
            let char = Character(scalar)
            return char.isASCII && (char.isLetter || char.isNumber || char == "-" || char == "_")
        }
        guard scalars.allSatisfy(isNameChar) else { return false }
        func isASCIIDigit(_ scalar: Unicode.Scalar) -> Bool { scalar.value >= 0x30 && scalar.value <= 0x39 }
        if isASCIIDigit(scalars[0]) { return false }
        if scalars[0] == "-" {
            guard scalars.count > 1, !isASCIIDigit(scalars[1]) else { return false }
        }
        return true
    }

    /// Whether `value` is safe to place inside a quoted attribute selector. Refuses
    /// the empty string, over-long values, quotes, backslashes, control characters —
    /// and, conservatively, ANY whitespace: a quoted value with a space is legal CSS,
    /// but the trace guarantees its `selector` field contains no whitespace at all so
    /// downstream consumers can tokenize a step line without quoting rules.
    public static func isSafeAttributeValue(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= maxValueLength else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            guard scalar.value >= 0x20, scalar.value != 0x7F else { return false }
            switch scalar {
            case "\"", "'", "\\", "`": return false
            default: return !Character(scalar).isWhitespace
            }
        }
    }

    // MARK: Links and roles

    /// A link destination that identifies the link on THIS site: a path from the site root, no
    /// scheme, no host (`//cdn…` is a host), no query string, no fragment, and safe to quote.
    /// `/` alone is the home link and passes; it is as literal as any other destination.
    public static func isRelativePathHref(_ href: String) -> Bool {
        guard isSafeAttributeValue(href), href.hasPrefix("/"), !href.hasPrefix("//") else { return false }
        return !href.contains("?") && !href.contains("#")
    }

    /// The ARIA roles a person clicks, types into or picks from. Landmarks and structure
    /// (`navigation`, `list`, `presentation`) are not handles for a step and are left out.
    public static let interactiveRoles: Set<String> = [
        "button", "link", "menuitem", "menuitemcheckbox", "menuitemradio", "tab", "option",
        "radio", "checkbox", "switch", "combobox", "textbox", "searchbox", "listbox", "slider",
        "spinbutton", "treeitem",
    ]

    // MARK: Classes

    /// The class tokens worth putting in a selector: whitespace-split, each a plain
    /// CSS identifier, each NOT build-hash-looking, capped at ``maxClassTokens`` in
    /// document order (deterministic across runs).
    public static func stableClassTokens(_ classAttribute: String?) -> [String] {
        guard let classAttribute else { return [] }
        let tokens = classAttribute.split(whereSeparator: \.isWhitespace).map(String.init)
        return Array(tokens.filter { isValidCSSIdentifier($0) && !looksHashed($0) }.prefix(maxClassTokens))
    }

    /// Prefixes that mark a build-generated class: emotion / styled-components /
    /// styled-jsx all mint a fresh hash on every build, so the class is worthless as
    /// a durable handle even though it is a perfectly valid identifier.
    static let hashedClassPrefixes = ["css-", "sc-", "jsx-", "emotion-", "styled-"]

    // MARK: Generated ids

    /// Does this id look like a GENERATOR wrote it, rather than a person?
    ///
    /// The shapes, each measured on a live page whose controls carry a fresh id per render:
    ///
    ///   * the hashed shape ``looksHashed`` already refuses in class tokens — a run of five or
    ///     more characters mixing letters and digits (Magento's `VL8WV5X`, `JV2FMF8`, `CD26XAH`);
    ///   * SCREAMING CAPS with no separator (`XODHUST`). A person writing an identifier writes
    ///     it lowercase or camelCase and usually separates its words; an unbroken run of five
    ///     or more capitals is what a generator emits;
    ///   * React 19's `useId` (`_r_i_`, `_r_1d_`, `_R_vclld65_`, and the `«r1»` spelling of 19.1):
    ///     a one-letter body wrapped in underscores or guillemets. React 18 wrote `:r1:`, which
    ///     ``isValidCSSIdentifier`` already refuses for the colon. MEASURED on github.com/search
    ///     (github-ss r5, 2026-09-22): the sort button's `#_r_i_` beat its own
    ///     `data-testid="sort-button"` to the receipt;
    ///   * a component library's counter: `radix-`, `headlessui-`, `mui-`, `downshift-`,
    ///     `react-select-`, `react-aria`, `ember` prefixes, each renumbered on remount;
    ///   * a SHORT COUNTER: one to three letters and a number, `ucj-3`, `c12`, `j_5` -- what an id
    ///     generator hands out in sequence (translate.google.com's "Text translation" heading was
    ///     `#ucj-3`, gtranslate-fr-r60). A person names things with words.
    ///
    /// It is a judgement about the CHARACTERS, not about the site, and it errs toward refusing:
    /// a real id spelled that way loses its rung and the element is addressed by its name,
    /// test hook, class or position instead — all of which outlive a render, which is the only
    /// property being asked for here.
    public static func looksGenerated(_ id: String) -> Bool {
        if looksHashed(id) { return true }
        if isReactUseId(id) { return true }
        let lower = id.lowercased()
        if generatedIdPrefixes.contains(where: { lower.hasPrefix($0) }) { return true }
        if id.range(of: #"^[A-Za-z]{1,3}[-_]?[0-9]{1,4}$"#, options: .regularExpression) != nil { return true }
        let separated = id.contains("-") || id.contains("_")
        let letters = id.filter { $0.isLetter }
        return !separated && letters.count >= 5 && letters.allSatisfy { $0.isUppercase }
    }

    /// Prefixes component libraries put on the ids they number per render.
    static let generatedIdPrefixes = ["radix-", "headlessui-", "mui-", "downshift-", "react-select-", "react-aria", "ember"]

    /// `_r_1d_`, `_R_vclld65_`, `«r1»`: React 19's `useId`, possibly followed by a suffix the
    /// component appended (`_r_1d_--label`). The body is letters and digits only.
    public static func isReactUseId(_ id: String) -> Bool {
        if id.contains("«") || id.contains("»") { return true }
        guard id.count >= 4 else { return false }
        let chars = Array(id)
        guard chars[0] == "_", chars[1] == "r" || chars[1] == "R", chars[2] == "_" else { return false }
        var i = 3
        while i < chars.count, chars[i].isLetter || chars[i].isNumber { i += 1 }
        return i > 3 && i < chars.count && chars[i] == "_"
    }

    /// Whether a class token looks BUILD-GENERATED rather than authored. Three signals:
    /// a known CSS-in-JS prefix; a CSS-modules hash after `___` (letters only count, since
    /// github.com's `Primer_Brand__Button-module__Button--size-small___zQrEw` has no digit and
    /// was `___scH9Z` a day later); or a hash-shaped segment (letters+digits mixed in a 5+
    /// character run, a 5+ digit run, or a 4+ character run mixing BOTH letter cases with a
    /// digit, as Primer's `…-KBb8-` does). Deliberately tolerant of authored tokens that merely
    /// contain digits (`col-md-6`, `mt-4`, `h2-heading`, `icon-16px`), which are one case and
    /// stable.
    public static func looksHashed(_ token: String) -> Bool {
        let lower = token.lowercased()
        if hashedClassPrefixes.contains(where: { lower.hasPrefix($0) }) { return true }
        if let range = token.range(of: "___", options: .backwards) {
            let hash = token[range.upperBound...]
            if (4...10).contains(hash.count), hash.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) { return true }
        }
        return token.split(whereSeparator: { $0 == "-" || $0 == "_" }).contains { segment in
            let digits = segment.count(where: \.isNumber)
            let letters = segment.count(where: \.isLetter)
            if segment.count >= 5 && digits > 0 && letters > 0 { return true }
            if segment.count >= 5 && letters == 0 && digits == segment.count { return true }
            return segment.count >= 4 && digits > 0
                && segment.contains(where: \.isUppercase) && segment.contains(where: \.isLowercase)
        }
    }
}
