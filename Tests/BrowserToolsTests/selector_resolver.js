// Runs the page-side SELECTOR RESOLVER (`SelectorResolverScript.source`: `splitProcedural` /
// `textMatch` / `applyOp` / `window.__snips.resolveAll`) against fake documents, with the
// procedural pseudo-classes a receipt anchor or a replayed scenario actually carries. The source
// is EXTRACTED from the Swift file by its BEGIN/END markers, so this exercises the bytes that
// ship rather than a copy that can drift. Run with:  node Tests/BrowserToolsTests/selector_resolver.js
//
// The case that motivated the quoted-text rule (agent run jacket-bag-luna-ge38, 2026-09-21): the
// served scenario said `button.product-detail-color-item__color-button:has-text("Dark mink")`; the
// button was on the page, visible, text "Dark mink" -- and the resolver answered 0, because the
// argument was compared WITH its quotes. Anchors are minted from receipts' `[text="…"]`, so quoted
// text is the normal shape, not an edge case. The later cases each name the run that measured them.
const fs = require('fs');
const path = require('path');

const swift = fs.readFileSync(path.join(__dirname, '..', '..', 'Sources', 'BrowserTools', 'Runtime', 'SelectorResolverScript.swift'), 'utf8');
const begin = swift.indexOf('// BEGIN selector-resolver js');
const end = swift.indexOf('// END selector-resolver js');
if (begin < 0 || end < 0) { console.error('markers not found in SelectorResolverScript.swift'); process.exit(2); }
// A RAW Swift literal (`#"""`), so the bytes between the markers are the bytes the page gets.
const source = swift.slice(begin, end);

// The script reads `window`, `document` and `location` as globals, the way a page provides them.
// `installAt(url)` evaluates the shipped bytes against a fresh fake window standing at `url`.
function installAt(url, existing) {
  const window = existing ? { __snips: existing } : {};
  globalThis.location = new URL(url);
  globalThis.document = { baseURI: url };
  new Function('window', source)(window);
  return window.__snips;
}
let NS = installAt('https://site.example/');
function at(url) { globalThis.location = new URL(url); globalThis.document = { baseURI: url }; }

let failures = 0;
function check(name, cond, detail) { console.log((cond ? 'ok   ' : 'FAIL ') + name + (cond ? '' : '  ' + JSON.stringify(detail))); if (!cond) failures++; }
const texts = ns => ns.map(e => e.textContent);

// ---- install contract ---------------------------------------------------------------------
check('installs resolveAll, resolveFirst, relHrefOf, subPathOf, indexPath, resolvePath',
  ['resolveAll', 'resolveFirst', 'relHrefOf', 'subPathOf', 'indexPath', 'resolvePath'].every(k => typeof NS[k] === 'function'));
{
  // A second evaluation leaves the installed resolver alone.
  const window = { __snips: NS };
  new Function('window', source)(window);
  check('a second install is a no-op', window.__snips === NS);
  // A namespace a host put there WITHOUT a resolver is completed, not replaced (the agent's
  // planner keeps its `plan` / `run` on the same object).
  const host = { plan: () => 'planned' };
  const completed = installAt('https://site.example/', host);
  check('an existing namespace without resolveAll is completed in place', completed === host && typeof host.resolveAll === 'function' && host.plan() === 'planned');
  NS = installAt('https://site.example/');
}

// ---- flat fake DOM: `tag.cls1.cls2` / `.cls` / `tag` / `*`, comma lists, NOTHING procedural ----
function el(tag, { cls = '', text = '', attrs = {}, parent = null } = {}) {
  const e = { tagName: tag.toUpperCase(), className: cls, textContent: text, parentElement: parent,
              hasAttribute: k => k in attrs, getAttribute: k => (k in attrs ? attrs[k] : null),
              closest: q => { let n = e; while (n) { if (matches(n, q)) return n; n = n.parentElement; } return null; } };
  return e;
}
function matches(e, q) {
  q = q.trim(); if (q === '*') return true;
  const m = /^([a-z]*)((?:\.[\w-]+)*)$/.exec(q); if (!m) throw new Error('fake engine cannot parse ' + q);
  if (m[1] && e.tagName.toLowerCase() !== m[1]) return false;
  return m[2].split('.').filter(Boolean).every(c => e.className.split(/\s+/).includes(c));
}
function makeDoc(els) { return { querySelectorAll(q) { return els.filter(e => q.split(',').some(p => matches(e, p))); } }; }

const wrap = el('div', { cls: 'product-detail-color-item' });
const camel = el('button', { cls: 'product-detail-color-item__color-button product-detail-color-item__color-button--is-selected', text: 'Dark camel', parent: wrap });
const mink = el('button', { cls: 'product-detail-color-item__color-button', text: 'Dark mink', parent: wrap });
const sizeM = el('button', { cls: 'size-selector-sizes-size__button', text: 'M', attrs: { 'data-qa-action': 'size-in-stock' } });
const sizeS = el('button', { cls: 'size-selector-sizes-size__button', text: 'S' });
const add = el('button', { cls: 'zds-button product-detail-cart-buttons__button', text: 'ADD' });
const search = el('a', { cls: 'layout-header-action-search', text: ' Search ' });
const doc = makeDoc([wrap, camel, mink, sizeM, sizeS, add, search]);
const q = 'button.product-detail-color-item__color-button';

// 1. the minted shape: double-quoted text
check('has-text("Dark mink") resolves the one button', texts(NS.resolveAll(q + ':has-text("Dark mink")', doc)).join() === 'Dark mink', texts(NS.resolveAll(q + ':has-text("Dark mink")', doc)));
check('resolveFirst gives that button', NS.resolveFirst(q + ':has-text("Dark mink")', doc) === mink && NS.resolveFirst(q + ':has-text("Nope")', doc) === null);
// 2. single quotes (the earlier mint spelled them this way)
check("has-text('Dark mink') too", texts(NS.resolveAll(q + ":has-text('Dark mink')", doc)).join() === 'Dark mink');
// 3. uBlock's bare form still works
check('has-text(Dark mink) bare', texts(NS.resolveAll(q + ':has-text(Dark mink)', doc)).join() === 'Dark mink');
// 4. case-insensitive, substring (`M` is inside `Dark mink` for the colour class, but the size class narrows it)
check('has-text("m") on the size buttons gives M only', texts(NS.resolveAll('button.size-selector-sizes-size__button:has-text("m")', doc)).join() === 'M');
// 5. a quote INSIDE the text is not an outer quote
check('has-text("it\'s") keeps the inner quote', NS.resolveAll(q + ':has-text("it\'s")', doc).length === 0 && NS.resolveAll('a:has-text("earch")', doc).length === 1);
// 6. regex form untouched
check('has-text(/^dark (mink|camel)$/i) matches both', NS.resolveAll(q + ':has-text(/^dark (mink|camel)$/i)', doc).length === 2);
// 7. quoted text with an escaped inner double quote
const quoted = el('button', { cls: 'zds-button', text: 'Say "hi"' });
check('has-text("Say \\"hi\\"") unescapes', NS.resolveAll('button.zds-button:has-text("Say \\"hi\\"")', makeDoc([quoted, add])).length === 1);
// 8. matches-attr with a quoted value
check('matches-attr(data-qa-action="size-in-stock")', NS.resolveAll('button.size-selector-sizes-size__button:matches-attr(data-qa-action="size-in-stock")', doc).length === 1);
check('matches-attr(name) alone tests presence', NS.resolveAll('button:matches-attr(data-qa-action)', doc).length === 1);
// 9. upward with a css argument, and with a number
check('upward(div.product-detail-color-item)', NS.resolveAll(q + ':has-text("Dark mink"):upward(div.product-detail-color-item)', doc)[0] === wrap);
check('upward(1) is the parent, deduplicated across matches', NS.resolveAll(q + ':upward(1)', doc).length === 1 && NS.resolveAll(q + ':upward(1)', doc)[0] === wrap);
// 10. a lone quote pair is NOT stripped to an empty match-everything
check('has-text("") matches nothing rather than everything', NS.resolveAll(q + ':has-text("")', doc).length === 0);
// 11. no procedural part: plain css passes through; an unparsable selector is an empty answer
check('plain css', NS.resolveAll(q, doc).length === 2);
check('an unparsable css part answers [] rather than throwing', NS.resolveAll('button[', doc).length === 0);
// A native pseudo with parentheses is NOT procedural: it reaches querySelectorAll as written.
check('an unknown :name( is ordinary css', (() => { let seen = null; NS.resolveAll('li:nth-of-type(2):has-text("x")', { querySelectorAll(s) { seen = s; return []; } }); return seen === 'li:nth-of-type(2)'; })());

// 12. THE SIZE-S SHAPE (run jacket-bag-luna-ge53, 2026-09-21): size S is out of stock and reads
//     "SComing soon" -- which contains an m. A quoted :has-text("M") must pick the button whose
//     whole text is M, not the first substring match.
const sOut = el('button', { cls: 'size-selector-sizes-size__button', text: 'SComing soon' });
const mIn = el('button', { cls: 'size-selector-sizes-size__button', text: 'M' });
const lIn = el('button', { cls: 'size-selector-sizes-size__button', text: 'L' });
const sizesDoc = makeDoc([sOut, mIn, lIn]);
check('quoted "M" picks the M button, not "SComing soon"', texts(NS.resolveAll('button.size-selector-sizes-size__button:has-text("M")', sizesDoc)).join() === 'M');
check('quoted "m" is case-insensitive and still exact-first', texts(NS.resolveAll('button.size-selector-sizes-size__button:has-text("m")', sizesDoc)).join() === 'M');
check('quoted "Coming soon" finds S by whole-word match', texts(NS.resolveAll('button.size-selector-sizes-size__button:has-text("Coming soon")', sizesDoc)).join() === 'SComing soon');
check('bare has-text(M) keeps uBlock substring semantics (both)', NS.resolveAll('button.size-selector-sizes-size__button:has-text(M)', sizesDoc).length === 2);
// 13. whole-word beats substring when there is no exact match: a card's text carries its price.
const card1 = el('a', { cls: 'product-link _item', text: 'BELTED FAUX SUEDE JACKET 219 GEL' });
const card2 = el('a', { cls: 'product-link _item', text: 'BELTED FAUX SUEDE JACKETS COLLECTION 99 GEL' });
check('whole-word match wins over a longer word containing the anchor', texts(NS.resolveAll('a.product-link._item:has-text("BELTED FAUX SUEDE JACKET")', makeDoc([card2, card1]))).join() === 'BELTED FAUX SUEDE JACKET 219 GEL');
// 14. nothing exact, nothing whole-word: the substring matches are kept, as before.
check('substring fallback is unchanged', NS.resolveAll('a.product-link._item:has-text("JACKET")', makeDoc([card2])).length === 1);

// 15. THE GITHUB SHAPE (runs github-ss-r2/-r3, 2026-09-22): the anchor was minted from rendered
//     text "Search /" (a word and a keyboard hint, space between them); textContent is "Search/".
const searchKbd = el('button', { cls: 'hdr-btn', text: 'Search/' });
const signIn = el('a', { cls: 'hdr-btn', text: 'Sign in' });
const searchPlain = el('button', { cls: 'hdr-btn', text: 'Search' });
check('quoted "Search /" resolves the button whose text is "Search/"', texts(NS.resolveAll('.hdr-btn:has-text("Search /")', makeDoc([signIn, searchKbd]))).join() === 'Search/');
check('… and never the plain "Search" button when the kbd one is present', texts(NS.resolveAll('.hdr-btn:has-text("Search /")', makeDoc([searchPlain, searchKbd]))).join() === 'Search/');
// 16. the tight tiers are a FALLBACK: when the plain match finds something, nothing changes.
const ab = el('div', { cls: 'x', text: 'a b' }); const tab = el('div', { cls: 'x', text: 'tab' });
check('a plain match wins and the tight tier is never consulted', texts(NS.resolveAll('.x:has-text("a b")', makeDoc([tab, ab]))).join() === 'a b');
// 17. tight substring for anchors of three or more characters
check('tight substring fallback ("Add to bag" in "Addto bag now")', texts(NS.resolveAll('.x:has-text("Add to bag")', makeDoc([el('div', { cls: 'x', text: 'Addto bag now' })]))).join() === 'Addto bag now');
// 18. the tight-substring fallback needs three characters; tight EQUALITY has no minimum.
check('tight equality works for a short anchor ("S L" ~ "SL")', texts(NS.resolveAll('.x:has-text("S L")', makeDoc([el('div', { cls: 'x', text: 'SL' }), el('div', { cls: 'x', text: 'XSLY' })]))).join() === 'SL');
check('tight substring is refused for a short anchor ("S L" in "XSLY")', NS.resolveAll('.x:has-text("S L")', makeDoc([el('div', { cls: 'x', text: 'XSLY' })])).length === 0);
check('no match at all stays no match', NS.resolveAll('.x:has-text("M")', makeDoc([el('div', { cls: 'x', text: 'S' }), el('div', { cls: 'x', text: 'L' })])).length === 0);
// 19. bare (unquoted) arguments keep uBlock's exact substring semantics
check('bare has-text(Search /) is unchanged (no whitespace tier)', NS.resolveAll('.hdr-btn:has-text(Search /)', makeDoc([searchKbd])).length === 0);

// 20. THE OSM DIRECTIONS LINK (osm-form-r5, 2026-09-23): an icon link with no text and a title.
const dirLink = el('a', { cls: 'nav-link', text: '', attrs: { href: '/directions', title: 'Find directions between two points' } });
const histLink = el('a', { cls: 'nav-link', text: 'History', attrs: { href: '/history' } });
check('a text anchor matches the element\'s title when it has no text', NS.resolveAll('a.nav-link:has-text("Find directions between two points")', makeDoc([histLink, dirLink])).length === 1 && NS.resolveAll('a.nav-link:has-text("Find directions between two points")', makeDoc([histLink, dirLink]))[0] === dirLink);
// 21. THE GOOGLE TRANSLATE SHAPE (gtranslate r2/r3, 2026-09-22): an aria-label on a textless button.
const moreBtn = el('button', { cls: 'tl', text: '', attrs: { 'aria-label': 'More target languages' } });
const frBtn = el('button', { cls: 'tl', text: 'French' });
check('a text anchor matches an aria-label when the element has no text', NS.resolveAll('button.tl:has-text("More target languages")', makeDoc([frBtn, moreBtn]))[0] === moreBtn);
check('… case-insensitively', NS.resolveAll('button.tl:has-text("more target languages")', makeDoc([frBtn, moreBtn]))[0] === moreBtn);
// 22. TEXT WINS. When any element's text matches, attributes are never consulted.
const saveText = el('button', { cls: 'act', text: 'Save' });
const saveAria = el('button', { cls: 'act', text: 'Store', attrs: { 'aria-label': 'Save' } });
check('the attribute tier is not reached when a text match exists', texts(NS.resolveAll('button.act:has-text("Save")', makeDoc([saveAria, saveText]))).join() === 'Save');
// 23. Attribute equality beats containment; a short anchor never matches by containment.
const closeX = el('button', { cls: 'ic', text: '', attrs: { 'aria-label': 'Close' } });
const closeAll = el('button', { cls: 'ic', text: '', attrs: { 'aria-label': 'Close all tabs' } });
check('attribute equality wins over containment', NS.resolveAll('button.ic:has-text("Close")', makeDoc([closeAll, closeX])).length === 1 && NS.resolveAll('button.ic:has-text("Close")', makeDoc([closeAll, closeX]))[0] === closeX);
check('containment works for a longer anchor', NS.resolveAll('button.ic:has-text("all tabs")', makeDoc([closeAll, closeX]))[0] === closeAll);
check('a two-character anchor never matches an attribute by containment', NS.resolveAll('button.ic:has-text("al")', makeDoc([closeAll, closeX])).length === 0);
// Every attribute of the tier: placeholder, value, alt, name.
check('placeholder / value / alt / name are anchor attributes too',
  NS.resolveAll('input:has-text("Search GitHub")', makeDoc([el('input', { attrs: { placeholder: 'Search GitHub' } })])).length === 1
  && NS.resolveAll('input:has-text("Go")', makeDoc([el('input', { attrs: { value: 'Go' } })])).length === 1
  && NS.resolveAll('img:has-text("Logo")', makeDoc([el('img', { attrs: { alt: 'Logo' } })])).length === 1
  && NS.resolveAll('input:has-text("q")', makeDoc([el('input', { attrs: { name: 'q' } })])).length === 1);
// 24. Nothing anywhere: still no match.
check('no text, no attribute: no match', NS.resolveAll('button.ic:has-text("Open")', makeDoc([closeAll, closeX])).length === 0);

// 25. `:nth-match(N)` -- a scenario step's `nth`: the Nth of what the chain matched, 1-based,
//     after the other ops; fewer than N -> nothing.
const r1 = el('a', { cls: 'result', text: 'first' }), r2 = el('a', { cls: 'result', text: 'second' }), r3 = el('a', { cls: 'result', text: 'third' });
const resDoc = makeDoc([r1, r2, r3]);
check('nth-match(1) is the first match', NS.resolveAll('a.result:nth-match(1)', resDoc)[0] === r1 && NS.resolveAll('a.result:nth-match(1)', resDoc).length === 1);
check('nth-match(3) is the third match', NS.resolveAll('a.result:nth-match(3)', resDoc)[0] === r3);
check('nth-match beyond the count matches nothing', NS.resolveAll('a.result:nth-match(4)', resDoc).length === 0);
check('nth-match(0) and non-integers match nothing', NS.resolveAll('a.result:nth-match(0)', resDoc).length === 0 && NS.resolveAll('a.result:nth-match(1.5)', resDoc).length === 0 && NS.resolveAll('a.result:nth-match(x)', resDoc).length === 0);
const h1a = el('a', { cls: 'result', text: 'Go' }), h1b = el('a', { cls: 'result', text: 'Go tools' }), h1c = el('a', { cls: 'result', text: 'Rust' });
check('nth-match applies after has-text (regex keeps every match)', NS.resolveAll('a.result:has-text(/go/i):nth-match(2)', makeDoc([h1a, h1b, h1c]))[0] === h1b);
// A QUOTED anchor narrows to its best tier first (exact text beats substring), so the ordinal
// counts within that tier: "Go" exact is one element, and nth-match(2) finds nothing.
check('a quoted anchor narrows before the ordinal counts', NS.resolveAll('a.result:has-text("Go"):nth-match(1)', makeDoc([h1a, h1b, h1c]))[0] === h1a && NS.resolveAll('a.result:has-text("Go"):nth-match(2)', makeDoc([h1a, h1b, h1c])).length === 0);
// The ordinal follows DOCUMENT order, not the ranking: with compareDocumentPosition available, a
// has-text ranking that moved an element first does not make it nth-match(1).
{
  const order = [];
  const mk = (t) => { const e = el('a', { cls: 'r', text: t }); order.push(e); e.compareDocumentPosition = o => (order.indexOf(o) > order.indexOf(e) ? 4 : 2); return e; };
  const first = mk('Go tools'), second = mk('Go');
  const ranked = NS.resolveAll('a.r:has-text("Go")', makeDoc([first, second]));
  check('ranking puts the exact match first', ranked[0] === second);
  check('nth-match counts in document order, not ranked order', NS.resolveAll('a.r:has-text(/go/i):nth-match(1)', makeDoc([second, first]))[0] === first);
}

// ---- links relative to the page: `:sub-path`, `:rel-href`, relHrefOf, subPathOf -------------
const link = (href, id, cls = 'l') => el('a', { cls, attrs: { href, 'aloha-id': id } });
const ids = (sel, d) => NS.resolveAll(sel, d).map(e => e.getAttribute('aloha-id'));
// 26. github-ss-r53's Releases badge (absolute href), the sidebar link to the same place, another
//     repo's releases link in the same README, and a deeper sub-page.
{
  const badge = link('https://github.com/MHSanaei/3x-ui/releases', 'badge');
  const other = link('https://github.com/XTLS/Xray-core/releases', 'other');
  const side = link('/MHSanaei/3x-ui/releases', 'side');
  const latest = link('/MHSanaei/3x-ui/releases/latest', 'latest');
  const d = makeDoc([other, badge, side, latest]);
  at('https://github.com/MHSanaei/3x-ui');
  check("sub-path matches this repo's releases links only", JSON.stringify(ids('a:sub-path("/releases")', d)) === '["badge","side"]', ids('a:sub-path("/releases")', d));
  check('rel-href("releases") matches the same two', JSON.stringify(ids('a:rel-href("releases")', d)) === '["badge","side"]', ids('a:rel-href("releases")', d));
  check('relHrefOf gives the shortest reference', NS.relHrefOf(badge) === 'releases' && NS.relHrefOf(latest) === 'releases/latest' && NS.relHrefOf(other) === null);
  check('subPathOf gives the tail', NS.subPathOf(side) === '/releases' && NS.subPathOf(latest) === '/releases/latest' && NS.subPathOf(other) === null);
  // The SAME address on ANOTHER repo's page resolves to that repo's releases.
  at('https://github.com/v2ray/v2ray-core');
  const d2 = makeDoc([link('/v2ray/v2ray-core/releases', 'v')]);
  check('same address on another repo: its own releases', JSON.stringify(ids('a:sub-path("/releases")', d2)) === '["v"]' && JSON.stringify(ids('a:rel-href("releases")', d2)) === '["v"]');
}
// 27. `:sub-path` edges: the site root has no sub-pages, another origin never matches, the query
//     is part of the tail, a trailing slash is ignored, an unquoted tail matches nothing.
{
  const d = makeDoc([link('/x', 'root'), link('https://evil.example/repo/releases', 'evil'), link('/repo/issues?q=open', 'q'), link('/repo/releases/', 'slash')]);
  at('https://site.example/');
  check('site root: nothing is a sub-page', ids('a:sub-path("/x")', d).length === 0);
  at('https://site.example/repo');
  check('another origin never matches; trailing slash ignored', ids('a:sub-path("/releases")', d).join() === 'slash');
  at('https://site.example/repo/');
  check('the query is part of the tail', ids('a:sub-path("/issues?q=open")', d).join() === 'q');
  at('https://site.example/repo');
  check('an unquoted tail matches nothing', ids('a:sub-path(releases)', d).length === 0);
}
// 28. `:rel-href` IN EVERY DIRECTION from the current page, and never for a link elsewhere.
{
  // npm: the same page, another tab (a query).
  at('https://www.npmjs.com/package/left-pad');
  const npm = makeDoc([link('/package/left-pad?activeTab=readme', 'readme'), link('/package/left-pad?activeTab=versions', 'ver')]);
  check('same page, another query: rel-href("?activeTab=versions")', ids('a:rel-href("?activeTab=versions")', npm).join() === 'ver');
  check('relHrefOf of the other tab is its query', NS.relHrefOf(npm.querySelectorAll('a')[1]) === '?activeTab=versions');
  check('relHrefOf of a link to the page itself is null', NS.relHrefOf(link('/package/left-pad', 'self')) === null);
  // Up a level, and a sibling under the same parent.
  at('https://github.com/MHSanaei/3x-ui/pulls');
  const repo = makeDoc([link('/MHSanaei/3x-ui', 'up'), link('/MHSanaei/3x-ui/issues', 'sib')]);
  check('the page above: rel-href("..")', ids('a:rel-href("..")', repo).join() === 'up' && NS.relHrefOf(repo.querySelectorAll('a')[0]) === '..');
  check('a sibling: rel-href("../issues")', ids('a:rel-href("../issues")', repo).join() === 'sib' && NS.relHrefOf(repo.querySelectorAll('a')[1]) === '../issues');
  // A search result is not relative to /search: it shares no path segment.
  at('https://github.com/search?q=shadowsocks');
  check('a link elsewhere on the site is not relative (relHrefOf null)', NS.relHrefOf(link('/MHSanaei/3x-ui', 'top')) === null);
  // The same references from ANOTHER repo's pages lead to that repo's pages.
  at('https://github.com/v2ray/v2ray-core/pulls');
  const other = makeDoc([link('/v2ray/v2ray-core', 'c'), link('/v2ray/v2ray-core/issues', 'i'), link('/MHSanaei/3x-ui/issues', 'x')]);
  check('".." from another repo is that repo', ids('a:rel-href("..")', other).join() === 'c');
  check('"../issues" from another repo is that repo\'s issues', ids('a:rel-href("../issues")', other).join() === 'i');
  // Three levels up is not relative any more; two is.
  at('https://site.example/a/b/c/d');
  check('climbing more than two levels is not rel-href', NS.relHrefOf(link('/a/x', 'far')) === null);
  check('two levels is', NS.relHrefOf(link('/a/b/x', 'near')) === '../../x');
  // Another origin, an empty ref, a ref off the origin: nothing.
  at('https://github.com/MHSanaei/3x-ui');
  check('rel-href never crosses origins', ids('a:rel-href("releases")', makeDoc([link('https://evil.example/MHSanaei/3x-ui/releases', 'e')])).length === 0
    && ids('a:rel-href("https://evil.example/x")', makeDoc([link('https://evil.example/x', 'e')])).length === 0
    && ids('a:rel-href("")', makeDoc([link('/MHSanaei/3x-ui/releases', 'r')])).length === 0);
  check(':sub-path still resolves (scenarios minted before :rel-href)', ids('a:sub-path("/releases")', makeDoc([link('/MHSanaei/3x-ui/releases', 'r')])).length === 1);
}

// ---- position path helpers -----------------------------------------------------------------
{
  const tree = (tag, kids = []) => { const e = { tagName: tag, children: kids, parentElement: null }; kids.forEach(k => { k.parentElement = e; }); return e; };
  const target = tree('a');
  const html = tree('html', [tree('head'), tree('body', [tree('div'), tree('div', [tree('span'), target])])]);
  globalThis.document = { documentElement: html, baseURI: 'https://site.example/' };
  check('indexPath is the child-index path from the root', JSON.stringify(NS.indexPath(target)) === '[1,1,1]');
  check('resolvePath walks it back', NS.resolvePath([1, 1, 1]) === target && NS.resolvePath([1, 9]) === null);
}

console.log(failures ? `${failures} FAILED` : 'all selector-resolver checks passed');
process.exit(failures ? 1 : 0);
