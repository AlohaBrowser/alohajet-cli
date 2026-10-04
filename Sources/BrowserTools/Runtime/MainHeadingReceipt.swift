import Foundation
import ToolABI

// MARK: - The page's main heading, named on a whole-page read

/// A whole-page `manage_tabs read` names no element, so a run that reads its ANSWER from the page
/// (a release name, a story title) leaves the mint no selector for the read step: it invented one
/// three times on 2026-09-23 and its own guard refused each (`h1` on Hacker News, `h1.d-flex span`
/// and `h1.d-inline.mr-3` on GitHub, agent runs github-ss-r25/r26). The read now also names the
/// page's main heading(s) in the receipt form every action carries: `[selector=…]
/// [source=main-heading] [matches=N] [index=i/N] [text="…"] [attrs=…]`, the selector from the SAME
/// ladder a click's comes from (``stableCSSSelector(for:)``), fed the tag, attributes and position
/// path the page reports.
///
/// Which headings: the visible `h1`s (at most ``maxHeadings``); failing that, the visible
/// `[role=heading][aria-level="1"]`; failing that, the first visible `h2`. Nothing visible, or
/// nothing the ladder can justify, adds nothing.
enum MainHeadingProbe {
    static let maxHeadings = 3
    static let maxTextLength = 80

    struct Heading: Equatable, Sendable {
        let tag: String
        /// Attributes in page order.
        let attributes: [(name: String, value: String)]
        /// The walker's position format: `/body/div[3]/h1`, an index only where same-tag siblings exist.
        let xpath: String
        let text: String

        static func == (a: Heading, b: Heading) -> Bool {
            a.tag == b.tag && a.xpath == b.xpath && a.text == b.text
                && a.attributes.map(\.name) == b.attributes.map(\.name) && a.attributes.map(\.value) == b.attributes.map(\.value)
        }
    }

    /// One page round trip. Plain JS, no interpolation: a harness can run these bytes
    /// (`Tests/BrowserToolsTests/main_heading.js`).
    static let expression = #"""
    (function () { /* receipt: main heading */
      var out = [];
      try {
        var vis = function (e) { try { var r = e.getBoundingClientRect(); return r.width > 0 && r.height > 0; } catch (x) { return false; } };
        var pick = function (sel, max) { var a = []; try { a = Array.prototype.slice.call(document.querySelectorAll(sel)).filter(vis); } catch (x) {} return a.slice(0, max); };
        var found = pick('h1', 3);
        if (!found.length) found = pick('[role="heading"][aria-level="1"]', 3);
        if (!found.length) found = pick('h2', 1);
        found.forEach(function (el) {
          var segs = [], ok = true;
          for (var n = el; n && n !== document.body; n = n.parentElement) {
            var t = String(n.tagName || '').toLowerCase();
            if (!/^[a-z][a-z0-9-]*$/.test(t)) { ok = false; break; }
            var p = n.parentElement, same = 0, pos = 0, kids = p ? p.children : [];
            for (var k = 0; k < kids.length; k++) if (kids[k].tagName === n.tagName) { same++; if (kids[k] === n) pos = same; }
            segs.unshift(same > 1 ? t + '[' + pos + ']' : t);
            if (!p) { ok = false; break; }
          }
          if (!ok) return;
          var names = el.getAttributeNames ? el.getAttributeNames() : [], attrs = [];
          for (var j = 0; j < names.length; j++) attrs.push([names[j], String(el.getAttribute(names[j]) == null ? '' : el.getAttribute(names[j]))]);
          var text = String(el.innerText || el.textContent || '').replace(/\s+/g, ' ').trim().slice(0, 80);
          out.push({ tag: String(el.tagName).toLowerCase(), attrs: attrs, xpath: '/body/' + segs.join('/'), text: text });
        });
      } catch (e) {}
      return JSON.stringify(out);
    })()
    """#

    static func parse(_ json: String) -> [Heading] {
        guard let value = JSValue.parse(json), case let .array(items) = value else { return [] }
        return items.prefix(maxHeadings).compactMap { item in
            guard let tag = item.string("tag"), !tag.isEmpty, let xpath = item.string("xpath"), xpath.hasPrefix("/body") else { return nil }
            var attributes: [(name: String, value: String)] = []
            if case let .array(pairs)? = item["attrs"] {
                for pair in pairs {
                    guard case let .array(kv) = pair, kv.count == 2, let n = kv[0].stringValue, !n.isEmpty, let v = kv[1].stringValue else { continue }
                    attributes.append((n, v))
                }
            }
            return Heading(tag: tag, attributes: attributes, xpath: xpath, text: String((item.string("text") ?? "").prefix(maxTextLength)))
        }
    }

    /// The durable selector for a heading, from the click ladder; nil when nothing justifies one.
    static func selector(for heading: Heading) -> String? {
        var map: [String: String] = [:]
        for a in heading.attributes where map[a.name] == nil { map[a.name] = a.value }
        return stableCSSSelector(for: DomNode(id: "", element: DomElement(tagName: heading.tag, attributes: map, xpath: heading.xpath)))
    }

    /// The attributes a receipt shows: the identity probe's filter (no class, style, aloha-id,
    /// tabindex or handlers; no `data:` values), capped the same way.
    static func receiptAttributes(_ heading: Heading) -> [ElementIdentity.Attribute] {
        var out: [ElementIdentity.Attribute] = []
        var total = 0
        for a in heading.attributes {
            let n = a.name.lowercased()
            if ["class", "style", "aloha-id", "tabindex"].contains(n) || n.hasPrefix("on") || a.value.hasPrefix("data:") { continue }
            var v = a.value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            if v.count > ReceiptIdentityProbe.maxValueLength { v = String(v.prefix(ReceiptIdentityProbe.maxValueLength - 3)) + "..." }
            total += a.name.count + v.count + 4
            if total > ReceiptIdentityProbe.maxTotalLength || out.count >= ReceiptIdentityProbe.maxAttributes { break }
            out.append(.init(name: a.name, value: v))
        }
        return out
    }

    /// The receipt line for the read: one heading per line, or "" when there is nothing to name.
    static func receiptLine(_ notes: [String]) -> String {
        let kept = notes.filter { !$0.isEmpty }
        guard !kept.isEmpty else { return "" }
        return "Main heading" + (kept.count > 1 ? "s" : "") + " on this page:" + kept.map { "\n-" + $0 }.joined()
    }
}

extension AgentBrowserBridge {
    /// The main-heading receipt line for a whole-page read (see ``MainHeadingProbe``), or "".
    func mainHeadingReceiptLine() async -> String {
        guard let json = await evaluateForReceipt(MainHeadingProbe.expression) else { return "" }
        var notes: [String] = []
        for heading in MainHeadingProbe.parse(json) {
            guard let selector = MainHeadingProbe.selector(for: heading) else { continue }
            let matches = await selectorMatchCount(selector)
            // Verified like every receipt's selector: the heading's place among the matches, or no
            // index at all -- and then `[index=none]` -- when the ladder's pick does not name it.
            var index: Int? = nil
            if let matches, matches >= 1 { index = await matchIndex(selector: selector, xpath: heading.xpath) }
            notes.append(PageToolReceipt.selectorNote(
                selector: selector, matches: matches, text: heading.text.isEmpty ? nil : heading.text,
                identity: ElementIdentity(index: index, attributes: MainHeadingProbe.receiptAttributes(heading)),
                source: "main-heading"))
        }
        return MainHeadingProbe.receiptLine(notes)
    }

    /// 1-based position of the element at `xpath` (walker format) among `selector`'s matches.
    func matchIndex(selector: String, xpath: String) async -> Int? {
        let script = """
        (function (s, x) { /* receipt: match index */
          try {
            var el = document.evaluate('/html' + x, document, null, XPathResult.FIRST_ORDERED_NODE_TYPE, null).singleNodeValue;
            if (!el) return -1;
            var all = document.querySelectorAll(s);
            for (var i = 0; i < all.length; i++) if (all[i] === el) return i + 1;
          } catch (e) {}
          return -1;
        })(\(JSValue.string(selector).stringify()), \(JSValue.string(xpath).stringify()))
        """
        guard let raw = await evaluateForReceipt(script), let n = Int(raw), n >= 1 else { return nil }
        return n
    }
}
