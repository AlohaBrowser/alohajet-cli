import Foundation

// Lives in ToolABI, with the DOM model, because
// `AgentDOMSnapshotting.getInteractMarkdown` takes it across the module boundary.

public struct DomSerializeOptions: Sendable {
    public var includeUrls: Bool
    /// Pre-clean the DOM (drop boilerplate / chrome) before serialization. Baseline OFF.
    public var cleanDom: Bool
    /// Extract embedded site JSON (JSON-LD / framework data) as a structured block. Baseline OFF.
    public var extractSiteJson: Bool

    public init(
        includeUrls: Bool = false,
        cleanDom: Bool = false,
        extractSiteJson: Bool = false
    ) {
        self.includeUrls = includeUrls
        self.cleanDom = cleanDom
        self.extractSiteJson = extractSiteJson
    }
}
