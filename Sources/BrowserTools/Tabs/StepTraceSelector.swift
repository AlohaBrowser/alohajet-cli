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
/// 1. `#id` — when `id` is a valid CSS identifier.
/// 2. `[data-testid="…"]`, then `[data-test="…"]` — put there on purpose by the
///    site's own authors, precisely so automation can find the element.
/// 3. `[name="…"]` — form-field identity, part of the site's wire contract.
/// 4. `input[type="…"]` — weak but real for form controls.
/// 5. `tag.classA.classB` — only STABLE-LOOKING classes; build-time hashed classes
///    (`css-1x2y3z`, `sc-AbCdEf`, `Button_root__2xY3z`) are refused because they
///    change on every build of the site.
///
/// Nothing matched → `nil`. In particular the `aloha-id` attribute is never used
/// — it is stable but not re-resolvable off the page — and a bare tag selector is
/// never emitted.
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

        // 1. #id
        if let id = attributes["id"], isValidCSSIdentifier(id) {
            return "#" + id
        }
        // 2. explicit test hooks
        for key in ["data-testid", "data-test"] {
            if let value = attributes[key], isSafeAttributeValue(value) {
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
        // 5. tag + stable classes
        if let tag {
            let classes = stableClassTokens(attributes["class"])
            if !classes.isEmpty {
                return ([tag] + classes).joined(separator: ".")
            }
        }
        return nil
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
        for scalar in value.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7F { return false }
            switch scalar {
            case "\"", "'", "\\", "`": return false
            default: break
            }
            if Character(scalar).isWhitespace { return false }
        }
        return true
    }

    // MARK: Classes

    /// The class tokens worth putting in a selector: whitespace-split, each a plain
    /// CSS identifier, each NOT build-hash-looking, capped at ``maxClassTokens`` in
    /// document order (deterministic across runs).
    public static func stableClassTokens(_ classAttribute: String?) -> [String] {
        guard let classAttribute else { return [] }
        let tokens = classAttribute.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return tokens
            .filter { isValidCSSIdentifier($0) && !looksHashed($0) }
            .prefix(maxClassTokens)
            .map { $0 }
    }

    /// Prefixes that mark a build-generated class: emotion / styled-components /
    /// styled-jsx all mint a fresh hash on every build, so the class is worthless as
    /// a durable handle even though it is a perfectly valid identifier.
    static let hashedClassPrefixes = ["css-", "sc-", "jsx-", "emotion-", "styled-"]

    /// Whether a class token looks BUILD-GENERATED rather than authored. Two signals:
    /// a known CSS-in-JS prefix, or a hash-shaped segment (letters+digits mixed in a
    /// 5+ character run, or a 5+ digit run) as CSS-modules emit
    /// (`Button_root__2xY3z`). Deliberately tolerant of authored tokens that merely
    /// contain digits (`col-md-6`, `mt-4`, `h2-heading`), which are stable.
    public static func looksHashed(_ token: String) -> Bool {
        let lower = token.lowercased()
        if hashedClassPrefixes.contains(where: { lower.hasPrefix($0) }) { return true }
        let segments = token.split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init)
        for segment in segments {
            let digits = segment.filter { $0.isNumber }.count
            let letters = segment.filter { $0.isLetter }.count
            if segment.count >= 5 && digits > 0 && letters > 0 { return true }
            if segment.count >= 5 && letters == 0 && digits == segment.count { return true }
        }
        return false
    }
}
