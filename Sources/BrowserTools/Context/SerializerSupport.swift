import Foundation

// MARK: - Token estimation

func replacingFirstUnderscoreWithSpace(_ value: String) -> String {
    guard let range = value.range(of: "_") else { return value }
    return value.replacingCharacters(in: range, with: " ")
}

public func estimateTokenCount(_ text: String?) -> Int {
    guard let text, !text.isEmpty else { return 0 }
    return Int(ceil(Double(text.count) / 4.0))
}

public func formatTokenCount(_ value: Double) -> String {
    let n = Int(ceil(value))
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.groupingSeparator = ","
    formatter.locale = Locale(identifier: "en_US")
    return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
}

public func formatCompactTokenCount(_ value: Int) -> String {
    if value >= 1000 {
        let e = Double(value) / 1000.0
        if e.truncatingRemainder(dividingBy: 1) == 0 {
            return "\(Int(e))k"
        }
        return "\(String(format: "%.1f", e))k"
    }
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.groupingSeparator = ","
    formatter.locale = Locale(identifier: "en_US")
    return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
}

// MARK: - String utilities

public func stripLoneSurrogates(_ raw: String?) -> String {
    guard let raw, !raw.isEmpty else { return "" }
    var result = String.UnicodeScalarView()
    let scalars = Array(raw.unicodeScalars)
    for i in 0..<scalars.count {
        let scalar = scalars[i]
        if scalar.value >= 0xD800 && scalar.value <= 0xDBFF {
            let next = i + 1 < scalars.count ? scalars[i + 1] : nil
            if let next, next.value >= 0xDC00 && next.value <= 0xDFFF {
                result.append(scalar)
            }
            continue
        }
        if scalar.value >= 0xDC00 && scalar.value <= 0xDFFF {
            let prev = i > 0 ? scalars[i - 1] : nil
            if let prev, prev.value >= 0xD800 && prev.value <= 0xDBFF {
                result.append(scalar)
            }
            continue
        }
        result.append(scalar)
    }
    return String(result)
}

public func escapeRegExp(_ raw: String) -> String {
    let special: Set<Character> = [".", "*", "+", "?", "^", "$", "{", "}", "(", ")", "|", "[", "]", "\\"]
    var result = ""
    for ch in raw {
        if special.contains(ch) { result.append("\\") }
        result.append(ch)
    }
    return result
}

// MARK: - Regex helpers

func regexMatches(_ text: String, _ pattern: String, caseInsensitive: Bool = false) -> [String] {
    var options: NSRegularExpression.Options = []
    if caseInsensitive { options.insert(.caseInsensitive) }
    guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
    let ns = text as NSString
    let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
    return matches.map { ns.substring(with: $0.range) }
}

func regexFirstGroup(_ text: String, _ pattern: String, caseInsensitive: Bool = false) -> String? {
    var options: NSRegularExpression.Options = []
    if caseInsensitive { options.insert(.caseInsensitive) }
    guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
    let ns = text as NSString
    guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)), match.numberOfRanges > 1 else { return nil }
    let range = match.range(at: 1)
    if range.location == NSNotFound { return nil }
    return ns.substring(with: range)
}

func fullMatch(_ text: String, _ pattern: String, caseInsensitive: Bool = false) -> Bool {
    var options: NSRegularExpression.Options = []
    if caseInsensitive { options.insert(.caseInsensitive) }
    guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return false }
    let ns = text as NSString
    guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return false }
    return match.range.location == 0 && match.range.length == ns.length
}

func containsMatch(_ text: String, _ pattern: String, caseInsensitive: Bool = false) -> Bool {
    var options: NSRegularExpression.Options = []
    if caseInsensitive { options.insert(.caseInsensitive) }
    return text.range(of: pattern, options: caseInsensitive ? [.regularExpression, .caseInsensitive] : [.regularExpression]) != nil
}

