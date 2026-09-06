import Foundation

/// Whether an action moved the page — the one thing an action receipt never used to say.
///
/// MEASURED on the WebArena read-tier corpus: **143 rows end their final tool call on a bare
/// `Clicked element "X" (single).`** and 80 of those failed; 23 more end on `Typed into element "X".`
/// and 21 of those failed; 7 on `Selected X on element Y.`, 6 failed. A receipt of that shape is equally
/// true of an action that navigated, one that opened a menu, and one that hit nothing at all, so the
/// model proceeds as though it worked.
///
/// Shared rather than copied per tool, because three tools saying the same thing three slightly different
/// ways is how a model learns to distrust all three.
public nonisolated enum PageDelta {
    /// What a receipt says about the page after an action.
    ///
    /// THE POINT OF THE WHOLE CHANGE. `Clicked element "2s" (single).` is true of a click that
    /// navigated, a click that opened a menu, and a click that hit nothing at all — and 44 rows of the
    /// WebArena corpus answered the task immediately after a receipt of exactly that shape. Naming the
    /// URL is not enough on its own either: the model cannot tell a new URL from the old one without
    /// having memorised the previous receipt, so the receipt says which of the two happened.
    ///
    /// Silent when the URL is unknown (the backend's navigation seam is optional and some layers return
    /// ""), because a receipt that claims "URL unchanged" when it simply could not read the URL would be
    /// worse than the bare one it replaces.
    public static func describe(urlBefore: String, urlAfter: String) -> String {
        guard !urlAfter.isEmpty else { return "" }
        if urlBefore.isEmpty { return " Now at \(urlAfter)." }
        if urlBefore == urlAfter {
            return " The page did NOT navigate — still at \(urlAfter). If you expected a new page, the "
                + "action did not do what you assumed: read the page before acting again."
        }
        return " Navigated to \(urlAfter)."
    }
}
