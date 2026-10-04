import Foundation
import ToolABI

// MARK: - `[anchor=…]`: one verified address per element, chosen by one rule

/// The address a scenario step should use for the element an action touched, chosen by ONE
/// rule and CHECKED on the live page with the replay's own resolver before it is reported.
///
/// Why: the mint chose addresses with ad-hoc choices, and got a different wrong one each time
/// (agent runs, 2026-09-23): the White swatch on H&M anchored on the product card's text "REGULAR
/// FIT T-SHIRT" (the swatch has no text; its receipt said `title="White"`), GitHub's Go filter and
/// H&M's size M as bare position paths that click whatever sits there when the list reorders,
/// and invented selectors its own guard then refused. The client has everything the choice
/// needs at receipt time -- the element, its label, its attributes, its list -- and, unlike the
/// server, the live page to test the choice on.
///
/// The rule, first candidate that resolves to EXACTLY this element wins:
///   0. a link RELATIVE TO the page it sits on: `<tag>:rel-href("<ref>")`, the ref resolved against
///      the current path as a directory -- `releases` (a sub-page: "the Releases of wherever we
///      are"; github-ss-r53's badge `href` named 3x-ui, so every other rung named 3x-ui too),
///      `..` (the page above), `../issues` (a sibling), `?activeTab=versions` (the same page,
///      another tab). Only for a link that shares path with the page. Every match leads to the
///      same place, so it wins when this element is AMONG its matches;
///   1. a stable selector (any ladder rung but the position path) on its own;
///   1b. `<tag>[aria-label="…"]`, then `<tag>[title="…"]` -- the element's own accessible name,
///      when it has no digit (the ladder cannot carry it: a `[selector]` holds no whitespace);
///   2. the `[list]` selector + `:has-text("<label>")`;
///   3. the `[list]` selector + `nth` (the element has no label that tells it apart);
///   4. the `[selector]` + `:has-text("<label>")`.
/// The label is the element's OWN: its text, else its aria-label / title / alt / placeholder --
/// never a neighbour's. A label with a digit ("98 comments", "$19.99") is never used for rules 2
/// and 4: it changes with the page's content, so the element is addressed by its list position.
/// For a READ (`get_text`) rules 2 and 4 are skipped: the element's text is the value being read,
/// and an address built from it names the answer (github-ss-r53: `…nav-list>ul>li>a:has-text("v3.8.5")`
/// for "the latest release name" breaks on the next release), and any candidate whose selector
/// CONTAINS the label (an href rung, a sub-path tail like `/tag/v3.8.5`) is dropped too; a read's
/// anchor is an answer-free selector or its place in its list. The check runs
/// `window.__snips.resolveAll` (``SelectorResolverScript``, installed on the page when absent), so
/// an anchor the receipt reports is one the replay's resolver picks.
///
/// `Tests/BrowserToolsTests/receipt_anchor.js` runs the shipped expression against the real
/// resolver on tree-shaped fake documents.
enum ReceiptAnchorProbe {
    static let maxLabelLength = 60

    struct Anchor: Equatable, Sendable {
        let selector: String
        let nth: Int?
        /// How many elements `selector` resolved to when it was verified (1 for an exact rung; all
        /// the links to the same place for rule 0). nil when the probe did not say.
        var count: Int? = nil
    }

    static func expression(alohaId: String, selector: String?, stable: Bool, list: String?, forRead: Bool = false) -> String {
        let idLiteral = JSValue.string(alohaId).stringify()
        let selLiteral = JSValue.string(selector ?? "").stringify()
        let listLiteral = JSValue.string(list ?? "").stringify()
        return #"""
        (function (id, sel, stable, list, forRead) { /* receipt: anchor */
          try {
            if (!window.__snips || !window.__snips.resolveAll) return '';
            var el = null, tagged = document.querySelectorAll('[aloha-id]');
            for (var k = 0; k < tagged.length; k++) if (tagged[k].getAttribute('aloha-id') === id) { el = tagged[k]; break; }
            if (!el) return '';
            var label = String(el.innerText || el.textContent || '').replace(/\s+/g, ' ').trim();
            if (!label) {
              var names = ['aria-label', 'title', 'alt', 'placeholder'];
              for (var n = 0; n < names.length && !label; n++) label = String(el.getAttribute(names[n]) || '').replace(/\s+/g, ' ').trim();
            }
            label = label.slice(0, \#(maxLabelLength));
            var quote = function (v) { return '"' + v.replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"'; };
            // A label with a DIGIT is not an address either: hn-swift-r74 clicked the top story's
            // "98 comments" and anchored on `:has-text("98 comments")`, which stops resolving at the
            // 99th comment. A count, a price, a version changes with the content; the element's place
            // in its list does not. Such a label skips the text rungs (2 and 4), like rung 1b skips
            // a digit-bearing aria-label, and the list + nth rung addresses it instead.
            var q = label && !forRead && !/[0-9]/.test(label) ? quote(label) : '';
            var cands = [];
            var rel = window.__snips.relHrefOf ? window.__snips.relHrefOf(el) : null;
            if (rel) cands.push({ s: String(el.tagName || 'a').toLowerCase() + ':rel-href(' + quote(rel) + ')', among: true });
            if (stable && sel) cands.push({ s: sel });
            // 1b. What the element SAYS it is: its aria-label, else its title -- written for people
            // and screen readers, so it outlives a redeploy that renames every class. The search
            // button's receipt carried `aria-label="Search or jump to, type / to search"` while its
            // anchor was built on `…___zQrEw` (github-ss, 2026-09-29). A value with a digit is
            // skipped (a count, a version, a date: it changes with the page's content).
            var tagName = String(el.tagName || '').toLowerCase();
            ['aria-label', 'title'].forEach(function (attr) {
              var v = String(el.getAttribute(attr) || '').replace(/\s+/g, ' ').trim();
              if (v && v.length <= 80 && !/[0-9]/.test(v) && tagName) cands.push({ s: tagName + '[' + attr + '=' + quote(v) + ']' });
            });
            if (list && q) cands.push({ s: list + ':has-text(' + q + ')' });
            if (list) {
              var members = [];
              try { members = Array.prototype.slice.call(document.querySelectorAll(list)); } catch (e) {}
              var at = members.indexOf(el);
              if (at >= 0) cands.push({ s: list, nth: at + 1 });
            }
            if (sel && q) cands.push({ s: sel + ':has-text(' + q + ')' });
            // A READ'S ADDRESS NEVER CARRIES WHAT IT READS: not as `:has-text` (skipped above), and
            // not inside an href, an id or a sub-path either (github-ss-r57 read the release title
            // `/releases/tag/v3.8.5` and rule 0 offered `a:sub-path("/tag/v3.8.5")`). A candidate
            // whose selector contains the element's own label (3+ characters, any case) is dropped.
            if (forRead && label.length >= 3) {
              var needle = label.toLowerCase();
              cands = cands.filter(function (cand) { return cand.s.toLowerCase().indexOf(needle) === -1; });
            }
            for (var c = 0; c < cands.length; c++) {
              var nodes = [];
              try { nodes = window.__snips.resolveAll(cands[c].s, document) || []; } catch (e) { nodes = []; }
              if (cands[c].nth) nodes = nodes.length >= cands[c].nth ? [nodes[cands[c].nth - 1]] : [];
              if (cands[c].among ? nodes.indexOf(el) !== -1 : (nodes.length === 1 && nodes[0] === el))
                return JSON.stringify({ s: cands[c].s, nth: cands[c].nth, n: nodes.length });
            }
          } catch (e) {}
          return '';
        })(\#(idLiteral), \#(selLiteral), \#(stable ? "true" : "false"), \#(listLiteral), \#(forRead ? "true" : "false"))
        """#
    }

    static func parse(_ json: String) -> Anchor? {
        guard !json.isEmpty, let value = JSValue.parse(json), case .object = value,
              let s = value.string("s"), !s.isEmpty else { return nil }
        let nth = value["nth"]?.intValue
        let count = value["n"]?.intValue
        return Anchor(selector: s, nth: (nth ?? 0) >= 1 ? nth : nil, count: (count ?? 0) >= 1 ? count : nil)
    }

    /// A selector the ladder produced from a position (rung 6) is not "stable" for rule 1.
    static func isStable(_ selector: String?) -> Bool {
        guard let selector, !selector.isEmpty else { return false }
        return !selector.hasPrefix("body>") && selector != "body"
    }
}

extension AgentBrowserBridge {
    /// Installs the replay's resolver (`window.__snips`, ``SelectorResolverScript``) on the page
    /// when absent; its own guard makes a second install a no-op.
    func ensureSelectorResolver() async {
        if await evaluateForReceipt(SelectorResolverScript.isInstalledProbe) != "y" {
            _ = await evaluateForReceipt(SelectorResolverScript.installIfNeeded)
        }
    }

    /// The verified anchor for an element (see ``ReceiptAnchorProbe``); nil when no candidate
    /// resolves to exactly it, or the page cannot be asked.
    func receiptAnchor(alohaId: String, selector: String?, list: String?, forRead: Bool = false) async -> ReceiptAnchorProbe.Anchor? {
        guard !alohaId.isEmpty, selector != nil || list != nil else { return nil }
        await ensureSelectorResolver()
        guard let json = await evaluateForReceipt(ReceiptAnchorProbe.expression(
            alohaId: alohaId, selector: selector, stable: ReceiptAnchorProbe.isStable(selector), list: list,
            forRead: forRead)) else { return nil }
        return ReceiptAnchorProbe.parse(json)
    }
}
