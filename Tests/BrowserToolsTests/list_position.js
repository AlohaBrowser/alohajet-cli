// Runs the `[list=<selector> N/M]` part of the receipt identity probe
// (`ReceiptIdentityProbe.expression`, the bytes that ship) against TREE-shaped fake documents,
// with a small CSS engine for the position paths it emits (`body>div:nth-of-type(2)>a`).
//
// Agent round 17 (2026-09-23): every GitHub and Hacker News receipt had a unique selector, so no
// `[index=N/M]`, and `nth` had nothing to count. The list bracket names the repeating list the
// element sits in and its place there, whichever ladder rung won `[selector=…]`.
// Run with:  node Tests/BrowserToolsTests/list_position.js
const fs = require('fs');
const path = require('path');
const sup = fs.readFileSync(path.join(__dirname, '..', '..', 'Sources', 'BrowserTools', 'Tools', 'PageToolsSupport.swift'), 'utf8');
const seg = sup.slice(sup.indexOf('static func expression(selector: String?, alohaId: String)'));
const template = seg.slice(seg.indexOf('#"""') + 4, seg.indexOf('"""#'));

// ---- tree DOM ---------------------------------------------------------------------------------
function el(tag, attrs = {}, children = []) {
  const e = { tagName: tag.toUpperCase(), _attrs: attrs, parentElement: null, children: [],
    getAttributeNames: () => Object.keys(attrs), getAttribute: k => (k in attrs ? attrs[k] : null) };
  for (const c of children) { c.parentElement = e; e.children.push(c); }
  return e;
}
function all(root) { const out = []; (function walk(n) { for (const c of n.children) { out.push(c); walk(c); } })(root); return out; }
function segMatch(e, s) {
  const m = /^([a-z][a-z0-9-]*)(?::nth-of-type\((\d+)\))?$/.exec(s); if (!m) throw new Error('fake engine: ' + s);
  if (e.tagName.toLowerCase() !== m[1]) return false;
  if (m[2]) { const sibs = e.parentElement.children.filter(c => c.tagName === e.tagName); return sibs.indexOf(e) + 1 === Number(m[2]); }
  return true;
}
function makeDoc(bodyChildren) {
  const body = el('body', {}, bodyChildren); const html = el('html', {}, [body]);
  const doc = { body, documentElement: html };
  doc.querySelectorAll = q => {
    if (q === '[aloha-id]') return all(html).filter(e => 'aloha-id' in e._attrs);
    if (/^[a-z]/.test(q) && q.startsWith('body')) {
      const segs = q.split('>');
      return all(body).filter(e => {
        let n = e;
        for (let i = segs.length - 1; i >= 1; i--) { if (!n || !segMatch(n, segs[i])) return false; n = n.parentElement; }
        return n === body;
      });
    }
    const h = /^a\[href="(.+)"\]$/.exec(q); if (h) return all(body).filter(e => e.tagName === 'A' && e._attrs.href === h[1]);
    return [];
  };
  return doc;
}
function run(doc, selector, alohaId) {
  const expr = template.split('\\#(selectorLiteral)').join(JSON.stringify(selector || ''))
    .split('\\#(alohaIdLiteral)').join(JSON.stringify(alohaId))
    .split('\\#(maxAttributes)').join('12').split('\\#(maxValueLength)').join('80')
    .split('\\#(maxTotalLength)').join('600').split('\\#(maxListSegments)').join('32');
  return JSON.parse(new Function('document', 'return ' + expr.trim())(doc));
}
let failures = 0;
function check(name, cond, detail) { console.log((cond ? 'ok   ' : 'FAIL ') + name + (cond ? '' : '  ' + JSON.stringify(detail))); if (!cond) failures++; }

// 1. THE HACKER NEWS SHAPE: 30 stories; each subline has five sibling links, the comments link
//    is the last. The list is the STORIES (30), not the five links of one subline.
function story(i) {
  const links = ['points', 'user', 'age', 'hide', 'comments'].map(k =>
    el('a', k === 'comments' ? { href: '/item?id=' + i, 'aloha-id': 'c' + i } : { href: '/' + k }));
  return el('article', { class: 'story' }, [el('div', {}, [el('div', {}, [el('div', {}, [el('span', {}, [...links])])])])]);
}
{
  const stories = Array.from({ length: 30 }, (_, i) => story(i + 1));
  const doc = makeDoc([el('main', {}, [el('section', {}, stories)])]);
  const r = run(doc, 'a[href="/item?id=1"]', 'c1');
  check('HN: the list is the 30 stories', r.list && r.list.count === 30, r.list);
  check('HN: the first story is 1/30', r.list && r.list.index === 1, r.list);
  check('HN: only the story index is dropped', r.list && r.list.selector === 'body>main>section>article>div>div>div>span>a:nth-of-type(5)', r.list);
  const r7 = run(doc, 'a[href="/item?id=7"]', 'c7');
  check('HN: the seventh story is 7/30 on the same selector', r7.list && r7.list.index === 7 && r7.list.selector === r.list.selector, r7.list);
}

// 2. THE GITHUB SHAPE: ten result cards; the repo link inside each card's h3.
{
  const cards = Array.from({ length: 10 }, (_, i) =>
    el('div', { class: 'result' }, [el('div', {}, [el('h3', {}, [el('a', { href: '/repo' + i, 'aloha-id': 'r' + i })])])]));
  const doc = makeDoc([el('div', {}, [el('main', {}, cards)])]);
  const r = run(doc, 'a[href="/repo0"]', 'r0');
  check('GitHub: the top result is 1/10 even though its own selector is unique', r.list && r.list.index === 1 && r.list.count === 10, r.list);
}

// 3. NOTHING REPEATS: no bracket.
{
  const doc = makeDoc([el('main', {}, [el('form', {}, [el('button', { 'aloha-id': 'b1' })])])]);
  check('a lone control gets no list', run(doc, '', 'b1').list === undefined);
}

// 4. SIBLINGS OF THE SAME TAG BUT A DIFFERENT CLASS are not the same item.
{
  const doc = makeDoc([el('div', { class: 'promo' }, [el('a', { 'aloha-id': 'p' })]), el('div', { class: 'footer' }, [el('a', {})])]);
  check('different classes are not a list', run(doc, '', 'p').list === undefined);
}

// 5. The element outside <body>'s tree (a shadow root / an unattached node): no bracket, no throw.
{
  const orphan = el('div', {}, [el('a', { 'aloha-id': 'o' }), el('a', {})]);
  const doc = makeDoc([el('main', {})]);
  const q = doc.querySelectorAll; doc.querySelectorAll = s => s === '[aloha-id]' ? [orphan.children[0]] : q(s);
  check('an element outside body gets no list', run(doc, '', 'o').list === undefined);
}

console.log(failures ? `${failures} FAILED` : 'all list-position checks passed');
process.exit(failures ? 1 : 0);
