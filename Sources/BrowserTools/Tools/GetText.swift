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

    /// WHAT WAS READ, in replayable terms -- the same `[selector=…] [tool=get_text] [matches=N]
    /// [index] [text] [attrs] [list]` note a click or type receipt carries, resolved BEFORE the
    /// read from the same ladder. Until 2026-09-23 a read reported no selector at all (llmdex's
    /// CLIENT-CONTRACT §4: zero of every `get_text` receipt held one), so a scenario ending in
    /// "…and tell me what it says" had no evidence for its read step: the mint invented one and
    /// refused it (agent run github-ss-r25, `h1.d-flex span`), or read an element the run had
    /// clicked and returned the link's label. Empty when the element has no durable selector --
    /// the note never guesses.
    static func readNote(_ alohaId: String, _ tab: StepTraceTab?, _ bridge: AgentBrowserBridge) async -> String {
        guard let selector = await bridge.liveSelector(PageToolReceipt.durableSelector(alohaId: alohaId, tab: tab), alohaId: alohaId)
        else { return "" }
        let text = await bridge.elementText(alohaId: alohaId)
        let identity = await bridge.elementIdentity(selector: selector, alohaId: alohaId)
        if let free = answerFreeReadAddress(selector: selector, text: text, identity: identity) {
            return PageToolReceipt.selectorNote(
                selector: free.selector, matches: free.matches, text: text, identity: free.identity, tool: "get_text")
        }
        return PageToolReceipt.selectorNote(
            selector: selector, matches: await bridge.selectorMatchCount(selector),
            text: text, identity: identity, tool: "get_text")
    }

    /// A READ'S `[selector]` NEVER CARRIES WHAT IT READS. The ladder can put the read text into the
    /// selector itself -- its link rung writes the link's own address, and the address holds the
    /// value: agent run github-ss-r82 read v3.8.5 through `a[href="/MHSanaei/3x-ui/releases/tag/v3.8.5"]`,
    /// github-ss-r84 read "Latest" through `a[href="/MHSanaei/3x-ui/releases/latest"]` (the mint
    /// refused it: "a selector that CONTAINS THE ANSWER"). When the ladder's selector contains the
    /// text read (3+ characters, any case), the element is addressed by its place in its LIST
    /// (`[selector]` = the list, `[matches]` its size, `[index]` the place). nil when the selector
    /// is already free of the text, or there is nothing better to offer.
    static func answerFreeReadAddress(selector: String, text: String?, identity: ElementIdentity?)
        -> (selector: String, matches: Int?, identity: ElementIdentity?)? {
        guard let text, text.count >= 3 else { return nil }
        let needle = text.lowercased()
        guard selector.lowercased().contains(needle) else { return nil }
        if let list = identity?.list, !list.selector.lowercased().contains(needle) {
            var placed = ElementIdentity(index: list.index, attributes: identity?.attributes ?? [])
            placed.list = list
            return (list.selector, list.count, placed)
        }
        return nil
    }

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
                // The read's receipt note, resolved BEFORE the read like every action's.
                let note = await Self.readNote(capped[0], resolved.cdpTab, bridge)
                let result = await bridge.getTextById(capped[0])
                let text = result.isError ? result.output : Self.truncate(result.output, perId) + note
                // ONE OPTIONAL LINE, at the moment a round was spent on one element. The schema has advertised
                // the list form since this tool learned it, and a corpus row still spent EIGHT of thirteen
                // calls reading one id at a time before timing out — a description is read far from the
                // decision. Flag-gated and OFF by baseline, so this path stays byte-identical unless asked.
                let hint = (context.services?.webExtractionOptions ?? .baseline).batchHints && !result.isError
                    ? "\n(Reading one element per call spends a round each. Pass several ids at once: "
                      + "aloha_id=\"7959-1f3a9c2b,7959-7b21e40d,7959-3c8f95a1\".)"
                    : ""
                return resolved.tab.naming(
                    RawToolResult(output: text + hint, isError: result.isError ? true : nil))
            }
            var blocks: [String] = []
            var failures = 0
            for id in capped {
                let note = await Self.readNote(id, resolved.cdpTab, bridge)
                let result = await bridge.getTextById(id)
                if result.isError { failures += 1 }
                // A failed read gets no note: there is nothing replayable about it.
                blocks.append("[\(id)] \(result.isError ? result.output : Self.truncate(result.output, perId) + note)")
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
