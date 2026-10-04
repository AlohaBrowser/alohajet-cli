// Runs `MainHeadingProbe.expression` (the bytes that ship) against tree-shaped fake documents.
// A whole-page read names no element; this probe reports the page's main heading(s) with a
// position path the Swift selector ladder turns into a receipt `[selector=…]`.
// Agent runs github-ss-r25/r26 (2026-09-23): the mint invented `h1.d-flex span` / `h1.d-inline.mr-3`
// for the release heading the agent read off the page, and refused them.
// Run with:  node Tests/BrowserToolsTests/main_heading.js
const fs = require('fs');
const path = require('path');
const src = fs.readFileSync(path.join(__dirname, '..', '..', 'Sources', 'BrowserTools', 'Runtime', 'MainHeadingReceipt.swift'), 'utf8');
const seg = src.slice(src.indexOf('static let expression = #"""'));
const expr = seg.slice(seg.indexOf('#"""') + 4, seg.indexOf('"""#'));

function el(tag, attrs = {}, children = [], { text = '', visible = true } = {}) {
  const e = { tagName: tag.toUpperCase(), _attrs: attrs, parentElement: null, children: [], innerText: text, textContent: text,
    getAttributeNames: () => Object.keys(attrs), getAttribute: k => (k in attrs ? attrs[k] : null),
    getBoundingClientRect: () => (visible ? { width: 100, height: 20 } : { width: 0, height: 0 }) };
  for (const c of children) { c.parentElement = e; e.children.push(c); }
  return e;
}
function all(root) { const out = []; (function walk(n) { for (const c of n.children) { out.push(c); walk(c); } })(root); return out; }
function makeDoc(bodyChildren) {
  const body = el('body', {}, bodyChildren); const html = el('html', {}, [body]);
  return { body, documentElement: html, querySelectorAll: q => {
    if (q === 'h1' || q === 'h2') return all(body).filter(e => e.tagName === q.toUpperCase());
    if (q === '[role="heading"][aria-level="1"]') return all(body).filter(e => e._attrs.role === 'heading' && e._attrs['aria-level'] === '1');
    return [];
  } };
}
const run = doc => JSON.parse(new Function('document', 'return ' + expr.trim())(doc));
let failures = 0;
function check(name, cond, detail) { console.log((cond ? 'ok   ' : 'FAIL ') + name + (cond ? '' : '  ' + JSON.stringify(detail))); if (!cond) failures++; }

// 1. THE GITHUB RELEASES SHAPE: two release cards, each with an h1; the latest first.
{
  const card = (v) => el('section', {}, [el('div', {}, [el('h1', { class: 'd-inline mr-3' }, [], { text: v })])]);
  const doc = makeDoc([el('div', {}, [el('main', {}, [card('v4.31.0'), card('v4.30.0')])])]);
  const r = run(doc);
  check('releases: both h1s reported, latest first', r.length === 2 && r[0].text === 'v4.31.0' && r[1].text === 'v4.30.0', r);
  check('releases: position path in the walker format', r[0].xpath === '/body/div/main/section[1]/div/h1' && r[1].xpath === '/body/div/main/section[2]/div/h1', r.map(x => x.xpath));
  check('releases: attributes in page order', JSON.stringify(r[0].attrs) === JSON.stringify([['class', 'd-inline mr-3']]), r[0].attrs);
}
// 2. Hidden h1 skipped; a role=heading level 1 used when there is no visible h1.
{
  const doc = makeDoc([el('h1', {}, [], { text: 'Skip nav', visible: false }), el('div', { role: 'heading', 'aria-level': '1' }, [], { text: 'Approachable Swift Concurrency' })]);
  const r = run(doc);
  check('no visible h1: role=heading level 1', r.length === 1 && r[0].text === 'Approachable Swift Concurrency' && r[0].tag === 'div', r);
}
// 3. Falls back to the first visible h2; at most three h1s.
{
  check('no h1, no role heading: first h2', run(makeDoc([el('h2', {}, [], { text: 'A' }), el('h2', {}, [], { text: 'B' })])).map(x => x.text).join() === 'A');
  const many = makeDoc([1, 2, 3, 4, 5].map(i => el('h1', {}, [], { text: 'H' + i })));
  check('at most three headings', run(many).length === 3);
}
// 4. Nothing to name: empty.
check('no headings: empty', run(makeDoc([el('p', {}, [], { text: 'x' })])).length === 0);

console.log(failures ? `${failures} FAILED` : 'all main-heading checks passed');
process.exit(failures ? 1 : 0);
