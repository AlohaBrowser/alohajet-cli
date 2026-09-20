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

private func groupedDecimal(_ value: Int) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.groupingSeparator = ","
    formatter.locale = Locale(identifier: "en_US")
    return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
}

public func formatTokenCount(_ value: Double) -> String {
    groupedDecimal(Int(ceil(value)))
}

public func formatCompactTokenCount(_ value: Int) -> String {
    guard value >= 1000 else { return groupedDecimal(value) }
    let thousands = Double(value) / 1000.0
    if thousands.truncatingRemainder(dividingBy: 1) == 0 {
        return "\(Int(thousands))k"
    }
    return "\(String(format: "%.1f", thousands))k"
}

// MARK: - String utilities

public func stripLoneSurrogates(_ raw: String?) -> String {
    guard let raw, !raw.isEmpty else { return "" }
    let highSurrogates: ClosedRange<UInt32> = 0xD800...0xDBFF
    let lowSurrogates: ClosedRange<UInt32> = 0xDC00...0xDFFF
    let scalars = Array(raw.unicodeScalars)
    var result = String.UnicodeScalarView()
    for (index, scalar) in scalars.enumerated() {
        let paired: Bool
        if highSurrogates.contains(scalar.value) {
            paired = scalars.indices.contains(index + 1) && lowSurrogates.contains(scalars[index + 1].value)
        } else if lowSurrogates.contains(scalar.value) {
            paired = scalars.indices.contains(index - 1) && highSurrogates.contains(scalars[index - 1].value)
        } else {
            paired = true
        }
        if paired { result.append(scalar) }
    }
    return String(result)
}

public func escapeRegExp(_ raw: String) -> String {
    let special: Set<Character> = [".", "*", "+", "?", "^", "$", "{", "}", "(", ")", "|", "[", "]", "\\"]
    return raw.map { special.contains($0) ? "\\\($0)" : String($0) }.joined()
}

// MARK: - Regex helpers

func regexMatches(_ text: String, _ pattern: String, caseInsensitive: Bool = false) -> [String] {
    let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
    guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
    let ns = text as NSString
    let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
    return matches.map { ns.substring(with: $0.range) }
}

func regexFirstGroup(_ text: String, _ pattern: String, caseInsensitive: Bool = false) -> String? {
    let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
    guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
    let ns = text as NSString
    guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)), match.numberOfRanges > 1 else { return nil }
    let range = match.range(at: 1)
    guard range.location != NSNotFound else { return nil }
    return ns.substring(with: range)
}

func fullMatch(_ text: String, _ pattern: String, caseInsensitive: Bool = false) -> Bool {
    let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
    guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return false }
    let ns = text as NSString
    guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return false }
    return match.range.location == 0 && match.range.length == ns.length
}

func containsMatch(_ text: String, _ pattern: String, caseInsensitive: Bool = false) -> Bool {
    let options: String.CompareOptions = caseInsensitive ? [.regularExpression, .caseInsensitive] : [.regularExpression]
    return text.range(of: pattern, options: options) != nil
}

