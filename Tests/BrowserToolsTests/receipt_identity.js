// Runs the RECEIPT IDENTITY PROBE -- `ReceiptIdentityProbe.expression` in PageToolsSupport.swift,
// the one page round trip that reads `[index=i/N]` and `[attrs=…]` for an action receipt --
// against fake documents of unrelated shapes. The expression is EXTRACTED from the Swift file, so
// this exercises the bytes that ship (with the template's literals substituted the way Swift does).
// Run with:  node Tests/BrowserToolsTests/receipt_identity.js
const fs = require('fs');
const path = require('path');
const repo = path.join(__dirname, '..', '..', 'Sources', 'BrowserTools') + path.sep;

const sup = fs.readFileSync(repo + 'Tools' + path.sep + 'PageToolsSupport.swift', 'utf8');
const seg = sup.slice(sup.indexOf('static func expression(selector: String?, alohaId: String)'));
const template = seg.slice(seg.indexOf('#"""') + 4, seg.indexOf('"""#'));
const consts = {};
for (const k of ['maxAttributes', 'maxValueLength', 'maxTotalLength']) {
  consts[k] = Number(new RegExp('static let ' + k + ' = (\\d+)').exec(sup)[1]);
}

function el(tag, attrs, { w = 20 } = {}) {
  const order = Object.keys(attrs);
  return { tagName: tag.toUpperCase(), _attrs: attrs,
           getAttributeNames: () => order.slice(),
           getAttribute: k => (k in attrs ? attrs[k] : null),
           getBoundingClientRect: () => ({ width: w, height: w }) };
}
// tiny engine: `tag.cls` / `tag` / `[aloha-id]` / `#id` / `[name="x"]`; nothing else.
function matches(e, q) {
  q = q.trim();
  if (q === '[aloha-id]') return 'aloha-id' in e._attrs;
  if (q[0] === '#') return e._attrs.id === q.slice(1);
  const nm = /^\[name="([^"]+)"\]$/.exec(q); if (nm) return e._attrs.name === nm[1];
  const m = /^([a-z]*)((?:\.[\w-]+)*)$/.exec(q); if (!m) throw new Error('fake engine cannot parse ' + q);
  if (m[1] && e.tagName.toLowerCase() !== m[1]) return false;
  const cls = (e._attrs.class || '').split(/\s+/);
  return m[2].split('.').filter(Boolean).every(c => cls.includes(c));
}
function makeDoc(els) { return { querySelectorAll(q) { return els.filter(e => matches(e, q)); } }; }

function run(doc, selector, alohaId) {
  const expr = template.split('\\#(selectorLiteral)').join(JSON.stringify(selector || ''))
    .split('\\#(alohaIdLiteral)').join(JSON.stringify(alohaId))
    .split('\\#(maxAttributes)').join(String(consts.maxAttributes))
    .split('\\#(maxValueLength)').join(String(consts.maxValueLength))
    .split('\\#(maxTotalLength)').join(String(consts.maxTotalLength))
    .split('\\#(maxListSegments)').join('32');
  return JSON.parse(new Function('document', 'return ' + expr.trim())(doc));
}

let failures = 0;
function check(name, cond, detail) { console.log((cond ? 'ok   ' : 'FAIL ') + name + (cond ? '' : '  ' + JSON.stringify(detail))); if (!cond) failures++; }
const attrsOf = r => Object.fromEntries(r.attrs);

// 1. a shop: three size buttons share one class selector; the clicked one is the second,
//    and its identity is in data-* / aria attributes the selector ladder never used.
{
  const sizes = [
    el('button', { class: 'size-selector-sizes-size__button', 'aloha-id': 'a1', 'data-qa-action': 'size-in-stock', 'aria-label': 'S' }),
    el('button', { class: 'size-selector-sizes-size__button', 'aloha-id': 'a2', 'data-qa-action': 'size-in-stock', 'aria-label': 'M', style: 'color:red', tabindex: '0', onclick: 'x()' }),
    el('button', { class: 'size-selector-sizes-size__button', 'aloha-id': 'a3', 'data-qa-action': 'size-out-of-stock', 'aria-label': 'L' }),
  ];
  const r = run(makeDoc(sizes), 'button.size-selector-sizes-size__button', 'a2');
  check('shop: index is 2 of the three', r.index === 2, r);
  check('shop: data-* and aria-* attributes ride along', attrsOf(r)['data-qa-action'] === 'size-in-stock' && attrsOf(r)['aria-label'] === 'M', r);
  check('shop: class / style / aloha-id / tabindex / on* are left out', !('class' in attrsOf(r)) && !('style' in attrsOf(r)) && !('aloha-id' in attrsOf(r)) && !('tabindex' in attrsOf(r)) && !('onclick' in attrsOf(r)), r);
  check('shop: page order kept', r.attrs.map(p => p[0]).join() === 'data-qa-action,aria-label', r);
}

// 2. a form: the typed field's `value` is user data and never on the receipt; name/type/id are.
{
  const els = [
    el('input', { 'aloha-id': 'f1', id: 'q', name: 'q', type: 'search', value: 'faux suede belted jacket', placeholder: 'Search' }),
    el('input', { 'aloha-id': 'f2', name: 'passwd', type: 'password', value: 'hunter2' }),
    el('button', { 'aloha-id': 'f3', type: 'submit', value: 'go' }),
  ];
  const doc = makeDoc(els);
  const r = run(doc, '#q', 'f1');
  check('form: one match -> index 1', r.index === 1, r);
  check('form: value is NOT read from an input', !('value' in attrsOf(r)) && attrsOf(r).name === 'q' && attrsOf(r).type === 'search' && attrsOf(r).placeholder === 'Search', r);
  check('form: a password value is never read', !('value' in attrsOf(run(doc, '[name="passwd"]', 'f2'))));
  check("form: a button's value IS identity", attrsOf(run(doc, 'button', 'f3')).value === 'go');
}

// 3. gaps: unknown id, absent selector, unparsable selector, element not in the selector's set
{
  const doc = makeDoc([el('a', { 'aloha-id': 'x1', href: 'https://example.test/p/1', class: 'card' }), el('a', { 'aloha-id': 'x2', href: 'https://example.test/p/2', class: 'card' })]);
  check('gaps: unknown aloha-id -> index -1, no attrs', JSON.stringify(run(doc, 'a.card', 'nope')) === '{"index":-1,"attrs":[]}');
  const noSel = run(doc, '', 'x2');
  check('gaps: no selector -> attrs still read, index -1', noSel.index === -1 && attrsOf(noSel).href === 'https://example.test/p/2', noSel);
  const bad = run(doc, 'a[', 'x2');
  check('gaps: an unparsable selector throws inside the page and is absorbed', bad.index === -1 && bad.attrs.length === 1, bad);
  const other = run(doc, '#nothing', 'x1');
  check("gaps: element outside the selector's matches -> index -1", other.index === -1 && attrsOf(other).href.endsWith('/p/1'), other);
}

// 4. caps: a long value is trimmed with '...', a data: URI is dropped, the count is bounded
{
  const many = { 'aloha-id': 'm1' };
  for (let i = 0; i < consts.maxAttributes + 5; i++) many['data-k' + i] = 'v' + i;
  many.src = 'data:image/png;base64,AAAA';
  many.href = 'x'.repeat(consts.maxValueLength + 40);
  const r = run(makeDoc([el('a', many)]), 'a', 'm1');
  check('caps: at most maxAttributes attributes', r.attrs.length <= consts.maxAttributes, r.attrs.length);
  check('caps: data: URI dropped', !('src' in attrsOf(r)));
  const long = run(makeDoc([el('a', { 'aloha-id': 'm2', href: 'y'.repeat(consts.maxValueLength + 40) })]), 'a', 'm2');
  check('caps: long value trimmed to maxValueLength with ...', attrsOf(long).href.length === consts.maxValueLength && attrsOf(long).href.endsWith('...'), attrsOf(long).href.length);
  const ws = run(makeDoc([el('div', { 'aloha-id': 'm3', title: '  two\n lines  ' })]), 'div', 'm3');
  check('caps: whitespace collapsed', attrsOf(ws).title === 'two lines', ws);
}

console.log(failures ? `${failures} FAILED` : 'all receipt-identity checks passed');
process.exit(failures ? 1 : 0);
