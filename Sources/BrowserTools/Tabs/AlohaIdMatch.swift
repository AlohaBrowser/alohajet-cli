import Foundation

/// A markdown line matched while searching for `aloha-id` references.
public struct AlohaIdMatch: Equatable, Sendable {
    public var alohaId: String
    public var tagName: String
    public var text: String
    public var line: String
    public init(alohaId: String, tagName: String, text: String, line: String) {
        self.alohaId = alohaId
        self.tagName = tagName
        self.text = text
        self.line = line
    }
}
