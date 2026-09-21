import Foundation

// MARK: - Data URL image parsing

public struct ParsedDataUrlImage: Equatable, Sendable {
    public let base64: String
    public let mediaType: String
    public init(base64: String, mediaType: String) {
        self.base64 = base64
        self.mediaType = mediaType
    }
}

/// Parses a `data:<mime>;base64,<payload>` URL. JPEG/JPG map to `image/jpeg`,
/// PNG maps to `image/png`, and any other recognized base64 data url defaults to
/// `image/jpeg`. Returns `nil` when the string is not a base64 data url.
public func parseDataUrlImage(_ value: String) -> ParsedDataUrlImage? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let pattern = "^data:([^;]+);base64,(.+)$"
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return nil }
    let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
    guard let match = regex.firstMatch(in: trimmed, options: [], range: range),
          let mimeRange = Range(match.range(at: 1), in: trimmed),
          let dataRange = Range(match.range(at: 2), in: trimmed) else {
        return nil
    }
    let mime = String(trimmed[mimeRange])
    return ParsedDataUrlImage(
        base64: String(trimmed[dataRange]),
        mediaType: mime == "image/png" ? "image/png" : "image/jpeg")
}

