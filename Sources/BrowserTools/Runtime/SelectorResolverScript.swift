import Foundation

/// The page-side SELECTOR RESOLVER, embedded as a raw JS string so it can be installed on a page
/// verbatim through `Runtime.evaluate` and consulted by the receipt probes.
///
/// It is the resolution half of the agent's snips planner (AlohaBrowser/alohajet, branch
/// windows-on-snips, `SnipsExtractionScript.swift`), ported here so the receipts the page tools
/// write and the replays the agent runs resolve a selector the SAME way: an address a receipt
/// reports is verified with this resolver before it is written, and a scenario minted from that
/// receipt is replayed with it. The scenario machinery itself -- planning, running, settling,
/// reads, catalogs -- stays in the agent; nothing here acts on the page.
///
/// What it installs, under the stable `window.__snips` namespace the agent's scenarios already
/// address (the name is kept so a scenario minted before this port keeps working):
///
///   * `window.__snips.resolveAll(selector, root)` -- every element `selector` names under `root`
///     (the document when omitted), in document order unless a text ranking reordered them;
///   * `window.__snips.resolveFirst(selector, root)` -- the first of those, or null;
///   * `window.__snips.relHrefOf(el)` / `subPathOf(el)` -- the relative reference a link has to
///     the current page, for the anchor rule's rung 0;
///   * `window.__snips.indexPath(el)` / `resolvePath(path)` -- the child-index position path
///     helpers the planner's geometry step uses.
///
/// A selector is split into a CSS part and a chain of PROCEDURAL pseudo-classes (the uBlock
/// subset, clean-room), applied left to right to what `querySelectorAll` matched:
///
///   * `:has-text(t)` -- text containment, case-insensitive; a quoted `t` is a literal minted from
///     a receipt's `[text="…"]` and prefers whole-text equality, then whole-word, then a
///     whitespace-insensitive tier, then the element's own aria-label / title / placeholder /
///     value / alt / name; a `/re/flags` argument is a regex; empty text matches nothing;
///   * `:upward(n|sel)` -- the n-th ancestor, or `closest(sel)`;
///   * `:matches-attr(name=v)` -- the attribute exists, or its value contains `v` (or `/re/`);
///   * `:nth-match(n)` -- the n-th of what the chain matched so far, in document order;
///   * `:sub-path("/tail")` -- links to the current path followed by exactly `/tail` (kept for
///     scenarios minted before `:rel-href`);
///   * `:rel-href("ref")` -- links whose target is `ref` resolved against the current path taken
///     as a directory: `releases`, `..`, `../issues`, `?activeTab=versions`.
///
/// Any other `:name(` is ordinary CSS and goes to `querySelectorAll` as written. The one list of
/// these pseudos the server llmdex relies on is `RECEIPTS.md`; `receipt_registry.js` fails when
/// `PROC` below and that file disagree.
///
/// `Tests/BrowserToolsTests/selector_resolver.js` runs the bytes between the two markers against
/// fake documents under Node; `SelectorResolverScriptTests` compiles them under JavaScriptCore.
public enum SelectorResolverScript {

    /// The procedural pseudo-classes the resolver understands, in the order `PROC` lists them.
    /// Mirrored here so a Swift caller (and a Swift test) can name them without parsing the JS.
    public nonisolated static let pseudoClasses = ["has-text", "upward", "matches-attr", "nth-match", "sub-path", "rel-href"]

    /// Evaluates to `'installed'`, installing `window.__snips` when the page has no resolver yet.
    /// A second evaluation is a no-op: the source guards on `window.__snips.resolveAll`.
    public nonisolated static let installIfNeeded = source + "\n;'installed'"

    /// Evaluates to `'y'` when the resolver is on the page, `'n'` otherwise.
    public nonisolated static let isInstalledProbe =
        "typeof window !== 'undefined' && window.__snips && typeof window.__snips.resolveAll === 'function' ? 'y' : 'n'"

    // `source` is an immutable `String`, so it is `nonisolated`: under the package's
    // `defaultIsolation(MainActor.self)` an unannotated `static let` would be main-actor-isolated
    // and unreachable from the `@Sendable` page-evaluator closures that inject it.
    public nonisolated static let source = #"""
    // BEGIN selector-resolver js
    (function () {
      // The guard is on the RESOLVER, not on the namespace: a host that installs a fuller
      // `window.__snips` (the agent's planner) may already have put the namespace there, and a
      // namespace without `resolveAll` is one this script must still complete.
      if (typeof window !== 'undefined' && window.__snips && typeof window.__snips.resolveAll === 'function') return;
      const NS = (typeof window !== 'undefined' && window.__snips) ? window.__snips : {};
      if (typeof window !== 'undefined') window.__snips = NS;

      // ---- position path helpers ----

      function indexPath(el) {
        const path = [];
        let n = el;
        while (n && n.parentElement) {
          const sib = n.parentElement.children;
          let i = 0;
          for (; i < sib.length; i++) { if (sib[i] === n) break; }
          path.unshift(i);
          n = n.parentElement;
        }
        return path;
      }

      function resolvePath(path) {
        let n = document.documentElement;
        for (const i of path) {
          if (!n || !n.children || i >= n.children.length) return null;
          n = n.children[i];
        }
        return n;
      }

      NS.indexPath = function (el) { return indexPath(el); };
      NS.resolvePath = function (path) { return resolvePath(path); };

      // ---- Selector-recipe resolver (uBlock-style subset, clean-room) ----
      // Native :has()/:is()/:where()/:not() pass through to querySelectorAll; we add
      // procedural :has-text() / :upward() / :matches-attr() / :nth-match() / :sub-path() /
      // :rel-href() on top. RECEIPTS.md lists these; receipt_registry.js keeps the two in step.
      const PROC = ['has-text', 'upward', 'matches-attr', 'nth-match', 'sub-path', 'rel-href'];

      function splitProcedural(sel) {
        let pos = -1, depth = 0;
        for (let i = 0; i < sel.length; i++) {
          const c = sel[i];
          if (c === '(' || c === '[') depth++;
          else if (c === ')' || c === ']') depth--;
          else if (c === ':' && depth === 0) {
            const m = /^:([a-z-]+)\(/.exec(sel.slice(i));
            if (m && PROC.indexOf(m[1]) !== -1) { pos = i; break; }
          }
        }
        if (pos === -1) return { css: sel.trim() || '*', ops: [] };
        const css = sel.slice(0, pos).trim() || '*';
        const ops = [];
        let i = pos;
        while (i < sel.length) {
          const m = /^:([a-z-]+)\(/.exec(sel.slice(i));
          if (!m || PROC.indexOf(m[1]) === -1) break;
          let j = i + m[0].length, d = 1, arg = '';
          while (j < sel.length && d > 0) {
            if (sel[j] === '(') d++;
            else if (sel[j] === ')') { d--; if (d === 0) break; }
            if (d > 0) arg += sel[j];
            j++;
          }
          ops.push({ name: m[1], arg: arg.trim() });
          i = j + 1;
        }
        return { css: css, ops: ops };
      }

      // A quoted argument -- `:has-text("Dark mink")`, `:has-text('M')` -- names the text
      // INSIDE the quotes. Anchors are minted from receipts' `[text="..."]`, so the quoted
      // spelling is the normal one; uBlock's bare `:has-text(Dark mink)` and the regex form
      // stay as they are. One matching pair of outer quotes is removed and a backslash-escaped
      // quote or backslash inside is unescaped; anything else is left verbatim.
      function unquote(arg) {
        arg = String(arg == null ? '' : arg).trim();
        if (arg.length >= 2) {
          const q = arg[0];
          if ((q === '"' || q === "'") && arg[arg.length - 1] === q) {
            return arg.slice(1, -1).replace(/\\(["'\\])/g, '$1');
          }
        }
        return arg;
      }

      function textMatch(text, arg) {
        text = text || '';
        const rm = /^\/(.*)\/([a-z]*)$/.exec(arg);
        if (rm) { try { return new RegExp(rm[1], rm[2]).test(text); } catch (e) { return false; } }
        const needle = unquote(arg);
        // Empty text matches NOTHING (not everything): `:has-text("")` is a malformed anchor,
        // and a scenario must fail on it loudly rather than click the first element it finds.
        if (!needle) return false;
        return text.toLowerCase().indexOf(needle.toLowerCase()) !== -1;
      }

      function attrMatch(el, arg) {
        const eq = arg.indexOf('=');
        if (eq === -1) return el.hasAttribute(arg.trim());
        const name = arg.slice(0, eq).trim();
        const val = arg.slice(eq + 1).trim().replace(/^["']|["']$/g, '');
        const a = el.getAttribute(name);
        if (a == null) return false;
        const rm = /^\/(.*)\/([a-z]*)$/.exec(val);
        if (rm) { try { return new RegExp(rm[1], rm[2]).test(a); } catch (e) { return false; } }
        return a.indexOf(val) !== -1;
      }

      function upwardEl(el, arg) {
        if (/^[0-9]+$/.test(arg)) {
          let n = parseInt(arg, 10), e = el;
          while (n-- > 0 && e) e = e.parentElement;
          return e;
        }
        try { return el.closest(arg); } catch (e) { return null; }
      }

      // Was the argument written in quotes? A quoted anchor is a LITERAL minted from a
      // receipt's `[text="..."]`; it names the element whose text IS that, not any element
      // whose text happens to contain those letters.
      function quotedNeedle(arg) {
        var a = String(arg == null ? '' : arg).trim();
        if (a.length < 2) return null;
        var q = a[0];
        if ((q === '"' || q === "'") && a[a.length - 1] === q) return unquote(a);
        return null;
      }
      function normText(t) { return String(t == null ? '' : t).replace(/\s+/g, ' ').trim().toLowerCase(); }
      function escapeRe(s) { return String(s).replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); }

      // A QUOTED ANCHOR PREFERS THE WHOLE-TEXT MATCH. MEASURED (jacket-bag-luna-ge53): the size
      // step said :has-text("M"); size S was out of stock and its button read "SComing soon",
      // which contains an m; as the first visible substring match it was clicked, and the site
      // asked whether to notify about size S. Among the substring matches: the elements whose
      // normalised text EQUALS the anchor win; else those where the anchor stands as a whole
      // word ("BELTED FAUX SUEDE JACKET 219 GEL" for "BELTED FAUX SUEDE JACKET"); else all of
      // them, as before. Bare and regex arguments keep uBlock's substring semantics.
      function rankByAnchor(nodes, needle) {
        var want = normText(needle);
        if (!want) return nodes;
        var exact = nodes.filter(function (n) { return normText(n.textContent) === want; });
        if (exact.length) return exact;
        var word;
        try { word = new RegExp('(^|[^\\p{L}\\p{N}])' + escapeRe(want) + '($|[^\\p{L}\\p{N}])', 'iu'); }
        catch (e) { try { word = new RegExp('(^|\\W)' + escapeRe(want) + '($|\\W)', 'i'); } catch (e2) { return nodes; } }
        var whole = nodes.filter(function (n) { return word.test(normText(n.textContent)); });
        return whole.length ? whole : nodes;
      }

      // WHITESPACE IS NOT PART OF A LABEL. A receipt reads rendered text, where the browser
      // separates adjacent inline pieces with a space ("Search /": the word and a keyboard
      // hint); the resolver reads textContent, where nothing separates them ("Search/").
      // MEASURED (github-ss-r2, -r3): the step matched 0 twice while the same class selector
      // found the button for the agent both times. Reached ONLY when the plain text match
      // found nothing, so every anchor that matched before matches exactly as before. Tight
      // equality first; a tight substring only for anchors of three or more characters, so a
      // one-letter size never lands on "SComing soon".
      function tightText(t) { return normText(t).replace(/\s+/g, ''); }
      function matchIgnoringWhitespace(nodes, needle) {
        var want = tightText(needle);
        if (!want) return [];
        var exact = nodes.filter(function (n) { return tightText(n.textContent) === want; });
        if (exact.length) return exact;
        if (want.length < 3) return [];
        return nodes.filter(function (n) { return tightText(n.textContent).indexOf(want) !== -1; });
      }

      // WHAT THE ELEMENT SAYS ABOUT ITSELF WHEN IT HAS NO TEXT. An icon link or button has
      // no text; the receipt's `[text=…]` falls back to its aria-label / value / placeholder,
      // and `[attrs=…]` carries its title -- and the mint anchors on those words. MEASURED:
      // openstreetmap.org's Directions link (`title="Find directions between two points"`,
      // osm-form-r5, 2026-09-23) and Google Translate's "More target languages" (an
      // aria-label, gtranslate r2/r3, 2026-09-22) both matched 0 while the element was on the
      // page. Reached ONLY when every text tier found nothing: attribute equality first, then
      // containment for anchors of three or more characters.
      var ANCHOR_ATTRS = ['aria-label', 'title', 'placeholder', 'value', 'alt', 'name'];
      function matchByAttribute(nodes, needle) {
        var want = normText(needle);
        if (!want) return [];
        var exact = [], loose = [];
        nodes.forEach(function (n) {
          for (var i = 0; i < ANCHOR_ATTRS.length; i++) {
            var v = null;
            try { v = n.getAttribute ? n.getAttribute(ANCHOR_ATTRS[i]) : null; } catch (e) { v = null; }
            if (v == null || v === '') continue;
            var t = normText(String(v));
            if (t === want) { exact.push(n); return; }
            if (want.length >= 3 && t.indexOf(want) !== -1) { loose.push(n); return; }
          }
        });
        return exact.length ? exact : loose;
      }

      // THE SUB-PAGE OF WHEREVER THE RUN STANDS. A link from a page to one of its own sub-pages
      // -- a repo's Releases, a product's Reviews -- has an address no CSS can write without
      // naming the page it was recorded on: github-ss-r53 clicked
      // `href="https://github.com/MHSanaei/3x-ui/releases"`, and every replay whose search ranks
      // another repo first needs THAT repo's /releases. `:sub-path("/releases")` keeps the
      // elements whose link, resolved against this document, is on this origin and leads to
      // the CURRENT path followed by exactly that tail (query included, hash ignored). The
      // current path is the page's own, trailing slashes dropped; on the site root nothing is a
      // sub-page (a root-relative `a[href="/x"]` already says that). NS.subPathOf(el) gives the
      // tail the receipt anchor names, computed by this same function.
      function subPathOf(n) {
        var href = null;
        try { href = n && n.getAttribute ? n.getAttribute('href') : null; } catch (e) { href = null; }
        if (!href) return null;
        var u, here;
        try { u = new URL(href, document.baseURI || location.href); here = new URL(location.href); } catch (e) { return null; }
        if (u.origin !== here.origin) return null;
        var base = here.pathname.replace(/\/+$/, '');
        if (!base) return null;
        var path = u.pathname.replace(/\/+$/, '');
        if (path.indexOf(base + '/') !== 0 || path.length <= base.length + 1) return null;
        return path.slice(base.length) + u.search;
      }
      NS.subPathOf = function (el) { return subPathOf(el); };

      // A LINK RELATIVE TO WHEREVER THE RUN STANDS, in every direction: `:rel-href("<ref>")` keeps
      // the elements whose link leads to `<ref>` resolved against the CURRENT page's path taken as
      // a directory (RFC 3986 resolution, with the path ending in '/'). So `releases` is a sub-page,
      // `..` the page above, `../issues` a sibling under the same parent, `?activeTab=versions` the
      // same page with another query (npm's Versions tab). `:sub-path("/x")` is the special case
      // `:rel-href("x")`, kept for snips minted with it. Plain RFC resolution is not used: against
      // `/MHSanaei/3x-ui` it reads `releases` as `/MHSanaei/releases`. Hash ignored, trailing
      // slashes ignored, same origin only. NS.relHrefOf(el) gives the shortest such reference for
      // an element, or null when its link is not relative to this page (see relHrefOf).
      function linkKey(u) { return u.origin + u.pathname.replace(/\/+$/, '') + u.search; }
      function linkOf(n) {
        var href = null;
        try { href = n && n.getAttribute ? n.getAttribute('href') : null; } catch (e) { href = null; }
        if (!href) return null;
        try { return new URL(href, document.baseURI || location.href); } catch (e) { return null; }
      }
      function relTarget(ref) {
        try {
          var here = new URL(location.href);
          var dir = here.origin + here.pathname.replace(/\/*$/, '/');
          return new URL(ref, dir);
        } catch (e) { return null; }
      }
      function segmentsOf(path) { return path.split('/').filter(function (s) { return s !== ''; }); }
      // The reference, when the link is RELATIVE TO THIS PAGE: it shares at least one path segment
      // with it (or is the same path with another query), climbs at most two levels, and is no
      // longer than the link's own path. A link elsewhere on the site (a search result from
      // /search) is not relative to the page and keeps its ordinary address.
      function relHrefOf(n) {
        var u = linkOf(n), here;
        try { here = new URL(location.href); } catch (e) { return null; }
        if (!u || u.origin !== here.origin) return null;
        var B = segmentsOf(here.pathname), T = segmentsOf(u.pathname);
        if (!B.length) return null;
        var k = 0;
        while (k < B.length && k < T.length && B[k] === T[k]) k++;
        if (k === B.length && k === T.length) {
          return u.search && u.search !== here.search ? u.search : null;
        }
        if (k === 0) return null;
        var ups = B.length - k;
        if (ups > 2) return null;
        var parts = [];
        for (var i = 0; i < ups; i++) parts.push('..');
        parts = parts.concat(T.slice(k));
        if (parts.length > T.length) return null;
        return parts.join('/') + u.search;
      }
      NS.relHrefOf = function (el) { return relHrefOf(el); };

      function applyOp(op, nodes) {
        if (op.name === 'has-text') {
          var matched = nodes.filter(function (n) { return textMatch(n.textContent, op.arg); });
          var needle = quotedNeedle(op.arg);
          if (needle == null) return matched;
          if (matched.length) return rankByAnchor(matched, needle);
          var tight = matchIgnoringWhitespace(nodes, needle);
          if (tight.length) return tight;
          return matchByAttribute(nodes, needle);
        }
        if (op.name === 'matches-attr') return nodes.filter(function (n) { return attrMatch(n, op.arg); });
        // THE ORDINAL (a scenario step's `nth`, 1-based): the Nth of what the chain matched so
        // far, in DOCUMENT order (a `:has-text` ranking reorders; the ordinal does not follow
        // it). Fewer than N, or an N that is not a positive integer: nothing.
        if (op.name === 'nth-match') {
          var n = parseInt(String(op.arg).trim(), 10);
          if (!(n >= 1) || String(n) !== String(op.arg).trim()) return [];
          var ordered = nodes.slice();
          if (ordered.length > 1 && typeof ordered[0].compareDocumentPosition === 'function') {
            ordered.sort(function (a, b) { return (a.compareDocumentPosition(b) & 4) ? -1 : (b.compareDocumentPosition(a) & 4) ? 1 : 0; });
          }
          return ordered.length >= n ? [ordered[n - 1]] : [];
        }
        if (op.name === 'rel-href') {
          var ref = unquote(op.arg);
          if (!ref) return [];
          var target = relTarget(ref);
          if (!target || target.origin !== location.origin) return [];
          var want = linkKey(target);
          return nodes.filter(function (n) { var u = linkOf(n); return !!u && linkKey(u) === want; });
        }
        if (op.name === 'sub-path') {
          var tail = unquote(op.arg);
          if (!tail || tail.charAt(0) !== '/') return [];
          return nodes.filter(function (n) { return subPathOf(n) === tail; });
        }
        if (op.name === 'upward') {
          const out = [], seen = new Set();
          for (const n of nodes) { const u = upwardEl(n, op.arg); if (u && !seen.has(u)) { seen.add(u); out.push(u); } }
          return out;
        }
        return nodes;
      }

      NS.resolveAll = function (sel, root) {
        const sp = splitProcedural(sel);
        let nodes;
        try { nodes = Array.prototype.slice.call((root || document).querySelectorAll(sp.css)); }
        catch (e) { return []; }
        for (const op of sp.ops) nodes = applyOp(op, nodes);
        return nodes;
      };

      NS.resolveFirst = function (sel, root) {
        const all = NS.resolveAll(sel, root);
        return all.length ? all[0] : null;
      };
    })();
    // END selector-resolver js
    """#
}
