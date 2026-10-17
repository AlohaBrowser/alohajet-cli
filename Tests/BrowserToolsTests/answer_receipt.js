// Runs the answer-receipt page matcher (`AnswerReceipt.pageMatchExpression`, the bytes that ship)
// against fake pages shaped like the batch's own: which elements of the final page the answer
// repeats, minus what the task already said.
//
// 2026-10-01: answer receipts were taken from the answer's bold/quoted spans, so github-ss-r80's
// "**Latest release name: v3.8.5**" yielded no receipt for v3.8.5. The page now decides.
//
// Ported from AlohaBrowser/alohajet `Tests/AgentRuntimeTests/answer_receipt.js` (windows-on-snips)
// with the matcher, now `Sources/BrowserTools/Runtime/AnswerReceipt.swift` in this package.
// Run with:  node Tests/BrowserToolsTests/answer_receipt.js
const fs = require('fs');
const path = require('path');
const src = fs.readFileSync(path.join(__dirname, '..', '..', 'Sources', 'BrowserTools', 'Runtime', 'AnswerReceipt.swift'), 'utf8');
const seg = src.slice(src.indexOf('static func pageMatchExpression('));
const template = seg.slice(seg.indexOf('#"""') + 4, seg.indexOf('"""#'));
const cleanSeg = src.slice(src.indexOf('static let cleanupExpression'));
const cleanup = cleanSeg.slice(cleanSeg.indexOf('#"""') + 4, cleanSeg.indexOf('"""#'));
const maxValues = Number(/public static let maxValues = (\d+)/.exec(src)[1]);

// ---- a tree DOM with just what the matcher touches ------------------------------------------
function el(tag, attrs = {}, children = [], text = '', visible = true) {
  const e = { tagName: tag.toUpperCase(), _attrs: { ...attrs }, _text: text, parentElement: null, children: [], visible,
    getAttribute(k) { return k in this._attrs ? this._attrs[k] : null; },
    setAttribute(k, v) { this._attrs[k] = String(v); },
    removeAttribute(k) { delete this._attrs[k]; },
    getBoundingClientRect() { return this.visible ? { width: 10, height: 10 } : { width: 0, height: 0 }; },
    get innerText() { return [this._text, ...this.children.map(c => c.innerText)].filter(Boolean).join(' '); },
    get firstElementChild() { return this.children[0] || null; },
    get nextElementSibling() { const s = this.parentElement ? this.parentElement.children : []; return s[s.indexOf(this) + 1] || null; },
    querySelectorAll(q) {
      const out = []; (function walk(n) { for (const c of n.children) { out.push(c); walk(c); } })(this);
      if (q === '*') return out;
      const m = /^\[([a-z-]+)\^="([^"]*)"\]$/.exec(q);   // the cleanup's prefix query
      if (!m) throw new Error('fake engine: ' + q);
      return out.filter(e => typeof e._attrs[m[1]] === 'string' && e._attrs[m[1]].startsWith(m[2]));
    } };
  for (const c of children) { c.parentElement = e; e.children.push(c); }
  return e;
}
function run(body, answer, prompt, hints = [], reads = []) {
  const document = { body };
  const expr = template.split('\\#(answerLiteral)').join(JSON.stringify(answer)).split('\\#(promptLiteral)').join(JSON.stringify(prompt))
    .split('\\#(hintsLiteral)').join(JSON.stringify(hints)).split('\\#(readsLiteral)').join(JSON.stringify(reads)).split('\\#(maxValues)').join(String(maxValues))
    .split('\\#(StepTraceSelector.maxPathSegments)').join('32');
  const out = new Function('document', 'return ' + expr.trim())(document);
  return out ? JSON.parse(out) : [];
}
let failures = 0;
function check(name, cond, detail) { console.log((cond ? 'ok   ' : 'FAIL ') + name + (cond ? '' : '  ' + JSON.stringify(detail))); if (!cond) failures++; }

const githubTask = "Go to github.com and use its search box to look up 'shadowsocks'. Narrow the results to Go, sort them by most stars, open the top repository, go to its Releases page and tell me the latest release name.";

// 1. github-ss-r80: the version inside a bold sentence. The page holds "v3.8.5" (a span in a link,
//    nested), "MHSanaei/3x-ui", the badge "Latest", the heading "Releases"; the task says "latest"
//    and "Releases", so those two are the question's words, not values.
{
  const page = el('body', {}, [
    el('header', {}, [el('a', { href: '/MHSanaei/3x-ui' }, [], 'MHSanaei/3x-ui')]),
    el('h2', {}, [], 'Releases'),
    el('nav', {}, [el('ul', {}, [
      el('li', {}, [el('a', { href: '#a' }, [el('span', {}, [], 'Dev build 99047c0a')])]),
      el('li', {}, [el('a', { href: '#b' }, [el('span', {}, [], 'v3.8.5')])]),
    ])]),
    el('span', {}, [], 'Latest'),
  ]);
  const answer = 'I opened the top repository **MHSanaei/3x-ui**. **Latest release name: v3.8.5** (marked Latest).';
  const r = run(page, answer, githubTask, ['MHSanaei/3x-ui', 'Latest release name: v3.8.5']);
  const texts = r.map(x => x.text);
  check('v3.8.5 is found inside a bold sentence', texts.includes('v3.8.5'), texts);
  check('the repository the answer named is found', texts.includes('MHSanaei/3x-ui'), texts);
  check("the task's own words are not values (Latest, Releases)", !texts.includes('Latest') && !texts.includes('Releases'), texts);
  check('the innermost element: the span, not its link', r.find(x => x.text === 'v3.8.5').path.endsWith('>a>span'), r);
  check('the release the answer did not name is not taken', !texts.some(t => /Dev build/.test(t)), texts);
  check('a temporary id is stamped where the element had none', r.every(x => /^aloha-answer-\d+$/.test(x.id)), r);
}
// 2. Case, spacing and punctuation do not matter; a lone short common word is never a value.
{
  const page = el('body', {}, [el('p', {}, [], 'Approachable  Swift Concurrency'), el('button', {}, [], 'On'), el('a', {}, [], 'top')]);
  const r = run(page, 'The top story is titled "approachable swift concurrency." — turn it on.', 'Open the top story and tell me its title.');
  check('title matched across case and punctuation', r.length === 1 && r[0].text === 'Approachable Swift Concurrency', r);
}
// 3. NUMBERS when no words match: the page writes "3.7km", the model "3.7 kilometers".
{
  const page = el('body', {}, [el('div', {}, [el('span', {}, [], '3.7km'), el('span', {}, [], '50 min')]), el('span', {}, [], '24 steps')]);
  const r = run(page, '**Walking distance**: 3.7 kilometers. **Estimated time**: 50 minutes.', 'How far is the walk from the Eiffel Tower to the Louvre on foot?');
  const texts = r.map(x => x.text);
  check('numbers fallback: 3.7km and 50 min', texts.includes('3.7km') && texts.includes('50 min') && !texts.includes('24 steps'), texts);
}
// 4. A number the task already gave is not new information; hidden elements never count.
{
  const page = el('body', {}, [el('span', {}, [], '2024'), el('span', {}, [], 'v9.9.9', false)]);
  const r = run(page, 'In 2024 the latest was v9.9.9', 'What was the latest release in 2024?');
  check("the task's own number and a hidden element are skipped", r.length === 0, r);
}
// 5. An element that already has an aloha-id keeps it; the cap holds.
{
  const items = Array.from({ length: 8 }, (_, i) => el('li', { 'aloha-id': 'x' + i }, [], 'Item number ' + i));
  const page = el('body', {}, [el('ul', {}, items)]);
  const r = run(page, items.map(i => i._text).join(', '), 'List them');
  check('cap at maxValues', r.length === maxValues, r.length);
  check('an existing aloha-id is kept', r.every(x => /^x\d$/.test(x.id)), r);
}

// 6. A LONE SHORT NUMBER is not a value (github-ss-r82: the answer's numbered steps "2." "4."
//    matched a tab counter "2" and a count "4"); a version or a 3+-digit number still is.
{
  const page = el('body', {}, [el('span', {}, [], '2'), el('span', {}, [], '4'), el('span', {}, [], 'v3.8.5'), el('span', {}, [], '512')]);
  const r = run(page, '1. Searched\n2. Filtered\n4. Opened. The latest is **v3.8.5**, 512 stars.', githubTask, ['v3.8.5']);
  const texts = r.map(x => x.text);
  check('bare "2" and "4" are not values; v3.8.5 and 512 are', !texts.includes('2') && !texts.includes('4') && texts.includes('v3.8.5') && texts.includes('512'), texts);
}
// 7. THE ANSWER QUOTES PART OF A LONGER PAGE TEXT (hn-swift-r82: a clean title for the page's longer
//    one): a bold / quoted span of 2+ words matches the element whose text contains it.
{
  const title = el('span', { class: 'titleline' }, [el('a', {}, [], 'Fucking Approachable Swift Concurrency')]);
  const page = el('body', {}, [el('table', {}, [el('tbody', {}, [el('tr', {}, [el('td', {}, [title])])])]), el('a', {}, [], '98 comments')]);
  const r = run(page, 'The top story’s comment thread is titled **“Approachable Swift Concurrency.”**',
    "Search Hacker News for 'Swift concurrency', open the top story's comment thread and tell me its title.", ['Approachable Swift Concurrency']);
  check('a quoted part of a longer title finds the title element', r.length >= 1 && r[0].text === 'Fucking Approachable Swift Concurrency' && r[0].path.endsWith('>a'), r);
  // A one-word hint does not widen: "Concurrency" alone must not match every text containing it.
  const r2 = run(page, 'It is about **Concurrency**.', 'Tell me the topic.', ['Concurrency']);
  check('a one-word hint does not match by containment', r2.length === 0, r2);
}

// 8. A LONE WORD is a value only when the answer bolded or quoted it (github-ss-r84: the answer used
//    the word "next", and the page's pagination link "Next" became a receipt).
{
  const page = el('body', {}, [el('a', { href: '?page=2' }, [], 'Next'), el('span', {}, [], 'Xray'), el('span', {}, [], 'v3.8.5')]);
  const r = run(page, 'Next, I opened the releases. The core is **Xray** and the latest is v3.8.5.', githubTask, ['Xray']);
  const texts = r.map(x => x.text);
  check('a lone unhinted word is not a value; a hinted one and v3.8.5 are',
    !texts.includes('Next') && texts.includes('Xray') && texts.includes('v3.8.5'), texts);
}

// 9. THE ELEMENT THE TURN READ (github-ss-r87): v3.8.5 sits in a sidebar tag list above the release
//    heading the run read with get_text. Without a read the first one in the page wins, as before; with
//    the heading's aloha-id read, the heading; with a read of the whole release row, the value inside it.
{
  const page = () => el('body', {}, [
    el('nav', {}, [el('ul', {}, [el('li', {}, [el('a', { 'aloha-id': 'd61f-nav2' }, [el('span', {}, [], 'v3.8.5')])])])]),
    el('section', { 'aloha-id': 'd61f-row' }, [
      el('span', {}, [el('a', { 'aloha-id': 'd61f-6c0653d', href: '/MHSanaei/3x-ui/releases/tag/v3.8.5' }, [], 'v3.8.5')]),
      el('span', { 'aloha-id': 'd61f-badge' }, [], 'Latest'),
    ]),
  ]);
  const answer = 'The latest release name is **v3.8.5**.';
  const none = run(page(), answer, githubTask, ['v3.8.5']);
  check('without a read, the first v3.8.5 in the page', none.length === 1 && none[0].path.startsWith('body>nav'), none);
  const read = run(page(), answer, githubTask, ['v3.8.5'], ['d61f-badge', 'd61f-6c0653d']);
  check('with the heading read, the receipt is the element read',
    read.length === 1 && read[0].id === 'd61f-6c0653d' && read[0].path.startsWith('body>section'), read);
  const row = run(page(), answer, githubTask, ['v3.8.5'], ['d61f-row']);
  check('with the row read, the value inside the row', row.length === 1 && row[0].id === 'd61f-6c0653d', row);
  const gone = run(page(), answer, githubTask, ['v3.8.5'], ['d61f-elsewhere']);
  check('a read whose element is gone changes nothing', gone.length === 1 && gone[0].path.startsWith('body>nav'), gone);
}

// 10. THE TEMPORARY IDS LEAVE NO TRACE. No marker attribute rides on a stamped element (the
//     identity probe would read it into `[attrs=]`); the cleanup removes exactly the temporary ids;
//     a temporary id an earlier call left behind is dropped before it can name the wrong element.
function runCleanup(body) {
  const document = { body, querySelectorAll: q => body.querySelectorAll(q) };
  return new Function('document', 'return ' + cleanup.trim())(document);
}
{
  const kept = el('span', { 'aloha-id': '7959-1f3a9c2b' }, [], 'v3.8.5');
  const fresh = el('span', {}, [], 'MHSanaei/3x-ui');
  const stale = el('a', { 'aloha-id': 'aloha-answer-0' }, [], 'Dev build 99047c0a');
  const page = el('body', {}, [el('div', {}, [kept, fresh]), stale]);
  const r = run(page, 'The repository **MHSanaei/3x-ui** has **v3.8.5**.', githubTask, ['MHSanaei/3x-ui', 'v3.8.5']);
  check('a stale temporary id is dropped before matching', stale.getAttribute('aloha-id') === null, stale._attrs);
  const stamped = r.find(x => x.text === 'MHSanaei/3x-ui');
  check('the element without an id gets a temporary one', stamped && /^aloha-answer-\d+$/.test(stamped.id), r);
  check('no marker attribute besides the id', Object.keys(fresh._attrs).join(',') === 'aloha-id', fresh._attrs);
  const removed = runCleanup(page);
  check('the cleanup removes the temporary id', removed === '1' && fresh.getAttribute('aloha-id') === null, { removed, attrs: fresh._attrs });
  check("the cleanup keeps the page's own id", kept.getAttribute('aloha-id') === '7959-1f3a9c2b', kept._attrs);
}

console.log(failures ? `${failures} FAILED` : 'all answer-receipt checks passed');
process.exit(failures ? 1 : 0);
