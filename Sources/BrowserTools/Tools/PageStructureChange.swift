import Foundation
import ToolABI

/// The one bit a page action passes UP to its host: "the page's structure moved under me".
///
/// WHY A HOST NEEDS IT. An agent dispatches a round's page tools before the first one runs, so
/// every id in the round was chosen against the page as it stood BEFORE the round. When an
/// action replaces that page, the calls queued behind it are aimed at elements that may no
/// longer exist -- and the model cannot know, because the fresh page rides in that action's
/// result and reaches it only next round. A host that serialises page tools can read this mark
/// off a finished result and withhold the writes queued behind it.
///
/// Measured on a Zara run (AlohaBrowser/alohajet, llmdex tag `zara-trench-20260916-195459-f85b`):
/// one round batched `page_click`, `page_type`, `page_press_keys`. The click opened a promo
/// overlay, which the fingerprint saw and the click's result carried as a fresh page of 11 KB. The
/// type then aimed at an input id from the OLD page, now hidden, and was refused; the Enter fired
/// blind at whatever held focus. The right id was already in the click's result.
///
/// WHAT COUNTS AS "MOVED" is the same answer the tools already compute to decide whether to attach
/// a snapshot: `AgentBrowserBridge.pageFingerprint` (document generation, element count, URL). It
/// is deliberately NOT "a snapshot was attached" -- `page_type` attaches one unconditionally,
/// because a typed value changes none of those three, and marking every successful type would
/// withhold the submit in every type-then-click round. Typing does not restructure the page;
/// clicking, selecting and navigating can.
///
/// Carried in the result's `metadata`, under a key the host reads by name, so it survives the
/// result path without being parsed out of prose.
///
/// Main-actor isolated like the rest of this module (not `nonisolated`): `RawToolResult` is
/// isolated here, and `stamp` reads and writes its fields.
public enum PageStructureChange {
    /// Metadata key. A `.bool(true)` under it means the structure moved. The agent repo's
    /// `PageChangeMark.decode` reads this exact string.
    public static let key = "pageStructureChanged"

    /// Stamps `result` when `moved` is true; returns it untouched otherwise. An errored result is
    /// never stamped: the action did not happen, so the page did not move because of it.
    ///
    /// MERGES into existing metadata rather than replacing it. `TabHandle.naming` sets the tab
    /// identity in the same dictionary and skips a result that already carries metadata, so this
    /// must run AFTER `naming` and must not clobber what it wrote.
    public static func stamp(_ result: RawToolResult, moved: Bool) -> RawToolResult {
        guard moved, result.isError != true else { return result }
        var stamped = result
        var metadata = stamped.metadata ?? [:]
        metadata[key] = .bool(true)
        stamped.metadata = metadata
        return stamped
    }

    /// Whether `toolMetadata` says the structure moved. Absent, or anything but `.bool(true)`,
    /// reads as "did not move".
    public static func decode(toolMetadata: [String: WorkflowValue]?) -> Bool {
        if case .bool(true)? = toolMetadata?[key] { return true }
        return false
    }
}
