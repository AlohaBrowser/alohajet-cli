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
    /// order, de-duplicated. A bold LABEL (`**Distance:**`, `**Distance**: 3.7 km`) is not a value
    /// and is skipped; the value after it is taken instead.
    ///
    /// WHAT A LABEL IS (2026-10-18). A bold span with the colon INSIDE it (`**Time:** 50 min`) is
    /// always a label. One with the colon AFTER it (`**Walking distance**: 3.7 km`) is a label only
    /// when it opens its line or clause (start of line, a list bullet, or after `.`, `;`, `,`, `|`,
    /// a dash or `(`) AND a value follows it on the same line. Otherwise the bold span IS the value
    /// and the colon introduces what the answer says about it: quotes-love-first-author's teach run
    /// answered "The first quote is attributed to **André Gide**:" and put the quote on the next
    /// line, and André Gide -- the answer's lead value -- was dropped as a label, so the page's four
    /// longest author names, which the answer merely listed, took every receipt slot and the mint
    /// read the second quote's author.
    public static func values(in answer: String) -> [String] {
        let ns = answer as NSString
        let whole = NSRange(location: 0, length: ns.length)
        var found: [(Int, String)] = []
        // Where each bold LABEL starts: the bold pass below skips those spans.
        var labelStarts = Set<Int>()
        // A bold label followed by its value -- `**Walking distance**: 3.7 km`, `**Time:** 50 min`
        // (osm-route-r79): the value is the rest of the line, a trailing "(…)" gloss dropped.
        if let labelled = try? NSRegularExpression(pattern: #"\*\*[^*\n]+?(:\*\*|\*\*:)[ \t]*([^\n*]*)"#) {
            for match in labelled.matches(in: answer, range: whole) where match.numberOfRanges > 2 {
                let colonInside = ns.substring(with: match.range(at: 1)) == ":**"
                var value = ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
                if let paren = value.range(of: #"\s*\([^)]*\)\s*$"#, options: .regularExpression) { value.removeSubrange(paren) }
                let valued = cleanValue(value) != nil
                if colonInside || (valued && opensClause(answer, at: match.range.location)) {
                    labelStarts.insert(match.range.location)
                    if valued { found.append((match.range(at: 2).location, value)) }
                }
            }
        }
        let patterns = [#"\*\*(.+?)\*\*"#, #"“([^”\n]+)”"#, #"«\s*([^»\n]+?)\s*»"#, #""([^"\n]+)""#]
        for (index, pattern) in patterns.enumerated() {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: answer, range: whole) where match.numberOfRanges > 1 {
                if index == 0, labelStarts.contains(match.range.location) { continue }
                found.append((match.range.location, ns.substring(with: match.range(at: 1))))
            }
        }
        var out: [String] = []
        for (_, raw) in found.sorted(by: { $0.0 < $1.0 }) {
            guard let value = cleanValue(raw), !out.contains(value) else { continue }
            out.append(value)
            if out.count == maxValues { break }
        }
        return out
    }

    /// A span as a value: trimmed, unwrapped from its quotes, trailing punctuation dropped; nil
    /// when it is empty, a label (ends in `:`), or a sentence (over ``maxValueLength`` characters
    /// or ``maxWords`` words).
    static func cleanValue(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasSuffix(":") { return nil }
        for wrap in [("\"", "\""), ("“", "”"), ("«", "»"), ("'", "'")] where value.hasPrefix(wrap.0) && value.hasSuffix(wrap.1) && value.count > 1 {
            value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        while let last = value.last, ".,;!".contains(last) { value.removeLast() }
        guard !value.isEmpty, value.count <= maxValueLength,
              value.split(whereSeparator: { $0.isWhitespace }).count <= maxWords else { return nil }
        return value
    }

    /// Whether the text before UTF-16 offset `location` puts it at the start of a line or a clause:
    /// nothing but whitespace, quote markers and a list bullet since the line break, or a `.`, `;`,
    /// `,`, `|`, a dash or `(` right before it. "attributed to **André Gide**:" does not open one.
    static func opensClause(_ text: String, at location: Int) -> Bool {
        let before = (text as NSString).substring(to: location)
        let line = before.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        if line.range(of: #"^[ \t>]*(?:(?:[-*+•]|\d+[.)])[ \t]+)?$"#, options: .regularExpression) != nil { return true }
        return line.range(of: #"[.;,|(—–-][ \t]*$"#, options: .regularExpression) != nil
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
    /// THE ANSWER'S SPANS IN ORDER, THE MAIN CONTENT, THE WHOLE VALUE (2026-10-18). An earlier bold /
    /// quoted span ranks above a later one; an element in the page's main content above one in its
    /// navigation, sidebar or page header/footer; and when an element holds a whole multi-word span,
    /// an element holding only part of it ("10 December" for "10 December 1815") is dropped, as is an
    /// element around another that holds the same span.
    ///
    /// Returns a JSON array of `{id, path, text, tag, attrs, desc}` (at most ``maxValues``, best
    /// first), each element given a temporary aloha-id (``temporaryIdPrefix``) when it has none,
    /// `path` its live position path built the way the live-selector probe builds one, `tag` and
    /// `attrs` what the selector ladder reads (id, test hooks, name, type, href, role, class) and
    /// `desc` the first class tokens inside it; "" when nothing matches. A temporary
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
            // THE ANSWER'S OWN SPANS IN ITS OWN ORDER: a hint ranks above every unhinted candidate,
            // and an earlier hint above a later one, so the lead value is never pushed out by the
            // longer names the answer merely lists after it (quotes-love-first-author: "**André
            // Gide**" first, then thirteen more authors; the four longest took every slot).
            var hintRank = function (T) { var hi = H.indexOf(T); return hi === -1 ? 0 : 100 + (H.length - hi); };
            // THE MAIN CONTENT FIRST. Among candidates the answer repeats, one inside the page's
            // main content (`main`, `article`, role=main) ranks above one in its chrome (`nav`,
            // `aside`, a page-level `header` / `footer`, their roles): the same value in a sidebar
            // list and in the release heading is the heading's (github-ss-r87).
            var place = function (e) {
              var chain = [];
              for (var n = e; n && n !== document.body; n = n.parentElement) chain.push(n);
              var iMain = -1, chrome = false;
              for (var a = 0; a < chain.length; a++) {
                var t = chain[a].tagName, role = chain[a].getAttribute ? String(chain[a].getAttribute('role') || '').toLowerCase() : '';
                if (iMain === -1 && (t === 'MAIN' || t === 'ARTICLE' || role === 'main')) iMain = a;
              }
              for (var b = 0; b < chain.length; b++) {
                var t2 = chain[b].tagName, role2 = chain[b].getAttribute ? String(chain[b].getAttribute('role') || '').toLowerCase() : '';
                if (t2 === 'NAV' || t2 === 'ASIDE' || role2 === 'navigation' || role2 === 'complementary' || role2 === 'search') chrome = true;
                else if ((t2 === 'HEADER' || t2 === 'FOOTER' || role2 === 'banner' || role2 === 'contentinfo') && !(iMain > b)) chrome = true;
              }
              return chrome ? -20 : (iMain >= 0 ? 20 : 0);
            };
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
              var hinted = hintRank(T) + readBonus(e) + place(e);
              if (A.indexOf(' ' + T + ' ') !== -1 && P.indexOf(' ' + T + ' ') === -1 && substantive(tk, T)) {
                words.push({ e: e, T: T, raw: raw, h: H.indexOf(T) !== -1 ? T : '', score: hinted + (/\d/.test(T) ? 10 : 0) + T.length });
                continue;
              }
              var holds = HM.filter(function (h) { return (' ' + T + ' ').indexOf(' ' + h + ' ') !== -1 && P.indexOf(' ' + h + ' ') === -1; });
              if (holds.length) {
                words.push({ e: e, T: T, raw: raw, h: holds[0], holder: true,
                             score: readBonus(e) + place(e) + 50 + holds[0].length - (T.length - holds[0].length) / 10 });
                continue;
              }
              var en = nums(raw);
              if (en.length && raw.length <= 40 && en.every(function (n) { return AN.indexOf(n) !== -1; })
                  && !en.every(function (n) { return PN.indexOf(n) !== -1; })) {
                numbers.push({ e: e, T: T, raw: raw, score: hinted + en.length });
              }
            }
            // THE FULL VALUE, NOT A PIECE OF IT (wiki-ada-lovelace-birthdate, 2026-10-18). When an
            // element holds a whole bold / quoted span of the answer ("10 December 1815", in the
            // infobox cell), an element whose text is only PART of that span ("10 December", a
            // reference's access date further down) is not where the answer came from: it is
            // dropped, unless the turn read it. And of the elements holding the same span, the
            // innermost is kept: the cell, not its row; the author's own `<small>`, not the
            // "by André Gide (about)" line around it.
            var full = {};
            for (var w = 0; w < words.length; w++) if (words[w].h) full[words[w].h] = true;
            var within = function (inner, outer) {
              for (var n = inner ? inner.parentElement : null; n; n = n.parentElement) if (n === outer) return true;
              return false;
            };
            words = words.filter(function (m) {
              if (readBonus(m.e) > 0) return true;
              for (var h in full) {
                if (h !== m.T && (' ' + h + ' ').indexOf(' ' + m.T + ' ') !== -1) return false;
              }
              if (m.holder) {
                for (var o = 0; o < words.length; o++) {
                  if (words[o] !== m && words[o].h === m.h && within(words[o].e, m.e)) return false;
                }
              }
              return true;
            });
            var pool = (words.length ? words : numbers).sort(function (a, b) { return b.score - a.score; });
            // What the client's selector ladder (`StepTraceSelector`) reads off an element, so the
            // receipt can name it by an id, a test hook, a name or a class rather than its position;
            // and the class tokens inside it, to narrow a class that several elements share.
            var LADDER = ['id', 'data-testid', 'data-test', 'name', 'type', 'href', 'role', 'class'];
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
              if (!ok) { if (id.indexOf(TMP) === 0) m.e.removeAttribute('aloha-id'); continue; }
              var attrs = {};
              for (var li = 0; li < LADDER.length; li++) {
                var av = m.e.getAttribute(LADDER[li]);
                if (av !== null && av !== undefined && String(av) !== '') attrs[LADDER[li]] = String(av).slice(0, 200);
              }
              var desc = [], inside = m.e.querySelectorAll ? m.e.querySelectorAll('*') : [];
              for (var di = 0; di < inside.length && di < 200 && desc.length < 6; di++) {
                var cl = String((inside[di].getAttribute && inside[di].getAttribute('class')) || '').split(/\s+/);
                for (var ci = 0; ci < cl.length && desc.length < 6; ci++) if (cl[ci] && desc.indexOf(cl[ci]) === -1) desc.push(cl[ci]);
              }
              out.push({ id: id, path: ['body'].concat(segs).join('>'), text: m.raw.slice(0, 60),
                         tag: String(m.e.tagName || '').toLowerCase(), attrs: attrs, desc: desc });
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
    /// ``AnswerReceipt``). Read-only apart from the temporary ids, which are removed. At most
    /// ``AnswerReceipt/maxLines`` lines, each shorter than ``AnswerReceipt/maxLineLength``.
    func answerReceipts(for answer: String, prompt: String, readIds: [String] = []) async -> [AnswerReceipt.Line] {
        guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        var lines: [AnswerReceipt.Line] = []
        let expression = AnswerReceipt.pageMatchExpression(
            answer: answer, prompt: prompt, hints: AnswerReceipt.values(in: answer), readIds: readIds)
        // "" is "nothing matched" and stamped nothing; nil is a page that could not answer, which
        // the cleanup would not reach either (the next match removes what is left, see above).
        guard let raw = await evaluateForReceipt(expression), !raw.isEmpty else { return [] }
        if let found = JSValue.parse(raw), let items = found.arrayValue {
            for item in items where lines.count < AnswerReceipt.maxLines {
                guard let id = item.string("id"), !id.isEmpty, let path = item.string("path"), !path.isEmpty else { continue }
                let text = item.string("text") ?? ""
                let address = await answerAddress(item: item, alohaId: id, path: path, text: text)
                // The read rules: the anchor may not be built from the element's own text, which
                // is the value read; and the selector may not contain it either (exception 2).
                let identity = await elementIdentity(selector: address.selector, alohaId: id, forRead: true)
                let shown = text.isEmpty ? nil : text
                let free = GetTextExecutorTool.answerFreeReadAddress(selector: address.selector, text: shown, identity: identity)
                let note: (ElementIdentity?) -> String = { identity in
                    if let free {
                        var placed = free.identity
                        if identity?.attributes.isEmpty == true { placed = placed.map { AnswerReceipt.withoutAttributes($0) } }
                        return PageToolReceipt.selectorNote(
                            selector: free.selector, matches: free.matches, text: shown, identity: placed, tool: "answer")
                    }
                    return PageToolReceipt.selectorNote(
                        selector: address.selector, matches: address.matches, text: shown, identity: identity, tool: "answer")
                }
                // ONE LINE STAYS UNDER llmdex's ENTRY CAP (4000 runes, `answerReceiptChars`), which
                // cuts a longer one mid-bracket: the attributes go first, then the line.
                var line = AnswerReceipt.Line(value: text, receipt: note(identity))
                if !AnswerReceipt.fits(line), let identity {
                    line = AnswerReceipt.Line(value: text, receipt: note(AnswerReceipt.withoutAttributes(identity)))
                }
                if !line.receipt.isEmpty, AnswerReceipt.fits(line) { lines.append(line) }
            }
        }
        _ = await evaluateForReceipt(AnswerReceipt.cleanupExpression)
        return lines
    }

    /// WHERE A RECEIPT FOR A MATCHED ELEMENT POINTS, and how many elements that matches now.
    ///
    /// The selector ladder first, as every tool receipt's (`StepTraceSelector`: an id a person
    /// wrote, a test hook, a form name, a link's path, a role, stable classes), from the
    /// attributes the page matcher read off the element, VERIFIED on the live page. Until
    /// 2026-10-18 an answer receipt always carried the element's position path, so the mint copied
    /// `body>div:nth-of-type(1)>div>div` for the-internet's `#flash` and a twelve-segment path for
    /// Wikipedia's infobox cell: it reads right until the layout moves, then reads a different
    /// element with no error.
    ///
    /// A ladder selector that several elements share (`td.infobox-data`, every infobox cell) is
    /// NARROWED when a class inside the element makes it unique: `td.infobox-data:has(.nickname)`
    /// names Ada Lovelace's "Born" cell on any revision of the article. Tried only with classes the
    /// ladder itself would accept, and only one that resolves to exactly this element is kept.
    /// Otherwise the shared selector stays, and `[index=]` says which of its matches the element is.
    ///
    /// With no ladder rung, or one the live page no longer matches, the element's live position
    /// path (the matcher's `path`), as before.
    func answerAddress(item: JSValue, alohaId: String, path: String, text: String) async -> (selector: String, matches: Int?) {
        if let ladder = AnswerReceipt.ladderSelector(item: item), let count = await liveMatchesContaining(ladder, alohaId: alohaId) {
            if count > 1 {
                for candidate in AnswerReceipt.narrowed(ladder, insideClasses: item.array("desc") ?? [], text: text) {
                    if await liveMatchesContaining(candidate, alohaId: alohaId) == 1 { return (candidate, 1) }
                }
            }
            return (ladder, count)
        }
        return (path, await selectorMatchCount(path))
    }

    /// How many elements `selector` matches on the live page, when the element `alohaId` is among
    /// them; nil when it is not, the selector does not parse, or the page cannot answer. The
    /// live-selector probe's own round trip (``LiveSelectorProbe``), its rebuild ignored.
    func liveMatchesContaining(_ selector: String, alohaId: String) async -> Int? {
        guard !selector.isEmpty, !alohaId.isEmpty,
              let value = try? await backend.evaluateViaCdp(LiveSelectorProbe.expression(selector: selector, alohaId: alohaId)),
              let json = value.stringValue, let reply = LiveSelectorProbe.parse(json), reply.contains,
              let matches = reply.matches, matches >= 1 else { return nil }
        return matches
    }
}

extension AnswerReceipt {
    /// At most this many receipt lines per answer, whatever ``maxValues`` is: llmdex folds no more
    /// than twelve into a run (`answerReceiptsKept`).
    public static let maxLines = 12
    /// Every line is SHORTER than this many Unicode scalars (Go runes): llmdex keeps the first 4000
    /// of an entry (`answerReceiptChars`) and would cut a longer line inside a bracket.
    public static let maxLineLength = 4000
    /// At most this many `:has(.class)` narrowings are tried per element (one page round trip each).
    static let maxNarrowings = 3

    static func fits(_ line: Line) -> Bool { line.text.unicodeScalars.count < maxLineLength }

    static func withoutAttributes(_ identity: ElementIdentity) -> ElementIdentity {
        var bare = ElementIdentity(index: identity.index, attributes: [])
        bare.list = identity.list
        bare.anchor = identity.anchor
        return bare
    }

    /// The selector ladder's pick for the element the matcher described (`tag`, `attrs`), or nil
    /// when nothing on it is stable. No position rung here: the matcher's live path is that.
    static func ladderSelector(item: JSValue) -> String? {
        guard let tag = item.string("tag"), !tag.isEmpty else { return nil }
        var attributes: [String: String] = [:]
        for (name, value) in item.object("attrs") ?? [] {
            if let value = value.stringValue { attributes[name] = value }
        }
        guard !attributes.isEmpty else { return nil }
        return stableCSSSelector(for: DomNode(id: "", element: DomElement(tagName: tag, attributes: attributes)))
    }

    /// `ladder:has(.c)` for the first stable class tokens found inside the element, in document
    /// order -- never one whose selector would contain the value read (`text`, 3+ characters).
    static func narrowed(_ ladder: String, insideClasses: [JSValue], text: String) -> [String] {
        let needle = text.count >= 3 ? text.lowercased() : nil
        var out: [String] = []
        for raw in insideClasses {
            guard let token = raw.stringValue else { continue }
            guard let stable = StepTraceSelector.stableClassTokens(token).first, stable == token else { continue }
            let candidate = ladder + ":has(." + stable + ")"
            if let needle, candidate.lowercased().contains(needle) { continue }
            if !out.contains(candidate) { out.append(candidate) }
            if out.count == maxNarrowings { break }
        }
        return out
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
