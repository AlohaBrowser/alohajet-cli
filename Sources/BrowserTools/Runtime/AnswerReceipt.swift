import Foundation
import ToolABI

// MARK: - A receipt for the element the answer was read from

/// A receipt for each value the final answer reports, taken from the page the turn ended on.
///
/// Why: most fact-finding runs answer from the page view an ACTION returned, not from a read
/// tool. Measured over the 66 runs captured 2026-09-28..10-01: of 48 runs of the five
/// fact-finding tasks, 26 took the answer straight from a click / type / navigate result and only
/// about 10 had a `get_text` receipt for the element holding it. github-ss-r76 read **v3.8.5** off
/// the Releases page its own click returned; the only receipts in that result were the clicked
/// link and the page's main heading, so a mint had no evidence for a read step and none could
/// be built, whatever the server did.
///
/// So after the turn, on the page the answer was read from (``AnswerPageTracker``), the client
/// finds the elements whose text the answer repeats (see
/// ``pageMatchExpression(answer:prompt:hints:readIds:)``) and writes the same receipt a `get_text`
/// would have written for each (`[tool=answer]`, read rules: no value-bearing anchor). Nothing is
/// inferred about whether the answer is right.
///
/// THE WIRE. The host sends each ``Line/text`` as one string of the verdict's `answer_receipts`
/// (llmdex `POST /v1/verdict`), which journals it verbatim as `receipt answer: <text>` and reads
/// its brackets with the same grammar as every tool receipt (`RECEIPTS.md`, "Answer receipts").
///
/// Ported from AlohaBrowser/alohajet `Sources/AgentRuntime/AnswerReceipt.swift` (branch
/// windows-on-snips, dc514f76..a74a7d63), onto this package's receipt probes.
public nonisolated enum AnswerReceipt {
    /// At most this many values per answer.
    public static let maxValues = 4
    /// A value longer than this, or with more words than ``maxWords``, is a sentence, not a value.
    public static let maxValueLength = 80
    public static let maxWords = 12
    /// The prefix of the temporary aloha-id given to a matched element that has none, for the
    /// identity and anchor probes to find it by; removed again before ``answerReceipts`` returns.
    /// A real id is `<4-hex generation>-<hash>`, so the two never collide.
    static let temporaryIdPrefix = "aloha-answer-"

    /// The values an answer reports: its **bold** spans and its quoted spans ("…", “…”, «…»), in
    /// order, de-duplicated. A bold LABEL (`**Distance:**`) is not a value and is skipped.
    public static func values(in answer: String) -> [String] {
        // A bold LABEL followed by its value -- `**Walking distance**: 3.7 km`, `**Time:** 50 min`
        // (osm-route-r79): the value is the rest of the line, a trailing "(…)" gloss dropped. The
        // label itself is skipped below.
        var found: [(Int, String)] = []
        if let labelled = try? NSRegularExpression(pattern: #"\*\*[^*\n]+?(?::\*\*|\*\*:)[ \t]*([^\n*]+)"#) {
            let ns = answer as NSString
            for match in labelled.matches(in: answer, range: NSRange(location: 0, length: ns.length)) where match.numberOfRanges > 1 {
                var value = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
                if let paren = value.range(of: #"\s*\([^)]*\)\s*$"#, options: .regularExpression) { value.removeSubrange(paren) }
                found.append((match.range(at: 1).location, value))
            }
        }
        let patterns = [#"\*\*(.+?)\*\*(?!:)"#, #"“([^”\n]+)”"#, #"«\s*([^»\n]+?)\s*»"#, #""([^"\n]+)""#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = answer as NSString
            for match in regex.matches(in: answer, range: NSRange(location: 0, length: ns.length)) where match.numberOfRanges > 1 {
                found.append((match.range.location, ns.substring(with: match.range(at: 1))))
            }
        }
        var out: [String] = []
        for (_, raw) in found.sorted(by: { $0.0 < $1.0 }) {
            var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasSuffix(":") { continue }
            for wrap in [("\"", "\""), ("“", "”"), ("«", "»"), ("'", "'")] where value.hasPrefix(wrap.0) && value.hasSuffix(wrap.1) && value.count > 1 {
                value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            }
            while let last = value.last, ".,;!".contains(last) { value.removeLast() }
            guard !value.isEmpty, value.count <= maxValueLength,
                  value.split(whereSeparator: { $0.isWhitespace }).count <= maxWords,
                  !out.contains(value) else { continue }
            out.append(value)
            if out.count == maxValues { break }
        }
        return out
    }

    /// THE PAGE DECIDES WHAT THE VALUES ARE. Every visible element on the final page whose own text
    /// is short (at most 80 characters) is a candidate -- a form field never: its content is what
    /// was typed, not what the page said; it is kept when the ANSWER repeats its text
    /// as a whole run of words and the TASK did not already say it -- "v3.8.5" and "MHSanaei/3x-ui"
    /// on the 3x-ui Releases page are new information, "Latest" is the question's own word. Text
    /// is compared as lower-cased word tokens, so case, spacing and surrounding punctuation do not
    /// matter. Nested matches keep the innermost element; a lone short common word ("on", "the")
    /// is not a value. When no element matches by words, an element whose NUMBERS all appear in the
    /// answer (and not all in the task) is taken instead: the page writes "3.7km", the model
    /// "3.7 kilometers". The answer's own **bold** / quoted spans (``values(in:)``) only rank the
    /// candidates. Nothing here knows a site, a language or a kind of value.
    ///
    /// THE ELEMENT THE TURN READ COMES FIRST. A value can sit on the page more than once:
    /// github-ss-r87 (2026-10-02) read v3.8.5 off the release heading with `get_text`, and the
    /// receipt went to the first "v3.8.5" in document order, a sidebar tag list above it. `readIds`
    /// are the aloha-ids the turn's `get_text` calls read on this page, oldest first
    /// (``AnswerPageTracker/readIds(onTarget:)``). A candidate that WAS a read element ranks above
    /// every other, one INSIDE a read element next (a read of a whole row holds its values), the
    /// later read before the earlier; without a read, or when its element is gone, the order is as
    /// above.
    ///
    /// Returns a JSON array of `{id, path, text}` (at most ``maxValues``, best first), each element
    /// given a temporary aloha-id (``temporaryIdPrefix``) when it has none, `path` its live position
    /// path built the way the live-selector probe builds one; "" when nothing matches. A temporary
    /// id an earlier call left behind is removed first. A template (`\#(answerLiteral)`,
    /// `\#(promptLiteral)`, `\#(hintsLiteral)`, `\#(readsLiteral)`, `\#(maxValues)`) so a harness can
    /// run the shipped bytes against a fake document: `Tests/BrowserToolsTests/answer_receipt.js`.
    @MainActor
    static func pageMatchExpression(answer: String, prompt: String, hints: [String], readIds: [String] = []) -> String {
        let answerLiteral = JSValue.string(answer).stringify()
        let promptLiteral = JSValue.string(prompt).stringify()
        let hintsLiteral = JSValue.array(hints.map { .string($0) }).stringify()
        let readsLiteral = JSValue.array(readIds.map { .string($0) }).stringify()
        return #"""
        (function (answer, prompt, hints, reads, maxN) { /* receipt: answer page match */
          try {
            if (!document.body) return '';
            var TMP = 'aloha-answer-';
            var toks = function (s) { return String(s || '').toLowerCase().match(/[\p{L}\p{N}]+(?:[.,:\/'’_-][\p{L}\p{N}]+)*/gu) || []; };
            var nums = function (s) { return String(s || '').match(/\d+(?:[.,]\d+)*/g) || []; };
            var A = ' ' + toks(answer).join(' ') + ' ', P = ' ' + toks(prompt).join(' ') + ' ';
            var AN = nums(answer), PN = nums(prompt);
            var H = hints.map(function (h) { return toks(h).join(' '); });
            // The read elements' rank: later reads higher. 1000 for the element itself, 500 for
            // an element inside one; 0 when no read element holds it.
            var R = {};
            for (var ri = 0; ri < reads.length; ri++) R[reads[ri]] = ri + 1;
            var readBonus = function (e) {
              for (var n = e, up = 0; n && n !== document.body; n = n.parentElement, up++) {
                var rid = n.getAttribute ? n.getAttribute('aloha-id') : null;
                if (rid && Object.prototype.hasOwnProperty.call(R, rid)) return (up === 0 ? 1000 : 500) + R[rid];
              }
              return 0;
            };
            // A lone token is a value only when it is long enough to mean something: a bare "2"
            // matched github-ss-r82's numbered steps ("2. …") to a tab counter.
            // A lone WORD (no digit) is a value only when the answer bolded or quoted it: any page
            // carries common words the answer also uses ("Next", the pagination link github-ss-r84
            // matched). A lone token with a digit ("v3.8.5", "512") needs 3+ characters.
            var substantive = function (tk, T) {
              if (tk.length >= 2) return true;
              return /\d/.test(tk[0]) ? tk[0].length >= 3 : (tk[0].length >= 4 && H.indexOf(T) !== -1);
            };
            // The answer may quote PART of a longer page text: hn-swift-r82 wrote **“Approachable Swift
            // Concurrency”** for a title the page gives in full. A bold / quoted span of 2+ words
            // matches an element whose text contains it as a whole run.
            var HM = H.filter(function (h) { return h.split(' ').length >= 2; });
            var words = [], numbers = [];
            var all = document.body.querySelectorAll('*');
            for (var i = 0; i < all.length; i++) {
              var e = all[i], tag = e.tagName;
              // A temporary id an earlier call failed to remove is not the page's: drop it before
              // it can name the wrong element.
              var own = e.getAttribute ? e.getAttribute('aloha-id') : null;
              if (own && own.indexOf(TMP) === 0) e.removeAttribute('aloha-id');
              if (tag === 'SCRIPT' || tag === 'STYLE' || tag === 'NOSCRIPT' || tag === 'TEMPLATE') continue;
              // A field's content is not a value read off the page: a textarea's text is what was
              // typed there (`[text=]` never carries it, `ElementTextProbe`), a select's is its options.
              if (tag === 'TEXTAREA' || tag === 'INPUT' || tag === 'SELECT') continue;
              var raw = String(e.innerText || '').replace(/\s+/g, ' ').trim();
              if (!raw || raw.length > 80) continue;
              var r = e.getBoundingClientRect();
              if (!(r.width > 0 && r.height > 0)) continue;
              var tk = toks(raw);
              if (!tk.length) continue;
              var T = tk.join(' '), inner = false;
              for (var c = e.firstElementChild; c; c = c.nextElementSibling) {
                if (toks(c.innerText).join(' ') === T) { inner = true; break; }
              }
              if (inner) continue;
              var hinted = (H.indexOf(T) !== -1 ? 100 : 0) + readBonus(e);
              if (A.indexOf(' ' + T + ' ') !== -1 && P.indexOf(' ' + T + ' ') === -1 && substantive(tk, T)) {
                words.push({ e: e, T: T, raw: raw, score: hinted + (/\d/.test(T) ? 10 : 0) + T.length });
                continue;
              }
              var holds = HM.filter(function (h) { return (' ' + T + ' ').indexOf(' ' + h + ' ') !== -1 && P.indexOf(' ' + h + ' ') === -1; });
              if (holds.length) {
                words.push({ e: e, T: T, raw: raw, score: readBonus(e) + 50 + holds[0].length - (T.length - holds[0].length) / 10 });
                continue;
              }
              var en = nums(raw);
              if (en.length && raw.length <= 40 && en.every(function (n) { return AN.indexOf(n) !== -1; })
                  && !en.every(function (n) { return PN.indexOf(n) !== -1; })) {
                numbers.push({ e: e, T: T, raw: raw, score: hinted + en.length });
              }
            }
            var pool = (words.length ? words : numbers).sort(function (a, b) { return b.score - a.score; });
            var out = [], seen = {};
            for (var k = 0; k < pool.length && out.length < maxN; k++) {
              var m = pool[k];
              if (seen[m.T]) continue;
              seen[m.T] = true;
              var id = m.e.getAttribute('aloha-id');
              if (!id) { id = TMP + out.length; m.e.setAttribute('aloha-id', id); }
              var segs = [], ok = true;
              for (var n = m.e; n && n !== document.body; n = n.parentElement) {
                var p = n.parentElement;
                if (!p) { ok = false; break; }
                var tg = String(n.tagName || '').toLowerCase();
                if (!/^[a-z][a-z0-9-]*$/.test(tg)) { ok = false; break; }
                var same = 0, at = 0;
                for (var s2 = p.firstElementChild; s2; s2 = s2.nextElementSibling) {
                  if (s2.tagName === n.tagName) { same++; if (s2 === n) at = same; }
                }
                segs.unshift(same > 1 ? tg + ':nth-of-type(' + at + ')' : tg);
                if (segs.length > \#(StepTraceSelector.maxPathSegments)) { ok = false; break; }
              }
              if (ok) out.push({ id: id, path: ['body'].concat(segs).join('>'), text: m.raw.slice(0, 60) });
              else if (id.indexOf(TMP) === 0) m.e.removeAttribute('aloha-id');
            }
            return out.length ? JSON.stringify(out) : '';
          } catch (e) { return ''; }
        })(\#(answerLiteral), \#(promptLiteral), \#(hintsLiteral), \#(readsLiteral), \#(maxValues))
        """#
    }

    /// Removes the temporary aloha-ids ``pageMatchExpression(answer:prompt:hints:readIds:)`` added.
    /// By the id's prefix, not by a marker attribute: a marker would be read back into the
    /// receipt's `[attrs=]` by the identity probe, and a mint could address the element by an
    /// attribute that exists only while this runs.
    static let cleanupExpression = #"""
    (function () { /* receipt: answer cleanup */
      try {
        var s = document.querySelectorAll('[aloha-id^="aloha-answer-"]');
        for (var i = 0; i < s.length; i++) s[i].removeAttribute('aloha-id');
        return String(s.length);
      } catch (e) { return '0'; }
    })()
    """#

    /// One receipt line: `answer "v3.8.5": [selector=…] [tool=answer] …`.
    public struct Line: Equatable, Sendable {
        /// The element's text, as the page wrote it (at most 60 characters).
        public let value: String
        /// The receipt brackets, space-led: ` [selector=…] [tool=answer] [matches=N] …`.
        public let receipt: String

        public init(value: String, receipt: String) {
            self.value = value
            self.receipt = receipt
        }

        /// The line the verdict carries. The value is quoted the way a receipt token is: no `"`,
        /// no line break, and no square bracket inside (the reader takes `[name=…]` anywhere on
        /// the line for a bracket, so a value must never look like one).
        public var text: String {
            let safe = value.replacingOccurrences(of: "\"", with: "'")
                .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
            return "answer \"\(safe)\":\(receipt)"
        }
    }
}

extension AgentBrowserBridge {
    /// The answer receipts for `answer` (to the task `prompt`) on this bridge's page (see
    /// ``AnswerReceipt``). Read-only apart from the temporary ids, which are removed.
    func answerReceipts(for answer: String, prompt: String, readIds: [String] = []) async -> [AnswerReceipt.Line] {
        guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        var lines: [AnswerReceipt.Line] = []
        let expression = AnswerReceipt.pageMatchExpression(
            answer: answer, prompt: prompt, hints: AnswerReceipt.values(in: answer), readIds: readIds)
        // "" is "nothing matched" and stamped nothing; nil is a page that could not answer, which
        // the cleanup would not reach either (the next match removes what is left, see above).
        guard let raw = await evaluateForReceipt(expression), !raw.isEmpty else { return [] }
        if let found = JSValue.parse(raw), let items = found.arrayValue {
            for item in items {
                guard let id = item.string("id"), !id.isEmpty, let path = item.string("path"), !path.isEmpty else { continue }
                let text = item.string("text") ?? ""
                // The read rules: the anchor may not be built from the element's own text, which
                // is the value read.
                let note = PageToolReceipt.selectorNote(
                    selector: path, matches: await selectorMatchCount(path), text: text.isEmpty ? nil : text,
                    identity: await elementIdentity(selector: path, alohaId: id, forRead: true),
                    tool: "answer")
                if !note.isEmpty { lines.append(.init(value: text, receipt: note)) }
            }
        }
        _ = await evaluateForReceipt(AnswerReceipt.cleanupExpression)
        return lines
    }
}

/// The answer receipts for `answer` on `tab` -- the page the answer was read from, preferring the
/// elements the turn's `get_text` calls read there (`tracker`'s ``AnswerPageTracker/readIds(onTarget:)``).
/// For a runner's turn end, which owns the tab but not the bridge: take the tab from
/// ``AnswerPageTracker/observedTab(in:)``, send each ``AnswerReceipt/Line/text`` with the verdict.
/// Best-effort: a page that cannot answer yields no lines, never a throw. Does not count as an
/// observation of the tab.
@MainActor
public func answerReceipts(
    onTab tab: CDPTabHandle, answer: String, prompt: String, tracker: AnswerPageTracker = .current
) async -> [AnswerReceipt.Line] {
    let reads = tracker.readIds(onTarget: tab.id)
    let bridge = AgentBrowserBridge(backend: CDPAgentBridgeBackend(tab: tab, signal: AbortSignal()))
    return await bridge.answerReceipts(for: answer, prompt: prompt, readIds: reads)
}
