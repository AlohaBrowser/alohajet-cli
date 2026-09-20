import Foundation

// MARK: - Dynamic JSON value

/// A dynamic JSON value used as the boundary type wherever the library exchanges
/// untyped, schema-less JSON: CDP command params/results and tool arguments.
///
/// Key design decisions:
/// - `.object` stores its members as an ORDERED array of key/value pairs so
///   insertion order is preserved. A `Dictionary` would lose this, and a
///   deterministic key order is required for a stable serialized byte stream.
/// - `.undefined` is modeled as a distinct case (NOT folded into `.null`) so a
///   value can be omitted from serialized output (objects drop it, arrays lower
///   it to `null`), matching the JSON-with-holes shape callers expect.
public nonisolated enum JSValue: Equatable, Sendable {
    case null
    case undefined
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSValue])
    /// Members in insertion order. Duplicate keys are allowed by the type; the
    /// LAST assignment for a key wins on lookup.
    case object([(String, JSValue)])

    // MARK: Equatable (structural)
    //
    // Hand-rolled because the associated values (tuple arrays, and `Double` with
    // its NaN quirk) are not auto-`Equatable`.
    public static func == (lhs: JSValue, rhs: JSValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null):
            return true
        case (.undefined, .undefined):
            return true
        case let (.bool(a), .bool(b)):
            return a == b
        case let (.number(a), .number(b)):
            // Treat two NaNs as equal and -0/+0 as equal so round-trip/value
            // assertions are stable.
            if a.isNaN && b.isNaN { return true }
            return a == b
        case let (.string(a), .string(b)):
            return a == b
        case let (.array(a), .array(b)):
            return a == b
        case let (.object(a), .object(b)):
            guard a.count == b.count else { return false }
            for (lhs, rhs) in zip(a, b) {
                if lhs.0 != rhs.0 { return false }
                if lhs.1 != rhs.1 { return false }
            }
            return true
        default:
            return false
        }
    }
}

// MARK: - Literal conveniences
//
// A dictionary literal preserves its written order, which becomes the object's
// insertion order.

nonisolated extension JSValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

nonisolated extension JSValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

nonisolated extension JSValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
}

nonisolated extension JSValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .number(value) }
}

nonisolated extension JSValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

nonisolated extension JSValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSValue...) { self = .array(elements) }
}

nonisolated extension JSValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSValue)...) {
        self = .object(elements.map { ($0.0, $0.1) })
    }
}

// MARK: - Subscripts & typed getters

public nonisolated extension JSValue {
    /// Object member access. Returns `nil` for non-objects and for missing keys.
    /// When duplicate keys exist, the LAST one wins.
    subscript(key: String) -> JSValue? {
        guard case let .object(members) = self else { return nil }
        return members.last { $0.0 == key }?.1
    }

    /// Array element access. Returns `nil` for non-arrays and out-of-range
    /// (including negative) indices.
    subscript(index: Int) -> JSValue? {
        guard case let .array(elements) = self, elements.indices.contains(index) else { return nil }
        return elements[index]
    }

    func string(_ key: String) -> String? { self[key]?.stringValue }

    func number(_ key: String) -> Double? { self[key]?.doubleValue }

    func bool(_ key: String) -> Bool? { self[key]?.boolValue }

    func object(_ key: String) -> [(String, JSValue)]? { self[key]?.objectValue }

    func array(_ key: String) -> [JSValue]? { self[key]?.arrayValue }
}

// MARK: - Direct value accessors

public nonisolated extension JSValue {
    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// The value as an `Int`, if this is a `.number` with an integral value that FITS.
    ///
    /// `Int(_:)` traps on a `Double` outside `Int`'s range, and `1e300` is a legal JSON
    /// number — reachable from a tool argument and from anything a page returns over CDP.
    /// A value that does not fit is not an `Int`, so it reads as absent like any other
    /// non-integer. (`NaN` is already excluded: it is not equal to its own `rounded()`.)
    var intValue: Int? {
        if case .number(let value) = self, value == value.rounded() {
            return Int(exactly: value)
        }
        return nil
    }

    var doubleValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var objectValue: [(String, JSValue)]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var arrayValue: [JSValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    static func number(_ value: Int) -> JSValue {
        .number(Double(value))
    }
}

// MARK: - Foundation bridging (JSONSerialization wire format)

public nonisolated extension JSValue {
    /// Bridges to a Foundation JSON object suitable for `JSONSerialization`.
    ///
    /// Object key order is preserved on the way out by emitting an
    /// `NSMutableDictionary` (whose enumeration order follows insertion);
    /// `JSONSerialization` itself does not guarantee key order, so callers that
    /// require a deterministic byte stream should use `stringify()` instead.
    /// `.undefined` has no Foundation/JSON representation, so it bridges to
    /// `NSNull`.
    var anyValue: Any {
        switch self {
        case .null, .undefined:
            return NSNull()
        case .bool(let value):
            return value
        case .number(let value):
            return value
        case .string(let value):
            return value
        case .array(let values):
            return values.map { $0.anyValue }
        case .object(let members):
            let result = NSMutableDictionary()
            for (key, value) in members { result[key] = value.anyValue }
            return result
        }
    }

    /// Builds a `JSValue` from a `JSONSerialization`-style Foundation object.
    ///
    /// Note: a Foundation dictionary is unordered, so object key order from such
    /// a source is not meaningful; for order-preserving parsing of a JSON string
    /// use `JSValue.parse(_:)`.
    init(foundation object: Any) {
        switch object {
        case is NSNull:
            self = .null
        case let n as NSNumber:
            // In Foundation, `true`/`false` are `NSNumber` wrapping a
            // `CFBoolean`; distinguish them from numeric values.
            #if canImport(Darwin)
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                self = .bool(n.boolValue)
            } else {
                self = .number(n.doubleValue)
            }
            #else
            // swift-corelibs-foundation does not expose CFBooleanGetTypeID. A
            // Bool-backed NSNumber reports an objCType of "c" (as on Apple),
            // which distinguishes it from numeric NSNumbers (e.g. "q"/"d").
            if n.objCType.pointee == CChar(99) /* 'c' */ {
                self = .bool(n.boolValue)
            } else {
                self = .number(n.doubleValue)
            }
            #endif
        case let b as Bool:
            self = .bool(b)
        case let s as String:
            self = .string(s)
        case let arr as [Any]:
            self = .array(arr.map { JSValue(foundation: $0) })
        case let dict as [String: Any]:
            self = .object(dict.map { ($0.key, JSValue(foundation: $0.value)) })
        default:
            self = .null
        }
    }

    /// Parses a JSON-encoded string into a `JSValue`, PRESERVING object key
    /// order. Returns `.null` for an empty or `undefined` payload (e.g. a snippet
    /// with no return value).
    static func parse(jsonString: String) -> JSValue {
        let trimmed = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "undefined" else { return .null }
        return parse(trimmed) ?? .null
    }
}

// MARK: - JSON serialization (order-preserving)

public nonisolated extension JSValue {
    /// Parse a JSON string into a `JSValue`, PRESERVING object key order.
    ///
    /// We deliberately do NOT use `JSONSerialization`/`JSONDecoder`: both lower
    /// objects into an unordered `NSDictionary`/`Dictionary`, which destroys
    /// insertion order. This is a tiny, self-contained recursive-descent parser
    /// that records members in document order.
    static func parse(_ json: String) -> JSValue? {
        var parser = JSONParser(Array(json.unicodeScalars))
        guard let value = parser.parseValue() else { return nil }
        parser.skipWhitespace()
        guard parser.isAtEnd else { return nil }
        return value
    }

    /// Serialize to a compact JSON string (no insignificant whitespace),
    /// preserving object key order.
    func stringify() -> String {
        var out = ""
        Self.write(self, pretty: nil, indent: 0, into: &out)
        return out
    }

    /// Serialize to a pretty-printed JSON string with a two-space indent (or a
    /// caller-chosen `indent`): `": "` between key and value, `",\n"` between
    /// members, and `{}`/`[]` for empty containers.
    ///
    /// `.undefined` is omitted: a `.undefined` array element serializes to
    /// `null`, a `.undefined` object value drops the whole member, and a
    /// top-level `.undefined` produces an empty string.
    func prettyStringified(indent: Int = 2) -> String {
        if case .undefined = self { return "" }
        var out = ""
        Self.write(self, pretty: indent, indent: 0, into: &out)
        return out
    }

    private static func write(
        _ value: JSValue,
        pretty: Int?,
        indent depth: Int,
        into out: inout String
    ) {
        switch value {
        case .null, .undefined:
            // `.undefined` only reaches here as an array element (objects omit
            // it; top-level is handled by the caller). It lowers to `null`.
            out += "null"
        case let .bool(b):
            out += b ? "true" : "false"
        case let .number(n):
            out += formatJSONNumber(n)
        case let .string(s):
            out += encodeString(s)
        case let .array(elements):
            writeArray(elements, pretty: pretty, depth: depth, into: &out)
        case let .object(members):
            writeObject(members, pretty: pretty, depth: depth, into: &out)
        }
    }

    private static func writeArray(
        _ elements: [JSValue],
        pretty: Int?,
        depth: Int,
        into out: inout String
    ) {
        if elements.isEmpty {
            out += "[]"
            return
        }
        out += "["
        let inner = depth + 1
        for (i, el) in elements.enumerated() {
            if i > 0 { out += "," }
            newlineAndPad(pretty: pretty, depth: inner, into: &out)
            write(el, pretty: pretty, indent: inner, into: &out)
        }
        newlineAndPad(pretty: pretty, depth: depth, into: &out)
        out += "]"
    }

    private static func writeObject(
        _ members: [(String, JSValue)],
        pretty: Int?,
        depth: Int,
        into out: inout String
    ) {
        let kept = members.filter { $0.1 != .undefined }
        if kept.isEmpty {
            out += "{}"
            return
        }
        out += "{"
        let inner = depth + 1
        for (i, member) in kept.enumerated() {
            if i > 0 { out += "," }
            newlineAndPad(pretty: pretty, depth: inner, into: &out)
            out += encodeString(member.0)
            out += pretty == nil ? ":" : ": "
            write(member.1, pretty: pretty, indent: inner, into: &out)
        }
        newlineAndPad(pretty: pretty, depth: depth, into: &out)
        out += "}"
    }

    private static func newlineAndPad(pretty: Int?, depth: Int, into out: inout String) {
        guard let width = pretty else { return }
        out += "\n"
        out += String(repeating: " ", count: width * depth)
    }

    private static func encodeString(_ s: String) -> String {
        var result = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\u{08}": result += "\\b"
            case "\u{09}": result += "\\t"
            case "\u{0A}": result += "\\n"
            case "\u{0C}": result += "\\f"
            case "\u{0D}": result += "\\r"
            default:
                if scalar.value < 0x20 {
                    result += String(format: "\\u%04x", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        result += "\""
        return result
    }
}

// MARK: - JSON number formatting

/// Format a `Double` for JSON output: the shortest round-trippable decimal for
/// finite values, and `null` for non-finite values (JSON has no representation
/// for NaN / ±Infinity).
///
/// The placement rules (when to use plain decimal vs. exponential form) follow
/// the standard shortest-decimal conventions. Swift's `Double.description`
/// already produces the shortest round-trippable digit string (the hard part);
/// this only re-places the decimal point / chooses exponential form.
nonisolated func formatJSONNumber(_ value: Double) -> String {
    if value.isNaN || value.isInfinite {
        return "null"
    }
    if value == 0 {
        // Covers both +0 and -0.
        return "0"
    }

    let negative = value < 0
    let magnitude = abs(value)

    let (digits, n) = significandAndExponent(of: magnitude)
    let k = digits.count

    var body: String
    if k <= n && n <= 21 {
        body = digits + String(repeating: "0", count: n - k)
    } else if 0 < n && n <= 21 {
        let idx = digits.index(digits.startIndex, offsetBy: n)
        body = String(digits[..<idx]) + "." + String(digits[idx...])
    } else if -6 < n && n <= 0 {
        body = "0." + String(repeating: "0", count: -n) + digits
    } else {
        let exp = n - 1
        let mantissa: String
        if k == 1 {
            mantissa = digits
        } else {
            let second = digits.index(after: digits.startIndex)
            mantissa = String(digits[..<second]) + "." + String(digits[second...])
        }
        let sign = exp >= 0 ? "+" : "-"
        body = mantissa + "e" + sign + String(abs(exp))
    }

    return negative ? "-" + body : body
}

/// Extract the shortest significant-digit string `s` (no leading or trailing
/// zeros) and `n` (number of digits before the decimal point) from a finite,
/// positive `Double`, using `Double.description` as the source of the shortest
/// round-trippable digits.
nonisolated private func significandAndExponent(of magnitude: Double) -> (digits: String, n: Int) {
    let desc = magnitude.description
    let lower = desc.lowercased()

    var mantissaPart = lower
    var exp10 = 0
    if let eIndex = lower.firstIndex(of: "e") {
        mantissaPart = String(lower[..<eIndex])
        let expString = String(lower[lower.index(after: eIndex)...])
        exp10 = Int(expString) ?? 0
    }

    var intPart = mantissaPart
    var fracPart = ""
    if let dot = mantissaPart.firstIndex(of: ".") {
        intPart = String(mantissaPart[..<dot])
        fracPart = String(mantissaPart[mantissaPart.index(after: dot)...])
    }

    let combined = intPart + fracPart
    var pointPos = intPart.count + exp10

    // Each removed LEADING zero shifts the point left; trailing zeros do not affect it.
    var digits = combined.drop { $0 == "0" }
    pointPos -= combined.count - digits.count
    while digits.last == "0" {
        digits = digits.dropLast()
    }

    if digits.isEmpty {
        return ("0", 1)
    }
    return (String(digits), pointPos)
}

// MARK: - Order-preserving JSON parser

/// A minimal, dependency-free recursive-descent JSON parser whose only job is to
/// record object members in DOCUMENT ORDER (which `JSONSerialization` discards).
/// It accepts standard JSON; on any malformed input the relevant `parse*`
/// returns `nil` and the top-level `JSValue.parse` reports failure.
nonisolated private struct JSONParser {
    private let scalars: [Unicode.Scalar]
    private var index: Int = 0

    init(_ scalars: [Unicode.Scalar]) {
        self.scalars = scalars
    }

    var isAtEnd: Bool { index >= scalars.count }

    private func peek() -> Unicode.Scalar? {
        index < scalars.count ? scalars[index] : nil
    }

    mutating func skipWhitespace() {
        while let c = peek(), c == " " || c == "\t" || c == "\n" || c == "\r" {
            index += 1
        }
    }

    mutating func parseValue() -> JSValue? {
        skipWhitespace()
        guard let c = peek() else { return nil }
        switch c {
        case "{": return parseObject()
        case "[": return parseArray()
        case "\"":
            guard let s = parseString() else { return nil }
            return .string(s)
        case "t", "f": return parseBool()
        case "n": return parseNull()
        default: return parseNumber()
        }
    }

    private mutating func expect(_ scalar: Unicode.Scalar) -> Bool {
        guard peek() == scalar else { return false }
        index += 1
        return true
    }

    private mutating func parseObject() -> JSValue? {
        guard expect("{") else { return nil }
        var members: [(String, JSValue)] = []
        skipWhitespace()
        if peek() == "}" { index += 1; return .object(members) }
        while true {
            skipWhitespace()
            guard peek() == "\"", let key = parseString() else { return nil }
            skipWhitespace()
            guard expect(":") else { return nil }
            guard let value = parseValue() else { return nil }
            members.append((key, value))
            skipWhitespace()
            if expect(",") { continue }
            if expect("}") { return .object(members) }
            return nil
        }
    }

    private mutating func parseArray() -> JSValue? {
        guard expect("[") else { return nil }
        var elements: [JSValue] = []
        skipWhitespace()
        if peek() == "]" { index += 1; return .array(elements) }
        while true {
            guard let value = parseValue() else { return nil }
            elements.append(value)
            skipWhitespace()
            if expect(",") { continue }
            if expect("]") { return .array(elements) }
            return nil
        }
    }

    private mutating func parseString() -> String? {
        guard expect("\"") else { return nil }
        var result = String.UnicodeScalarView()
        while let c = peek() {
            index += 1
            if c == "\"" {
                return String(result)
            }
            if c == "\\" {
                guard let esc = peek() else { return nil }
                index += 1
                switch esc {
                case "\"": result.append("\"")
                case "\\": result.append("\\")
                case "/": result.append("/")
                case "b": result.append("\u{08}")
                case "f": result.append("\u{0C}")
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "t": result.append("\t")
                case "u":
                    guard let scalar = parseUnicodeEscape() else { return nil }
                    result.append(scalar)
                default:
                    return nil
                }
            } else {
                result.append(c)
            }
        }
        return nil  // unterminated
    }

    private mutating func parseUnicodeEscape() -> Unicode.Scalar? {
        guard let high = parseHex4() else { return nil }
        if high >= 0xD800 && high <= 0xDBFF {
            guard expect("\\"), expect("u"), let low = parseHex4(),
                  low >= 0xDC00 && low <= 0xDFFF else { return nil }
            let combined = 0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00)
            return Unicode.Scalar(combined)
        }
        if high >= 0xDC00 && high <= 0xDFFF {
            return nil  // lone low surrogate
        }
        return Unicode.Scalar(high)
    }

    private mutating func parseHex4() -> Int? {
        var value = 0
        for _ in 0..<4 {
            guard let c = peek(), let digit = hexDigit(c) else { return nil }
            value = value * 16 + digit
            index += 1
        }
        return value
    }

    private func hexDigit(_ c: Unicode.Scalar) -> Int? {
        switch c {
        case "0"..."9": return Int(c.value - 48)
        case "a"..."f": return Int(c.value - 97 + 10)
        case "A"..."F": return Int(c.value - 65 + 10)
        default: return nil
        }
    }

    private mutating func parseBool() -> JSValue? {
        if matchLiteral("true") { return .bool(true) }
        if matchLiteral("false") { return .bool(false) }
        return nil
    }

    private mutating func parseNull() -> JSValue? {
        matchLiteral("null") ? .null : nil
    }

    private mutating func matchLiteral(_ literal: String) -> Bool {
        let lit = Array(literal.unicodeScalars)
        guard index + lit.count <= scalars.count,
              scalars[index..<(index + lit.count)].elementsEqual(lit)
        else { return false }
        index += lit.count
        return true
    }

    private mutating func parseNumber() -> JSValue? {
        let start = index
        if peek() == "-" { index += 1 }
        while let c = peek(),
              (c >= "0" && c <= "9") || c == "." || c == "e" || c == "E"
                || c == "+" || c == "-" {
            index += 1
        }
        guard start < index else { return nil }
        let text = String(String.UnicodeScalarView(scalars[start..<index]))
        guard let d = Double(text) else { return nil }
        return .number(d)
    }
}
