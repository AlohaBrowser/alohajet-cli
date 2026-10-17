// Runs the `[anchor=…]` probe (`ReceiptAnchorProbe.expression`, the bytes that ship) against
// tree-shaped fake documents, with window.__snips.resolveAll = the REAL resolver extracted from
// SelectorResolverScript.swift -- so an anchor this harness accepts is one the replay picks.
//
// Agent runs, 2026-09-23: the mint anchored H&M's White swatch on the product card's text, and left
// GitHub's Go filter and H&M's size M as position paths. The probe chooses by one rule and
// verifies the choice. Run with:  node Tests/BrowserToolsTests/receipt_anchor.js
const fs = require('fs');
const path = require('path');
const sources = path.join(__dirname, '..', '..', 'Sources', 'BrowserTools', 'Runtime') + path.sep;

const resolverSwift = fs.readFileSync(sources + 'SelectorResolverScript.swift', 'utf8');
const rb = resolverSwift.indexOf('// BEGIN selector-resolver js'), re = resolverSwift.indexOf('// END selector-resolver js');
if (rb < 0 || re < 0) { console.error('markers not found in SelectorResolverScript.swift'); process.exit(2); }
const resolverSource = resolverSwift.slice(rb, re);
function resolverAt(url) {
  const window = {};
  globalThis.location = new URL(url);
  globalThis.document = { baseURI: url };
  new Function('window', resolverSource)(window);
  return window.__snips;
}
let NS = resolverAt('https://site.example/');

const asrc = fs.readFileSync(sources + 'ReceiptAnchor.swift', 'utf8');
const aseg = asrc.slice(asrc.indexOf('static func expression(alohaId: String'));
const template = aseg.slice(aseg.indexOf('#"""') + 4, aseg.indexOf('"""#'));
const maxLabel = Number(/static let maxLabelLength = (\d+)/.exec(asrc)[1]);

// ---- tree DOM + small CSS engine ------------------------------------------------------------
function el(tag, attrs = {}, children = [], text = '') {
  const e = { tagName: tag.toUpperCase(), _attrs: attrs, parentElement: null, children: [], _text: text,
    getAttribute: k => (k in attrs ? attrs[k] : null),
    hasAttribute: k => k in attrs,
    get textContent() { return this._text + this.children.map(c => c.textContent).join(''); },
    get innerText() { return this.textContent; } };
  for (const c of children) { c.parentElement = e; e.children.push(c); }
  return e;
}
function all(root) { const out = []; (function walk(n) { for (const c of n.children) { out.push(c); walk(c); } })(root); return out; }
function pos(e) { const s = e.parentElement.children.filter(c => c.tagName === e.tagName); return s.indexOf(e) + 1; }
function simple(e, s) {
  let m;
  if ((m = /^([a-z][a-z0-9-]*)?\[([a-z-]+)="([^"]*)"\]$/.exec(s))) return (!m[1] || e.tagName.toLowerCase() === m[1]) && e._attrs[m[2]] === m[3];
  if (s[0] === '#') return e._attrs.id === s.slice(1);
  if ((m = /^([a-z][a-z0-9-]*)(?::nth-of-type\((\d+)\))?$/.exec(s))) return e.tagName.toLowerCase() === m[1] && (!m[2] || pos(e) === Number(m[2]));
  if ((m = /^([a-z]*)((?:\.[\w-]+)+)$/.exec(s))) {
    if (m[1] && e.tagName.toLowerCase() !== m[1]) return false;
    const cls = (e._attrs.class || '').split(/\s+/); return m[2].split('.').filter(Boolean).every(c => cls.includes(c));
  }
  throw new Error('fake engine cannot parse ' + s);
}
function makeDoc(bodyChildren) {
  const body = el('body', {}, bodyChildren); const html = el('html', {}, [body]);
  const doc = { body, documentElement: html };
  doc.querySelectorAll = q => {
    if (q === '[aloha-id]') return all(html).filter(e => 'aloha-id' in e._attrs);
    if (q.startsWith('body>')) {
      const segs = q.split('>');
      return all(body).filter(e => { let n = e; for (let i = segs.length - 1; i >= 1; i--) { if (!n || n === body || !simple(n, segs[i])) return false; n = n.parentElement; } return n === body; });
    }
    return all(body).filter(e => simple(e, q));
  };
  return doc;
}
// `pageUrl` is where the page is (the resolver's `:rel-href` reads location / document.baseURI).
function run(doc, alohaId, selector, stable, list, forRead = false, pageUrl = 'https://site.example/') {
  const expr = template.split('\\#(idLiteral)').join(JSON.stringify(alohaId)).split('\\#(selLiteral)').join(JSON.stringify(selector || ''))
    .split('\\#(stable ? "true" : "false")').join(stable ? 'true' : 'false').split('\\#(listLiteral)').join(JSON.stringify(list || ''))
    .split('\\#(forRead ? "true" : "false")').join(forRead ? 'true' : 'false')
    .split('\\#(maxLabelLength)').join(String(maxLabel));
  globalThis.location = new URL(pageUrl);
  globalThis.document = { baseURI: pageUrl };
  const window = { __snips: NS };
  const out = new Function('document', 'window', 'return ' + expr.trim())(doc, window);
  return out ? JSON.parse(out) : null;
}
let failures = 0;
function check(name, cond, detail) { console.log((cond ? 'ok   ' : 'FAIL ') + name + (cond ? '' : '  ' + JSON.stringify(detail))); if (!cond) failures++; }

// 1. H&M WHITE SWATCH: a unique relative-href link with no text, title="White" -> rule 1, the href
//    on its own (never the product card's text).
{
  const sw = (href, title, id) => el('a', { href, title, role: 'radio', 'aloha-id': id });
  const doc = makeDoc([el('main', {}, [el('section', {}, [el('div', {}, [sw('/p/290', 'Brown', 's1'), sw('/p/001', 'White', 's2'), sw('/p/002', 'Black', 's3')])])])]);
  const r = run(doc, 's2', 'a[href="/p/001"]', true, 'body>main>section>div>a');
  check('swatch: the stable href on its own', r && r.s === 'a[href="/p/001"]' && !r.nth && r.n === 1, r);
}
// 2. H&M SIZE M: a position-path selector, list of seven sizes, text "M" -> list + :has-text("M").
{
  const sizes = ['XS', 'S', 'M', 'L', 'XL', 'XXL', '3XL'].map((t, i) => el('li', {}, [el('div', {}, [el('div', { 'aloha-id': 'z' + i }, [], t)])]));
  const doc = makeDoc([el('main', {}, [el('div', {}, [el('ul', {}, sizes)])])]);
  const r = run(doc, 'z2', 'body>main>div>ul>li:nth-of-type(3)>div>div', false, 'body>main>div>ul>li>div>div');
  check('size M: list selector + text anchor', r && r.s === 'body>main>div>ul>li>div>div:has-text("M")' && !r.nth, r);
}
// 3. A LABEL-LESS item in a list (an icon link): list + nth.
{
  const items = [1, 2, 3].map(i => el('li', {}, [el('a', { 'aloha-id': 'i' + i })]));
  const doc = makeDoc([el('ul', {}, items)]);
  const r = run(doc, 'i2', 'body>ul>li:nth-of-type(2)>a', false, 'body>ul>li>a');
  check('no label: list + nth', r && r.s === 'body>ul>li>a' && r.nth === 2, r);
}
// 4. A label that is NOT unique in the list falls through to list + nth.
{
  const items = ['Go', 'Go', 'Rust'].map((t, i) => el('li', {}, [el('a', { 'aloha-id': 'g' + i }, [], t)]));
  const doc = makeDoc([el('ul', {}, items)]);
  const r = run(doc, 'g1', 'body>ul>li:nth-of-type(2)>a', false, 'body>ul>li>a');
  check('duplicate label: list + nth', r && r.s === 'body>ul>li>a' && r.nth === 2, r);
}
// 5. No list, a position path, a label: selector + :has-text.
{
  const doc = makeDoc([el('main', {}, [el('div', {}, [el('button', { 'aloha-id': 'b' }, [], 'Continue')])])]);
  const r = run(doc, 'b', 'body>main>div>button', false, '');
  check('no list: selector + text anchor', r && r.s === 'body>main>div>button:has-text("Continue")', r);
}
// 6. A stable selector that is AMBIGUOUS does not win rule 1; the list does.
{
  const cards = [1, 2].map(i => el('div', { class: 'card' }, [el('button', { class: 'buy', 'aloha-id': 'c' + i }, [], i === 1 ? 'Buy A' : 'Buy B')]));
  const doc = makeDoc([el('main', {}, cards)]);
  const r = run(doc, 'c2', 'button.buy', true, 'body>main>div>button');
  check('ambiguous stable selector: list + text instead', r && r.s === 'body>main>div>button:has-text("Buy B")', r);
}
// 7. Quotes in a label are escaped so the anchor still resolves.
{
  const doc = makeDoc([el('div', {}, [el('button', { 'aloha-id': 'q' }, [], 'Say "hi"')])]);
  const r = run(doc, 'q', 'body>div>button', false, '');
  check('quoted label escaped and verified', r && r.s === 'body>div>button:has-text("Say \\"hi\\"")', r);
}
// 8. Nothing resolves to exactly the element (no resolver on the page): no anchor.
{
  const doc = makeDoc([el('div', {}, [el('button', { 'aloha-id': 'n' }, [], 'X')])]);
  const expr = template.split('\\#(idLiteral)').join('"n"').split('\\#(selLiteral)').join('"body>div>button"').split('\\#(stable ? "true" : "false")').join('false').split('\\#(listLiteral)').join('""').split('\\#(forRead ? "true" : "false")').join('false').split('\\#(maxLabelLength)').join('60');
  check('no resolver installed: empty', new Function('document', 'window', 'return ' + expr.trim())(doc, {}) === '');
}

// 9. A READ never anchors on its own text (github-ss-r53): the release-name link, 2nd of the
//    release list, reads by its place -- `:has-text("v3.8.5")` would name the answer.
{
  const rel = (t, i) => el('li', {}, [el('a', { class: 'ActionListContent', href: '#release-' + t, 'aloha-id': 'r' + i }, [], t)]);
  const doc = makeDoc([el('nav', {}, [el('ul', {}, ['Dev build', 'v3.8.5', 'v3.8.4'].map(rel))])]);
  const r = run(doc, 'r1', 'a.ActionListContent', true, 'body>nav>ul>li>a', true);
  check('read: list + nth, never the read text', r && r.s === 'body>nav>ul>li>a' && r.nth === 2, r);
  // Clicked, a version label is still a changing value (case 14): list + nth as well.
  const w = run(doc, 'r1', 'a.ActionListContent', true, 'body>nav>ul>li>a', false);
  check('the same element CLICKED: a version label is not a text anchor either', w && w.s === 'body>nav>ul>li>a' && w.nth === 2, w);
}
// 10. A LINK TO A SUB-PAGE of the current page (github-ss-r53's Releases badge: absolute href, no
//     text, in a README): `a:rel-href("releases")`, repo-free -- although the sidebar link to the
//     same place also matches, and another repo's releases link sits in the same README.
{
  const badge = el('a', { href: 'https://github.com/MHSanaei/3x-ui/releases', 'aloha-id': 'badge' }, [el('img', { alt: '' })]);
  const other = el('a', { href: 'https://github.com/XTLS/Xray-core/releases', 'aloha-id': 'other' }, [], 'Xray releases');
  const side = el('a', { href: '/MHSanaei/3x-ui/releases', 'aloha-id': 'side' }, [], 'Releases');
  const latest = el('a', { href: '/MHSanaei/3x-ui/releases/latest', 'aloha-id': 'latest' }, [], 'Latest');
  const doc = makeDoc([el('main', {}, [el('article', {}, [el('p', {}, [other, badge])]), el('aside', {}, [side, latest])])]);
  const at = 'https://github.com/MHSanaei/3x-ui';
  const r = run(doc, 'badge', 'body>main>article>p>a:nth-of-type(2)', false, 'body>main>article>p>a', false, at);
  check('sub-page link: a:rel-href("releases"), two links lead there', r && r.s === 'a:rel-href("releases")' && !r.nth && r.n === 2, r);
  // A deeper sub-page keeps its whole tail; a link to another repo is not relative to this page.
  const l = run(doc, 'latest', 'a[href="/MHSanaei/3x-ui/releases/latest"]', true, '', false, at);
  check('deeper sub-page: the whole tail', l && l.s === 'a:rel-href("releases/latest")', l);
  const o = run(doc, 'other', 'body>main>article>p>a:nth-of-type(1)', false, 'body>main>article>p>a', false, at);
  check("another repo's link is not rel-href", o && !/rel-href|sub-path/.test(o.s), o);
}

// 11. A READ whose href carries the value (github-ss-r57: the release title link
//     `/MHSanaei/3x-ui/releases/tag/v3.8.5`, read on the Releases page): neither the href rung nor
//     `a:rel-href("tag/v3.8.5")` -- both name the answer; the release list + nth instead. The same
//     link CLICKED keeps the rel-href address.
{
  const title = (t, i) => el('section', {}, [el('h2', {}, [el('a', { href: '/MHSanaei/3x-ui/releases/tag/' + t, 'aloha-id': 't' + i }, [], t)])]);
  const doc = makeDoc([el('main', {}, ['Dev build 823db059', 'v3.8.5', 'v3.8.0'].map(title))]);
  const at = 'https://github.com/MHSanaei/3x-ui/releases';
  const r = run(doc, 't1', 'a[href="/MHSanaei/3x-ui/releases/tag/v3.8.5"]', true, 'body>main>section>h2>a', true, at);
  check('read: the value is in no part of the address', r && !/v3\.8\.5/.test(r.s) && r.s === 'body>main>section>h2>a' && r.nth === 2, r);
  const c = run(doc, 't1', 'a[href="/MHSanaei/3x-ui/releases/tag/v3.8.5"]', true, 'body>main>section>h2>a', false, at);
  check('the same link clicked: rel-href', c && c.s === 'a:rel-href("tag/v3.8.5")', c);
}

// 12. THE ELEMENT'S ACCESSIBLE NAME beats a hashed class or a position (github-ss, 2026-09-29: the
//     search button anchored on `…___zQrEw:has-text("Search/")` while its receipt carried
//     `aria-label="Search or jump to, type / to search"`). The ladder now refuses the hash, so the
//     button's selector is a position path; rule 1b gives the aria-label.
{
  const btn = (label, id, text) => el('button', { 'aria-label': label, 'aloha-id': id }, [], text);
  const doc = makeDoc([el('header', {}, [btn('Search or jump to, type / to search', 'search', 'Search/'), btn('Open menu', 'menu', '')])]);
  const r = run(doc, 'search', 'body>header>button:nth-of-type(1)', false, '');
  check('accessible name: button[aria-label=…]', r && r.s === 'button[aria-label="Search or jump to, type / to search"]', r);
  // Two buttons with the SAME label: not exactly this element -> falls through to the text anchor.
  const dup = makeDoc([el('header', {}, [btn('Search', 'd1', 'Search/'), btn('Search', 'd2', 'Find')])]);
  const d = run(dup, 'd1', 'body>header>button:nth-of-type(1)', false, '');
  check('a label two elements share is not an address', d && d.s === 'body>header>button:nth-of-type(1):has-text("Search/")', d);
  // A label with a digit changes with the content ("3 items in cart"): skipped.
  const cart = makeDoc([el('div', {}, [el('a', { 'aria-label': '3 items in cart', 'aloha-id': 'c' }, [], 'Bag')])]);
  const c = run(cart, 'c', 'body>div>a', false, '');
  check('a label with a digit is skipped', c && !/aria-label/.test(c.s), c);
  // A stable ladder selector still comes first; a title is used when there is no aria-label.
  const t = makeDoc([el('div', {}, [el('a', { title: 'Find directions between two points', 'aloha-id': 't' })])]);
  const tr = run(t, 't', 'body>div>a', false, '');
  check('title when there is no aria-label', tr && tr.s === 'a[title="Find directions between two points"]', tr);
  const s = makeDoc([el('div', {}, [el('button', { 'data-testid': 'sort-button', 'aria-label': 'Sort', 'aloha-id': 's' }, [], 'Sort')])]);
  const sr = run(s, 's', '[data-testid="sort-button"]', true, '');
  check('a stable test hook still wins', sr && sr.s === '[data-testid="sort-button"]', sr);
}

// 13. A LABEL WITH A DIGIT is not a text anchor (hn-swift-r74: the top story's "98 comments"
//     anchored as `:has-text("98 comments")`, dead at the 99th comment). The list + nth rung
//     addresses it; with no list there is no text anchor at all.
{
  const story = (n, i) => el('tr', {}, [el('td', {}, [el('a', { href: '/item?id=' + i, 'aloha-id': 'h' + i }, [], n + ' comments')])]);
  const doc = makeDoc([el('table', {}, [el('tbody', {}, [story(98, 1), story(40, 2), story(7, 3)])])]);
  const r = run(doc, 'h1', 'body>table>tbody>tr:nth-of-type(1)>td>a', false, 'body>table>tbody>tr>td>a');
  check('count label: never :has-text', r && !/has-text/.test(r.s), r);
  const sizes = makeDoc([el('ul', {}, ['40', '41', '42'].map((t, i) => el('li', {}, [el('button', { 'aloha-id': 's' + i }, [], t)])))]);
  const s = run(sizes, 's2', 'body>ul>li:nth-of-type(3)>button', false, 'body>ul>li>button');
  check('size "42": list + nth', s && s.s === 'body>ul>li>button' && s.nth === 3, s);
  const lone = makeDoc([el('div', {}, [el('button', { 'aloha-id': 'p' }, [], 'Pay $19.99')])]);
  const p = run(lone, 'p', 'body>div>button', false, '');
  check('no list, digit label: no text anchor', !p || !/has-text/.test(p.s), p);
  const words = makeDoc([el('ul', {}, ['Best match', 'Most stars'].map((t, i) => el('li', {}, [el('a', { 'aloha-id': 'w' + i }, [], t)])))]);
  const w = run(words, 'w1', 'body>ul>li:nth-of-type(2)>a', false, 'body>ul>li>a');
  check('a label without digits keeps its text anchor', w && w.s === 'body>ul>li>a:has-text("Most stars")', w);
}

// 14. `:rel-href` IN EVERY DIRECTION from the current page, and never for a link elsewhere.
{
  const a = (href, id, text = '') => el('a', { href, 'aloha-id': id }, [], text);
  // npm: the same page, another tab (a query) -- the address of "the Versions tab of this package".
  const npm = makeDoc([el('ul', {}, [a('/package/left-pad?activeTab=readme', 'readme', 'Readme'), a('/package/left-pad?activeTab=versions', 'ver', 'Versions')])]);
  const v = run(npm, 'ver', 'body>ul>a:nth-of-type(2)', false, 'body>ul>a', false, 'https://www.npmjs.com/package/left-pad');
  check('same page, another query: a:rel-href("?activeTab=versions")', v && v.s === 'a:rel-href("?activeTab=versions")', v);
  // Up a level, and a sibling under the same parent.
  const repo = makeDoc([el('nav', {}, [a('/MHSanaei/3x-ui', 'up', 'Code'), a('/MHSanaei/3x-ui/issues', 'sib', 'Issues')])]);
  const up = run(repo, 'up', 'body>nav>a:nth-of-type(1)', false, 'body>nav>a', false, 'https://github.com/MHSanaei/3x-ui/pulls');
  check('the page above: a:rel-href("..")', up && up.s === 'a:rel-href("..")', up);
  const sib = run(repo, 'sib', 'body>nav>a:nth-of-type(2)', false, 'body>nav>a', false, 'https://github.com/MHSanaei/3x-ui/pulls');
  check('a sibling: a:rel-href("../issues")', sib && sib.s === 'a:rel-href("../issues")', sib);
  // A search result is not relative to /search: it keeps its own address (shares no path).
  const results = makeDoc([el('div', {}, [a('/MHSanaei/3x-ui', 'top', 'MHSanaei/3x-ui')])]);
  const t = run(results, 'top', 'a[href="/MHSanaei/3x-ui"]', true, '', false, 'https://github.com/search?q=shadowsocks');
  check('a link elsewhere on the site is not rel-href', t && t.s === 'a[href="/MHSanaei/3x-ui"]', t);
}

// 15. THE HACKER NEWS SHAPE (2026-10-04 audit): a result link to another site, and its comments
//     link with a query string. Rung 4b refuses both (not a relative query-free path), `:rel-href`
//     refuses the first (another origin) and the second from the front page's root (no shared
//     segment) -- so neither had an address. Rule 1a offers the href verbatim, when unique.
{
  const story = (title, href, id) => el('tr', {}, [el('td', {}, [el('span', { class: 'titleline' }, [el('a', { href, 'aloha-id': id }, [], title)])])]);
  const sub = (id, n, aid) => el('tr', {}, [el('td', {}, [el('span', { class: 'subline' }, [el('a', { href: 'item?id=' + id, 'aloha-id': aid }, [], n + ' comments')])])]);
  const doc = makeDoc([el('table', {}, [el('tbody', {}, [
    story('Show HN: Bar 2.0', 'https://github.com/foo/bar', 's1'), sub(101, 98, 'c1'),
    story('A plain post', 'https://example.org/post', 's2'), sub(102, 4, 'c2'),
    story('Same place again', 'https://example.org/post', 's3'), sub(103, 1, 'c3')])])]);
  const at = 'https://news.ycombinator.com/';
  const list = 'body>table>tbody>tr>td>span>a';
  const r = run(doc, 's1', 'body>table>tbody>tr:nth-of-type(1)>td>span>a', false, list, false, at);
  check('an external result link anchors on its href verbatim', r && r.s === 'a[href="https://github.com/foo/bar"]' && r.n === 1, r);
  const c = run(doc, 'c1', 'body>table>tbody>tr:nth-of-type(2)>td>span>a', false, list, false, at);
  check('a query-bearing relative link too (and never its digit label)', c && c.s === 'a[href="item?id=101"]', c);
  // Two links to the same place: not exactly this element, so the href is not its address.
  const d = run(doc, 's2', 'body>table>tbody>tr:nth-of-type(3)>td>span>a', false, list, false, at);
  check('a destination two links share is not an address', d && !/example\.org/.test(d.s), d);
  // A READ whose label sits inside the href is still protected by the value filter.
  const read = makeDoc([el('div', {}, [el('a', { href: 'https://example.org/v3.8.5', 'aloha-id': 'rd' }, [], 'v3.8.5'), el('a', { href: '/other', 'aloha-id': 'o' }, [], 'Other')])]);
  const rr = run(read, 'rd', 'body>div>a:nth-of-type(1)', false, 'body>div>a', true, at);
  check('a read never anchors on an href holding the value read', !rr || !/v3\.8\.5/.test(rr.s), rr);
  // A rung-4b href is rule 1's business: when it is ambiguous there, rule 1a does not offer it again.
  const twice = makeDoc([el('ul', {}, [el('li', {}, [el('a', { href: '/p/1', 'aloha-id': 'p1' }, [], 'One')]), el('li', {}, [el('a', { href: '/p/1', 'aloha-id': 'p2' }, [], 'Two')])])]);
  const t = run(twice, 'p2', 'a[href="/p/1"]', true, 'body>ul>li>a', false, at);
  check('an ambiguous rung-4b href falls to the list, not to itself', t && t.s === 'body>ul>li>a:has-text("Two")', t);
  // Unquotable values are never offered.
  const odd = makeDoc([el('div', {}, [el('a', { href: 'https://x.example/a"b', 'aloha-id': 'q' }, [], 'Q')])]);
  const oq = run(odd, 'q', 'body>div>a', false, '', false, at);
  check('an href with a quote is not offered', oq && !/href/.test(oq.s), oq);
  // A bare fragment names a spot in this document and carries its content (case 9's release
  // link, `#release-v3.8.5`); a script URL is no destination. Neither is offered.
  const frag = makeDoc([el('div', {}, [el('a', { href: '#release-v3.8.5', 'aloha-id': 'f' }, [], 'Jump'), el('a', { href: 'javascript:void(0)', 'aloha-id': 'j' }, [], 'Open')])]);
  const fr = run(frag, 'f', 'body>div>a:nth-of-type(1)', false, 'body>div>a', false, at);
  check('a bare fragment href is not offered', fr && !/href/.test(fr.s), fr);
  const jr = run(frag, 'j', 'body>div>a:nth-of-type(2)', false, 'body>div>a', false, at);
  check('a javascript: href is not offered', jr && !/href/.test(jr.s), jr);
}

console.log(failures ? `${failures} FAILED` : 'all receipt-anchor checks passed');
process.exit(failures ? 1 : 0);
