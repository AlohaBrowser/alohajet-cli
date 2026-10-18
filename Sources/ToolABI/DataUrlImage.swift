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

/// Parses a `data:<mime>;base64,<payload>` URL. The PAYLOAD decides the media type when its
/// first bytes say what it is (PNG, JPEG, GIF, WebP): the desktop app's screenshot arrived as
/// `data:image/jpeg;base64,iVBORw0KGgo…` -- PNG bytes under a JPEG label (W6 e2e), which a
/// vision endpoint that trusts the label decodes as a broken JPEG. Otherwise the label maps as
/// before: PNG to `image/png`, anything else to `image/jpeg`. Returns `nil` when the string is not
/// a base64 data url.
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
    let payload = String(trimmed[dataRange])
    return ParsedDataUrlImage(
        base64: payload,
        mediaType: sniffedImageMediaType(base64: payload) ?? (mime == "image/png" ? "image/png" : "image/jpeg"))
}

/// The media type a base64 image payload's magic bytes name, or nil when they name none of the
/// four a vision endpoint takes.
public func sniffedImageMediaType(base64 payload: String) -> String? {
    if payload.hasPrefix("iVBORw0KGgo") { return "image/png" }
    if payload.hasPrefix("/9j/") { return "image/jpeg" }
    if payload.hasPrefix("R0lGOD") { return "image/gif" }
    if payload.hasPrefix("UklGR") { return "image/webp" }
    return nil
}

