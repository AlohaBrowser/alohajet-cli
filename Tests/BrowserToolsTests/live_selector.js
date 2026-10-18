// Runs the LIVE SELECTOR PROBE -- `LiveSelectorProbe.expression` in ReceiptProbes.swift, the one
// page round trip that verifies a receipt's selector against the live page before it is written
// -- against tree-shaped fake documents, with a small CSS engine for ids, classes and the
// position paths it rebuilds (`body>div:nth-of-type(2)>a`). The expression is EXTRACTED from the
// Swift file, so this exercises the bytes that ship.
//
// Agent run github-ss-r75 (2026-09-30): the search button's position path came from the snapshot
// and github.com inserted a `div` above its header after the read, so it matched nothing at click
// time. The 2026-10-04 audit asked that every rung be verified the same way.
// Run with:  node Tests/BrowserToolsTests/live_selector.js
const fs = require('fs');
const path = require('path');
const src = fs.readFileSync(path.join(__dirname, '..', '..', 'Sources', 'BrowserTools', 'Runtime', 'ReceiptProbes.swift'), 'utf8');
const seg = src.slice(src.indexOf('static func expression(selector: String, alohaId: String)'));
const template = seg.slice(seg.indexOf('#"""') + 4, seg.indexOf('"""#'));

// ---- tree DOM + small CSS engine ------------------------------------------------------------
function el(tag, attrs = {}, children = []) {
  const e = { tagName: tag.toUpperCase(), _attrs: attrs, parentElement: null, children: [],
    getAttribute: k => (k in attrs ? attrs[k] : null),
    get firstElementChild() { return this.children[0] || null; },
    get nextElementSibling() { const s = this.parentElement ? this.parentElement.children : []; return s[s.indexOf(this) + 1] || null; },
    contains(o) { for (let n = o; n; n = n.parentElement) if (n === this) return true; return false; } };
  for (const c of children) { c.parentElement = e; e.children.push(c); }
  return e;
}
function all(root) { const out = []; (function walk(n) { for (const c of n.children) { out.push(c); walk(c); } })(root); return out; }
function simple(e, s) {
  let m;
  if ((m = /^([a-z][a-z0-9-]*)?\[([a-z-]+)="([^"]*)"\]$/.exec(s))) return (!m[1] || e.tagName.toLowerCase() === m[1]) && e._attrs[m[2]] === m[3];
  if (s[0] === '#') return e._attrs.id === s.slice(1);
  if ((m = /^([a-z][a-z0-9-]*)(?::nth-of-type\((\d+)\))?$/.exec(s))) {
    if (e.tagName.toLowerCase() !== m[1]) return false;
    if (!m[2]) return true;
    const sibs = e.parentElement.children.filter(c => c.tagName === e.tagName); return sibs.indexOf(e) + 1 === Number(m[2]);
  }
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
    if (q === '' || q.endsWith('[')) throw new SyntaxError('bad selector ' + q);
    if (q.startsWith('body>')) {
      const segs = q.split('>');
      return all(body).filter(e => { let n = e; for (let i = segs.length - 1; i >= 1; i--) { if (!n || n === body || !simple(n, segs[i])) return false; n = n.parentElement; } return n === body; });
    }
    return all(body).filter(e => simple(e, q));
  };
  return doc;
}
function run(doc, selector, alohaId) {
  const expr = template.split('\\#(selectorLiteral)').join(JSON.stringify(selector))
    .split('\\#(alohaIdLiteral)').join(JSON.stringify(alohaId))
    .split('\\#(StepTraceSelector.maxPathSegments)').join('32');
  return JSON.parse(new Function('document', 'return ' + expr.trim())(doc));
}
let failures = 0;
function check(name, cond, detail) { console.log((cond ? 'ok   ' : 'FAIL ') + name + (cond ? '' : '  ' + JSON.stringify(detail))); if (!cond) failures++; }

// 1. THE GITHUB SHAPE: the snapshot's path said div:nth-of-type(4); a div was inserted above the
//    header after the read, so the live button is under div:nth-of-type(5).
{
  const button = el('button', { 'aloha-id': 'search' });
  const doc = makeDoc([el('div', {}, [el('div', {}), el('div', {}), el('div', {}), el('div', {}), el('div', {}, [el('header', {}, [button])])])]);
  const r = run(doc, 'body>div>div:nth-of-type(4)>header>button', 'search');
  check('stale path: 0 matches, not contained', r.n === 0 && r.has === false, r);
  check('stale path: rebuilt from the live element', r.path === 'body>div>div:nth-of-type(5)>header>button' && r.pathN === 1, r);
  const ok = run(doc, 'body>div>div:nth-of-type(5)>header>button', 'search');
  check('a path that still names the element is kept (no rebuild)', ok.n === 1 && ok.has === true && ok.path === '', ok);
}
// 2. A NAMED RUNG THAT MOVED: `#q` is another input now (the framework re-minted the id).
{
  const field = el('input', { 'aloha-id': 'f1', id: 'q-renamed' });
  const other = el('input', { id: 'q' });
  const doc = makeDoc([el('form', {}, [other, field])]);
  const r = run(doc, '#q', 'f1');
  check('a named selector that names another element: 1 match, not contained, rebuilt', r.n === 1 && !r.has && r.path === 'body>form>input:nth-of-type(2)' && r.pathN === 1, r);
  const cls = run(doc, 'input.gone', 'f1');
  check('a class the page dropped: 0 matches, rebuilt', cls.n === 0 && !cls.has && cls.path === 'body>form>input:nth-of-type(2)', cls);
}
// 3. A MANY-MATCH SELECTOR that contains the element is kept with its count (the identity probe
//    reports the index).
{
  const sizes = ['S', 'M', 'L'].map((t, i) => el('button', { class: 'size', 'aloha-id': 's' + i }));
  const doc = makeDoc([el('div', {}, sizes)]);
  const r = run(doc, 'button.size', 's1');
  check('contained among three: kept, n=3', r.n === 3 && r.has === true && r.path === '', r);
}
// 4. NOTHING TO REBUILD: the element is gone from the page (stale id), or outside body, or the
//    selector does not parse.
{
  const doc = makeDoc([el('div', {}, [el('a', { 'aloha-id': 'x', class: 'card' })])]);
  const gone = run(doc, 'a.card', 'nope');
  check('element gone: count reported, no path', gone.n === 1 && !gone.has && gone.path === '', gone);
  const bad = run(doc, 'a[', 'x');
  check('unparsable selector: n=-1, rebuilt anyway', bad.n === -1 && !bad.has && bad.path === 'body>div>a', bad);
  const orphan = el('div', {}, [el('a', { 'aloha-id': 'o' })]);
  const q = doc.querySelectorAll; doc.querySelectorAll = s => s === '[aloha-id]' ? [orphan.children[0]] : q(s);
  const out = run(doc, 'a.card', 'o');
  check('element outside body: no path', out.path === '' && !out.has, out);
}
// 5. The rebuilt path is only kept when it resolves back to the element; a path deeper than the
//    ladder's bound is refused.
{
  let deep = el('a', { 'aloha-id': 'd' });
  let node = deep;
  for (let i = 0; i < 33; i++) node = el('div', {}, [node]);
  const doc = makeDoc([node]);
  const r = run(doc, 'a.missing', 'd');
  check('a path past 32 segments is not rebuilt', r.path === '' && r.n === 0, r);
}

console.log(failures ? `${failures} FAILED` : 'all live-selector checks passed');
process.exit(failures ? 1 : 0);
