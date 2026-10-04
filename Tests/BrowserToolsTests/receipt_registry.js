// RECEIPTS.md is the one list of what the client sends llmdex: every receipt bracket and every
// resolver pseudo. This harness keeps it true. It fails when
//   - the resolver's PROC list and the doc's pseudo table differ,
//   - a bracket the Swift sources write (`" [name=`) is not in the doc's bracket table, or one
//     listed there is written nowhere,
//   - an address builder spells a `:name(` that is neither a resolver pseudo nor plain CSS,
//   - `selectorNote` writes its brackets in an order other than the doc's.
// llmdex cannot see a new pseudo (it reads as CSS) or a new bracket (it reads as prose), so a
// change to either must come with the doc, and the doc goes to llmdex.
// Run with:  node Tests/BrowserToolsTests/receipt_registry.js
const fs = require('fs');
const path = require('path');
const root = path.join(__dirname, '..', '..');
const read = p => fs.readFileSync(path.join(root, p), 'utf8');

let failed = 0;
function check(name, ok, detail) {
  if (ok) console.log('ok   ' + name);
  else { failed++; console.log('FAIL ' + name + (detail ? '\n     ' + detail : '')); }
}
const diff = (a, b) => [...a].filter(x => !b.has(x)).sort();

const doc = read('RECEIPTS.md');
function section(title) {
  const start = doc.indexOf('## ' + title);
  if (start < 0) throw new Error('RECEIPTS.md has no section "' + title + '"');
  const next = doc.indexOf('\n## ', start + 3);
  return doc.slice(start, next < 0 ? doc.length : next);
}

// ---- pseudos -------------------------------------------------------------------------------
const docPseudos = new Set([...section('Resolver pseudos').matchAll(/^\| `:([a-z-]+)\(/gm)].map(m => m[1]));
const proc = /const PROC = \[([^\]]*)\]/.exec(read('Sources/BrowserTools/Runtime/SelectorResolverScript.swift'));
const resolverPseudos = new Set([...proc[1].matchAll(/'([a-z-]+)'/g)].map(m => m[1]));
check('resolver pseudos are all in RECEIPTS.md', diff(resolverPseudos, docPseudos).length === 0,
  'missing from the doc: ' + diff(resolverPseudos, docPseudos).join(', '));
check('RECEIPTS.md lists no pseudo the resolver lacks', diff(docPseudos, resolverPseudos).length === 0,
  'not in PROC: ' + diff(docPseudos, resolverPseudos).join(', '));

// Address builders may only write resolver pseudos or standard CSS ones.
const CSS = new Set(['nth-of-type', 'nth-child', 'nth-last-of-type', 'nth-last-child', 'not', 'is', 'where', 'has']);
const builders = ['Tabs/StepTraceSelector.swift', 'Tools/PageToolsSupport.swift', 'Tools/GetText.swift',
  'Runtime/MainHeadingReceipt.swift', 'Runtime/ReceiptProbes.swift'];
const spelled = new Set();
for (const f of builders) for (const m of read('Sources/BrowserTools/' + f).matchAll(/:([a-z][a-z-]*)\(/g)) spelled.add(m[1]);
const unknown = [...spelled].filter(p => !resolverPseudos.has(p) && !CSS.has(p)).sort();
check('address builders write only resolver pseudos or CSS', unknown.length === 0, 'unknown: ' + unknown.join(', '));

// ---- brackets ------------------------------------------------------------------------------
const docBrackets = new Set([...section('Receipt brackets').matchAll(/^\| `\[([a-z-]+)=/gm)].map(m => m[1]));
const written = new Set();
function walk(dir) {
  for (const entry of fs.readdirSync(path.join(root, dir), { withFileTypes: true })) {
    const rel = dir + '/' + entry.name;
    if (entry.isDirectory()) { walk(rel); continue; }
    if (!entry.name.endsWith('.swift')) continue;
    for (const line of read(rel).split('\n')) {
      if (/^\s*\/\//.test(line)) continue;
      for (const m of line.matchAll(/" \[([a-z-]+)=/g)) written.add(m[1]);
    }
  }
}
walk('Sources/BrowserTools');
check('brackets the client writes are all in RECEIPTS.md', diff(written, docBrackets).length === 0,
  'missing from the doc: ' + diff(written, docBrackets).join(', '));
check('RECEIPTS.md lists no bracket the client never writes', diff(docBrackets, written).length === 0,
  'written nowhere: ' + diff(docBrackets, written).join(', '));

// The selectorNote writer: every bracket it appends is listed, in the order the doc gives.
const note = read('Sources/BrowserTools/Tools/PageToolsSupport.swift');
const body = note.slice(note.indexOf('var note = " [selector='), note.indexOf('static let submittedNote'));
const order = [...new Set([...body.matchAll(/" \[([a-z-]+)=/g)].map(m => m[1]))];
const docOrder = [...section('Receipt brackets').matchAll(/^\| `\[([a-z-]+)=/gm)].map(m => m[1]).filter(b => order.includes(b));
check('selectorNote writes brackets in the documented order', order.join(',') === docOrder.join(','),
  'code: ' + order.join(',') + '\n     doc:  ' + docOrder.join(','));

console.log(failed ? `\n${failed} check(s) FAILED` : '\nall checks passed');
process.exit(failed ? 1 : 0);
