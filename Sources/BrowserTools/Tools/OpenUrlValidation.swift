import Foundation

// Every navigation entry point in this package goes through `validateOpenUrl`
// before a URL reaches `Page.navigate`. It is the only thing standing between a
// caller — including a model that just read a hostile page — and `file:///`,
// which a real tab (as opposed to a fresh `about:blank`) will happily load and
// hand back through `get_text`.

public let MAX_URL_LENGTH = 8192

public let CONTROL_CHAR_RE = "[\\x00-\\x1f\\x7f]"

public let URL_FILE_PROTOCOL_REASON = "URL not allowed: file:// cannot be opened by browser tools. These tools drive a browser over CDP; they are not a local file reader."

public func urlBadProtocolReason(_ proto: String) -> String {
    "URL not allowed: only http and https URLs can be opened via browser tools (got \(proto))."
}

public let URL_CREDENTIALS_REASON = "URL not allowed: URLs containing 'user:password@' are rejected."

public let URL_MALFORMED_REASON = "URL not allowed: malformed or oversized URL."

public enum OpenUrlValidation: Equatable, Sendable {
    case ok(normalized: String)
    case rejected(reason: String)
}

/// Validates a URL for opening via browser tools: rejects empty, oversized,
/// control-character-bearing, malformed, non-http(s), and credential-bearing
/// URLs; returns the normalized href otherwise.
public func validateOpenUrl(_ value: String?) -> OpenUrlValidation {
    guard let value else {
        return .rejected(reason: URL_MALFORMED_REASON)
    }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
        return .rejected(reason: URL_MALFORMED_REASON)
    }
    if trimmed.count > MAX_URL_LENGTH {
        return .rejected(reason: URL_MALFORMED_REASON)
    }
    if urlRegexTest(trimmed, pattern: CONTROL_CHAR_RE) {
        return .rejected(reason: URL_MALFORMED_REASON)
    }
    guard let parsed = ParsedWebUrl(trimmed) else {
        return .rejected(reason: URL_MALFORMED_REASON)
    }
    let proto = parsed.protocolScheme
    if proto != "http:" && proto != "https:" {
        if proto == "file:" {
            return .rejected(reason: URL_FILE_PROTOCOL_REASON)
        }
        return .rejected(reason: urlBadProtocolReason(proto))
    }
    if !parsed.username.isEmpty || !parsed.password.isEmpty {
        return .rejected(reason: URL_CREDENTIALS_REASON)
    }
    return .ok(normalized: parsed.href)
}

public func validateTabUrl(_ tab: TabUrlInput) -> OpenUrlValidation {
    validateOpenUrl(tab.url)
}

public struct TabUrlInput: Equatable, Sendable {
    public var url: String?
    public init(url: String?) {
        self.url = url
    }
}

private func urlRegexTest(_ text: String, pattern: String) -> Bool {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return regex.firstMatch(in: text, range: range) != nil
}

/// A minimal absolute-URL parse for validation only — not a general-purpose URL parser.
struct ParsedWebUrl {
    var protocolScheme: String
    var username: String
    var password: String
    var href: String

    init?(_ raw: String) {
        guard let components = URLComponents(string: raw), let scheme = components.scheme, !scheme.isEmpty else {
            return nil
        }
        // A bare scheme such as `http:foo` with no `//` is not a valid absolute
        // browser URL; require an authority for hierarchical schemes.
        guard raw.range(of: "://") != nil || components.host != nil else {
            return nil
        }
        self.protocolScheme = "\(scheme.lowercased()):"
        self.username = components.user ?? ""
        self.password = components.password ?? ""
        self.href = components.string ?? raw
    }
}
