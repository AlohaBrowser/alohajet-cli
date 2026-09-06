import Foundation

// MARK: - AgentWebExtractionOptions
//
// The runtime-side projection of the CLI's improvement flags: the subset the agent's
// web-extraction path reads (the `manage_tabs` read tool, the snapshot/observation
// pipeline). It is carried on `NativeToolServices` so deep tool code reads it from the
// context it already has, instead of reaching for an env var — the values are resolved
// ONCE at the CLI composition root (from `ImproveFlags`) and threaded here.
//
// Every field's baseline is the EXACT prior behavior: the booleans default OFF and
// `defaultIncludeScreenshot` defaults `true` (the existing `include_screenshot != false`
// default). So `AgentWebExtractionOptions()` is a pure no-op carrier — the A/B baseline.
//
// FOUR FIELDS WERE DELETED HERE — `dedupeSnapshots`, `maxObsTokens`, `compactTools`,
// `maxSteps`. They came along on the carrier from an agent loop this package does not
// contain, and nothing in it ever read them: a documented knob that moves nothing is a
// lie told to whoever sets it. Every field below is read on a real path.
public nonisolated struct AgentWebExtractionOptions: Sendable, Equatable {
    /// Pre-clean the DOM before serialization.
    public var cleanDom: Bool
    /// Extract embedded site JSON (JSON-LD / framework data) as a structured block.
    public var extractSiteJson: Bool
    /// The default for a `manage_tabs` read's screenshot when the call does not specify
    /// one. Baseline `true` (matches the existing `include_screenshot != false` default).
    public var defaultIncludeScreenshot: Bool
    /// Append a one-line batching tip to the result of a single-item read or a single-field type.
    ///
    /// WHY THE TOOL RESULT AND NOT THE PROMPT. `get_text` has read a comma-separated list of ids since
    /// 2026-08-07 and its description says so, and wa-25 still spent EIGHT of its thirteen calls reading one
    /// id at a time and then timed out. A standing schema description is read once, far from the moment of the
    /// decision; three separate prompt-rule interventions measured exactly zero this same week. The tool result
    /// is where the model is actually looking, and it costs nothing on the rounds where the model got it right.
    /// Baseline OFF, so the OFF path is byte-identical.
    public var batchHints: Bool

    public init(
        cleanDom: Bool = false,
        extractSiteJson: Bool = false,
        defaultIncludeScreenshot: Bool = true,
        batchHints: Bool = false
    ) {
        self.cleanDom = cleanDom
        self.extractSiteJson = extractSiteJson
        self.defaultIncludeScreenshot = defaultIncludeScreenshot
        self.batchHints = batchHints
    }

    /// The all-baseline carrier (every improvement OFF, screenshot default `true`).
    public static let baseline = AgentWebExtractionOptions()

    /// Project the serialization-bound flags onto a `DomSerializeOptions`, preserving the
    /// caller's `includeUrls` decision. With the baseline carrier this produces exactly
    /// `DomSerializeOptions(includeUrls: includeUrls)` — the prior value — so the OFF path
    /// is byte-identical to baseline.
    @MainActor public func domSerializeOptions(includeUrls: Bool) -> DomSerializeOptions {
        DomSerializeOptions(
            includeUrls: includeUrls,
            cleanDom: cleanDom,
            extractSiteJson: extractSiteJson)
    }
}
