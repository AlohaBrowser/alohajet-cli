// Runs the `[text="…"]` probe (`ElementTextProbe.expression`, the bytes that ship) against fake
// documents. The words a receipt carries for the element an action touched: its own rendered text,
// else -- an element with none -- its aria-label, value or placeholder, then its title, then the alt
// of an image inside it (2026-10-18). Run with:  node Tests/BrowserToolsTests/element_text.js
const fs = require('fs');
const path = require('path');

const src = fs.readFileSync(path.join(__dirname, '..', '..', 'Sources', 'BrowserTools', 'Runtime', 'ReceiptProbes.swift'), 'utf8');
const seg = src.slice(src.indexOf('enum ElementTextProbe'));
const template = seg.slice(seg.indexOf('#"""') + 4, seg.indexOf('"""#'));
const maxLength = Number(/static let maxLength = (\d+)/.exec(seg)[1]);

function el(tag, attrs = {}, children = [], text = '') {
  const e = { tagName: tag.toUpperCase(), _attrs: attrs, children,
    getAttribute: k => (k in attrs ? attrs[k] : null),
    get textContent() { return text + children.map(c => c.textContent).join(''); },
    get innerText() { return this.textContent; },
    querySelectorAll: q => {
      if (q !== 'img[alt]') throw new Error('fake engine cannot parse ' + q);
      const out = []; (function walk(n) { for (const c of n.children) { if (c.tagName === 'IMG' && 'alt' in c._attrs) out.push(c); walk(c); } })(e);
      return out;
    } };
  return e;
}
function makeDoc(els) {
  const all = []; (function walk(list) { for (const e of list) { all.push(e); walk(e.children); } })(els);
  return { querySelectorAll: q => { if (q !== '[aloha-id]') throw new Error('fake engine cannot parse ' + q); return all.filter(e => 'aloha-id' in e._attrs); } };
}
function run(doc, id) {
  const expr = template.split('\\#(idLiteral)').join(JSON.stringify(id)).split('\\#(maxLength)').join(String(maxLength));
  return new Function('document', 'return ' + expr.trim())(doc);
}

let failures = 0;
function check(name, cond, detail) { console.log((cond ? 'ok   ' : 'FAIL ') + name + (cond ? '' : '  ' + JSON.stringify(detail))); if (!cond) failures++; }

const doc = makeDoc([
  el('button', { 'aloha-id': 'txt', 'aria-label': 'ignored' }, [], '  BELTED   FAUX\nSUEDE JACKET '),
  el('button', { 'aloha-id': 'aria', 'aria-label': 'More target languages', title: 'ignored' }),
  el('input', { 'aloha-id': 'ph', placeholder: 'From', title: 'ignored' }),
  el('input', { 'aloha-id': 'val', value: 'Go' }),
  el('a', { 'aloha-id': 'ttl', title: 'Find directions between two points' }),
  el('a', { 'aloha-id': 'img', href: '/' }, [el('span', {}, [el('img', { alt: '' }), el('img', { alt: '  Acme   Shop ' })])]),
  el('a', { 'aloha-id': 'both', title: 'Home' }, [el('img', { alt: 'Logo' })]),
  el('a', { 'aloha-id': 'textAndImg' }, [el('img', { alt: 'Logo' })], 'Sale'),
  el('div', { 'aloha-id': 'none' }),
  el('p', { 'aloha-id': 'long' }, [], 'x'.repeat(200)),
  el('span', { 'aloha-id': 'q"uote' }, [], 'quoted id'),
]);

check('own text, whitespace collapsed', run(doc, 'txt') === 'BELTED FAUX SUEDE JACKET', run(doc, 'txt'));
check('no text: aria-label before title', run(doc, 'aria') === 'More target languages', run(doc, 'aria'));
check('a field: its placeholder', run(doc, 'ph') === 'From', run(doc, 'ph'));
check('a field: its value attribute', run(doc, 'val') === 'Go', run(doc, 'val'));
check('no text, no label: the title', run(doc, 'ttl') === 'Find directions between two points', run(doc, 'ttl'));
check('no text, no label, no title: the alt of an image inside (the first non-empty one)', run(doc, 'img') === 'Acme Shop', run(doc, 'img'));
check('a title comes before an image alt', run(doc, 'both') === 'Home', run(doc, 'both'));
check('own text comes before an image alt', run(doc, 'textAndImg') === 'Sale', run(doc, 'textAndImg'));
check('nothing at all: empty', run(doc, 'none') === '', run(doc, 'none'));
check('capped at ' + maxLength + ' characters', run(doc, 'long').length === maxLength, run(doc, 'long').length);
check('an id is matched as data, never as a selector', run(doc, 'q"uote') === 'quoted id', run(doc, 'q"uote'));
check('an unknown id: empty', run(doc, 'missing') === '', run(doc, 'missing'));
check('a page that throws: empty', new Function('document', 'return ' + template.split('\\#(idLiteral)').join('"x"').split('\\#(maxLength)').join('60').trim())({ querySelectorAll() { throw new Error('boom'); } }) === '');

console.log(failures ? `${failures} FAILED` : 'all element-text checks passed');
process.exit(failures ? 1 : 0);
