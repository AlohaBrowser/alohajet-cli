import Foundation
import ToolABI

// THE PROBES EVERY ACTION RECEIPT IS BUILT FROM: one page round trip each, read BEFORE the action
// (afterwards the node may be gone), and silent -- nil, never a guess -- when the page cannot
// answer. `PageToolReceipt.selectorNote` turns their answers into the bracket string the server
// side (llmdex) mints a replayable scenario from; `RECEIPTS.md` is the contract.
//
// Ported from AlohaBrowser/alohajet's `AlohaBridge` (branch windows-on-snips). Each probe keeps the
// run that measured the need for it in its own doc comment. The comment MARKERS inside the
// scripts (`/* receipt: … */`) are what the test browser (`MockCDP`) recognises a probe by, so
// that a probe's default answer there is "nothing found" rather than the page's body text.

extension AgentBrowserBridge {
    /// THE ELEMENT'S OWN TEXT, for the action receipt's `[text="…"]`. A mint anchoring a
    /// many-match selector needs the words that were actually on the element, not the words of
    /// the task: the card clicked on jacket-bag-luna-ge33 read "BELTED FAUX SUEDE JACKET", the
    /// minted anchor said 'FAUX SUEDE BELTED JACKET', and the replay matched nothing. Sixty
    /// characters of collapsed text, or the aria-label / value / placeholder when there is no text;
    /// nil when the element cannot be read.
    func elementText(alohaId: String) async -> String? {
        let escaped = alohaId.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        (function () { /* receipt: element text */
          try {
            var el = document.querySelector('[aloha-id="\(escaped)"]');
            if (!el) return "";
            var t = (el.innerText || el.textContent || "").replace(/\\s+/g, " ").trim();
            if (!t) t = el.getAttribute("aria-label") || el.getAttribute("value") || el.getAttribute("placeholder") || "";
            return String(t).slice(0, 60);
          } catch (e) { return ""; }
        })()
        """
        guard let value = try? await backend.evaluateViaCdp(script), let text = value.stringValue, !text.isEmpty
        else { return nil }
        return text
    }

    /// The element's identity for the receipt -- its index among the selector's matches, its real
    /// attributes and the repeating list it sits in -- in one round trip. nil when the page cannot
    /// answer.
    func elementIdentity(selector: String?, alohaId: String) async -> ElementIdentity? {
        guard !alohaId.isEmpty else { return nil }
        let script = ReceiptIdentityProbe.expression(selector: selector, alohaId: alohaId)
        guard let value = try? await backend.evaluateViaCdp(script), let json = value.stringValue else { return nil }
        return ReceiptIdentityProbe.parse(json)
    }

    /// The `aloha-id` of the element that has keyboard focus -- the one `pressKeys` will type
    /// into -- descending through shadow roots the way the focus probe in `type` does. Nil
    /// when nothing beyond the document itself has focus, when the focused element carries no
    /// aloha-id (the walker never stamped it), or when the page cannot be asked. For the
    /// `page_press_keys` receipt, read BEFORE the keys: a submit can replace the document.
    func focusedElementAlohaId() async -> String? {
        let script = """
        (function () { /* receipt: focused element */
          try {
            var el = document.activeElement;
            while (el && el.shadowRoot && el.shadowRoot.activeElement) el = el.shadowRoot.activeElement;
            if (!el || el === document.body || el === document.documentElement) return "";
            return String(el.getAttribute("aloha-id") || "");
          } catch (e) { return ""; }
        })()
        """
        guard let value = try? await backend.evaluateViaCdp(script), let id = value.stringValue, !id.isEmpty
        else { return nil }
        return id
    }

    /// Evaluates a READ-ONLY receipt probe and returns its answer as a string (a number reply as
    /// its decimal form); nil when the page cannot answer. For probes defined outside this file
    /// (``MainHeadingProbe``), which cannot reach the backend directly.
    func evaluateForReceipt(_ expression: String) async -> String? {
        guard let value = try? await backend.evaluateViaCdp(expression) else { return nil }
        if let s = value.stringValue { return s }
        if let n = value.intValue { return String(n) }
        return nil
    }

    /// HOW MANY ELEMENTS A SELECTOR MATCHES on the live page right now, for the action receipt's
    /// `[matches=N]`. A mint that turns a run into a saved automation needs to know whether the
    /// durable selector it is about to keep names one element or sixty (`a.product-link._item`
    /// on a results page), and until this rode along it had to ask that of every click. One
    /// `querySelectorAll` in the top document; nil when the page cannot answer or the selector
    /// does not parse, and then the receipt says nothing rather than guessing.
    func selectorMatchCount(_ selector: String?) async -> Int? {
        guard let selector, !selector.isEmpty else { return nil }
        let literal = JSValue.string(selector).stringify()
        let script = """
        (function (s) { /* receipt: match count */
          try { return document.querySelectorAll(s).length; } catch (e) { return -1; }
        })(\(literal))
        """
        guard let value = try? await backend.evaluateViaCdp(script), let count = value.intValue, count >= 0
        else { return nil }
        return count
    }

    /// The receipt's selector, with a DEAD position path rebuilt from the live page.
    ///
    /// The ladder's position path comes from the page snapshot the agent last read, and a page
    /// that keeps rendering after that moves it: github.com inserted a `div` above its header after
    /// the read, so the search button's `body>div:nth-of-type(1)>div:nth-of-type(4)>…>button` matched
    /// nothing at click time (github-ss-r75, `[matches=0]`) while the live element sat under
    /// `div:nth-of-type(5)`. Only a position path (`body>…`) that matches NOTHING right now is
    /// rebuilt: from the element itself, found by its aloha-id, one segment per ancestor
    /// (`:nth-of-type` only where the parent has several of that tag, as the ladder writes it),
    /// and kept only if it resolves to that element. Any other selector, a path that still
    /// matches, or one that cannot be rebuilt comes back unchanged.
    func liveSelector(_ selector: String?, alohaId: String) async -> String? {
        guard let selector, selector == "body" || selector.hasPrefix("body>"), !alohaId.isEmpty else { return selector }
        guard await selectorMatchCount(selector) == 0 else { return selector }
        let idLiteral = JSValue.string(alohaId).stringify()
        let script = """
        (function (id) { /* receipt: live selector */
          try {
            var el = null, tagged = document.querySelectorAll('[aloha-id]');
            for (var k = 0; k < tagged.length; k++) if (tagged[k].getAttribute('aloha-id') === id) { el = tagged[k]; break; }
            if (!el || !document.body || !document.body.contains(el)) return "";
            var segs = [];
            for (var n = el; n && n !== document.body; n = n.parentElement) {
              var p = n.parentElement;
              if (!p) return "";
              var tag = String(n.tagName || '').toLowerCase();
              if (!/^[a-z][a-z0-9-]*$/.test(tag)) return "";
              var same = 0, at = 0;
              for (var c = p.firstElementChild; c; c = c.nextElementSibling) {
                if (c.tagName === n.tagName) { same++; if (c === n) at = same; }
              }
              segs.unshift(same > 1 ? tag + ':nth-of-type(' + at + ')' : tag);
              if (segs.length > \(StepTraceSelector.maxPathSegments)) return "";
            }
            var path = ['body'].concat(segs).join('>');
            var hits = document.querySelectorAll(path);
            for (var h = 0; h < hits.length; h++) if (hits[h] === el) return path;
            return "";
          } catch (e) { return ""; }
        })(\(idLiteral))
        """
        guard let value = try? await backend.evaluateViaCdp(script), let path = value.stringValue, !path.isEmpty
        else { return selector }
        return path
    }
}
