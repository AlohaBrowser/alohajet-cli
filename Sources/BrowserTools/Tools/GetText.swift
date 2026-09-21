import Foundation
import ToolABI

/// The executable `get_text` tool: reads the visible text (or input value) of one element
/// on the active tab by its `aloha_id`. The `window.__aloha.getText(...)` call text is
/// built in Swift; no caller-authored code reaches the page.
@MainActor public final class GetTextExecutorTool: ExecutorTool {
    public let name = "get_text"

    public init() {}

    /// How many elements one call may read. Bounded because the point of batching is to spend FEWER rounds,
    /// not to return an unbounded observation — the prompt is re-sent every round, so a huge result is paid
    /// again and again. Twenty covers a page of listing rows, which is the shape this exists for.
    private static let maxBatch = 20

    /// The default `max_chars` budget for one call's text.
    ///
    /// THE READ IS OTHERWISE UNBOUNDED. The in-page reader returns whole-subtree
    /// `textContent`, the bridge passes it through, and the join below never truncated —
    /// so `get_text` on the document body's id returned the entire page, into whatever
    /// transcript the host persists. The page-read path caps three separate ways; this
    /// one capped nowhere.
    static let defaultMaxChars = 20_000

    public func execute(_ input: WorkflowValue?, _ context: ToolExecutionContext) async throws -> RawToolResult {
        guard let raw = PageToolInput.string(input, "aloha_id"), !raw.isEmpty else {
            return RawToolResult(output: "get_text requires an \"aloha_id\" naming the element to read.", isError: true)
        }

        // ONE CALL PER ELEMENT IS THE WHOLE ROUND BUDGET. Reading a listing one row at a time spends a
        // round per row, and the standing prompt is re-sent on every round — so the read granularity,
        // not the read itself, is what a page of rows costs.
        //
        // A comma-separated list keeps the schema a string, so every existing caller is unaffected and a single
        // id behaves exactly as before, byte for byte.
        let ids = raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !ids.isEmpty else {
            return RawToolResult(output: "get_text requires an \"aloha_id\" naming the element to read.", isError: true)
        }
        var seen: Set<String> = []
        let unique = ids.filter { seen.insert($0).inserted }
        let capped = Array(unique.prefix(Self.maxBatch))
        // Split the budget across the ids so one enormous element cannot starve the rest, and so a
        // batch costs no more than a single read. A read that hit the cap says so, in place.
        // `Int($0)` TRAPPED on a `max_chars` too large for `Int` (`1e300` is a legal JSON number).
        // Saturating, not rejecting: this is a CAP, and asking for more than `Int.max` characters
        // means "do not cap me" — the same clamping choice `page_wait_for` makes for `timeout_ms`.
        let maxChars = max(1, PageToolInput.number(input, "max_chars").map(intSaturating) ?? Self.defaultMaxChars)
        let perId = max(1, maxChars / capped.count)

        switch await resolveActivePageTab(name, context) {
        case let .failure(errorResult):
            return errorResult
        case let .success(resolved):
            let bridge = makePageBridge(resolved.cdpTab, context.signal)
            if capped.count == 1 {
                let result = await bridge.getTextById(capped[0])
                let text = result.isError ? result.output : Self.truncate(result.output, perId)
                // ONE OPTIONAL LINE, at the moment a round was spent on one element. The schema has advertised
                // the list form since this tool learned it, and a corpus row still spent EIGHT of thirteen
                // calls reading one id at a time before timing out — a description is read far from the
                // decision. Flag-gated and OFF by baseline, so this path stays byte-identical unless asked.
                let hint = (context.services?.webExtractionOptions ?? .baseline).batchHints && !result.isError
                    ? "\n(Reading one element per call spends a round each. Pass several ids at once: "
                      + "aloha_id=\"1f3a9c2b,7b21e40d,3c8f95a1\".)"
                    : ""
                return resolved.tab.naming(
                    RawToolResult(output: text + hint, isError: result.isError ? true : nil))
            }
            var blocks: [String] = []
            var failures = 0
            for id in capped {
                let result = await bridge.getTextById(id)
                if result.isError { failures += 1 }
                blocks.append("[\(id)] \(result.isError ? result.output : Self.truncate(result.output, perId))")
            }
            if capped.count < unique.count {
                blocks.append("(read \(capped.count) of \(unique.count) ids — \(Self.maxBatch) per call is the "
                              + "cap; ask for the rest in another call)")
            }
            // An error only when EVERY id failed: a batch where one id is stale is still a useful read, and
            // marking the whole call an error would send the model back to reading one at a time.
            return resolved.tab.naming(
                RawToolResult(output: blocks.joined(separator: "\n"),
                              isError: failures == capped.count ? true : nil))
        }
    }

    /// Naming the cut matters more than the truncation: a silently clipped read looks like a
    /// complete one, and a caller that cannot tell will answer from half a page.
    static func truncate(_ text: String, _ limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit))
            + "\n…[truncated: \(text.count) characters, \(limit) returned. Raise max_chars or read a narrower element.]"
    }
}
