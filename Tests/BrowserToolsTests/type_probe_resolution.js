// Runs the page-side type probe (`AgentBrowserBridge.type`'s `resolveTypeTarget`) against a fake DOM.
// The source is EXTRACTED from PageBridge.swift by its BEGIN/END markers, so this exercises the bytes
// that ship rather than a copy that can drift. Run with:  node Tests/BrowserToolsTests/type_probe_resolution.js
//
// The shapes are the ones actually seen on WebArena's t625 and t648, and the ones the probe must
// leave alone:
//   1. a <span> inside the <label> that wraps a textarea (the t625 shape)  -> resolves, says so
//   2. a <label for> pointing at an input elsewhere                         -> resolves by id
//   3. a plain div wrapping exactly one input                               -> resolves
//   4. a wrapper holding TWO fields                                         -> refused with the count
//   5. a bare span with nothing associated                                  -> refused
//   6. a label wrapping a PASSWORD field                                    -> never resolved to
//   7. a wrapper around a readonly field                                    -> not a candidate
//   8. a real textarea passed directly                                      -> unchanged path, no redirect
//   9. a button                                                             -> refused, nothing to resolve to
//  10. the refusal enumerates the page's typable fields, and only those
//  11. the enumeration is NOT computed on the successful path

const fs = require('fs');
const path = require('path');

const swift = fs.readFileSync(path.join(__dirname, '..', '..', 'Sources', 'BrowserTools', 'Runtime', 'PageBridge.swift'), 'utf8');
const begin = swift.indexOf('// BEGIN type-probe js');
const end = swift.indexOf('// END type-probe js');
if (begin < 0 || end < 0) { console.error('markers not found in PageBridge.swift'); process.exit(2); }
// The Swift literal escapes backslashes; undo that so JS sees what the page sees.
const source = swift.slice(begin, end).replace(/\\\\/g, '\\');
// The source is a STATEMENT (one function declaration); evaluate it and hand the function back.
const resolveTypeTarget = new Function(source + '\nreturn resolveTypeTarget;')();

// THE SHAPE THE BRIDGE SHIPS, compiled as-is. The wrapper in PageBridge.swift inlines the source as
// a statement and then calls the function on its own line. The source ENDS in a `//` comment (the
// END marker): a call placed on that comment's line would make the whole probe a SyntaxError that
// the bridge's `try?` silences, which is exactly what happened to the overlay hider on 2026-09-17.
// So the shipped shape is compiled here, END comment included.
const shippedSource = swift.slice(begin, end + '// END type-probe js'.length).replace(/\\\\/g, '\\');
let shippedProbe;
try {
  shippedProbe = new Function(
    'return (function() {\n  var el = arguments[0]; var document = arguments[1];\n  if (!el) return { found: false };\n'
    + shippedSource + '\n  return resolveTypeTarget(el, document);\n})')();
} catch (e) {
  console.log('FAIL: the shipped probe shape does not compile: ' + e.message);
  process.exit(1);
}

// MARK: fake DOM

const byId = {};
const roots = [];
const doc = {
  activeElement: null,
  getElementById: (id) => byId[id] || null,
  querySelectorAll: (sel) => {
    const out = [];
    const want = sel.split(',').map(x => x.trim());
    for (const r of roots) {
      const visit = (n) => {
        const t = n.tagName.toLowerCase();
        if (want.includes(t) || (want.includes('[contenteditable]') && n.isContentEditable)) out.push(n);
        for (const c of n.children) visit(c);
      };
      visit(r);
    }
    return out;
  },
};

function makeEl(spec) {
  const el = {
    tagName: spec.tag,
    attrs: spec.attrs || {},
    children: spec.children || [],
    disabled: spec.disabled === true,
    readOnly: spec.readOnly === true,
    isContentEditable: spec.contentEditable === true,
    _parent: null,
    _next: null,
    labels: [],
    focused: false,
    getAttribute(k) { return Object.prototype.hasOwnProperty.call(this.attrs, k) ? this.attrs[k] : null; },
    focus() { this.focused = true; doc.activeElement = this; },
    scrollIntoView() {},
    get htmlFor() { return this.getAttribute('for'); },
    get control() {
      const f = this.getAttribute('for');
      if (f) return byId[f] || null;
      const inner = this.querySelectorAll('input, textarea, [contenteditable]');
      return inner.length ? inner[0] : null;
    },
    closest(sel) {
      let n = this;
      const want = sel.toUpperCase();
      while (n) { if (n.tagName === want) return n; n = n._parent; }
      return null;
    },
    querySelectorAll(sel) {
      const want = sel.split(',').map(s => s.trim());
      const out = [];
      const walk = (n) => {
        for (const c of n.children) {
          const t = c.tagName.toLowerCase();
          if (want.includes(t) || (want.includes('[contenteditable]') && c.isContentEditable)) out.push(c);
          walk(c);
        }
      };
      walk(this);
      return out;
    },
    get nextElementSibling() { return this._next; },
  };
  for (const c of el.children) c._parent = el;
  for (let i = 0; i < el.children.length - 1; i++) el.children[i]._next = el.children[i + 1];
  return el;
}

function register(el) {
  if (!el._parent) roots.push(el);
  const id = el.getAttribute('id');
  if (id) byId[id] = el;
  for (const c of el.children) register(c);
}

let pass = 0, fail = 0;
function check(label, cond) { if (cond) pass++; else { fail++; console.log('FAIL: ' + label); } }
function probe(el) { doc.activeElement = null; return resolveTypeTarget(el, doc); }

// 1. A label wrapping its textarea -- the t625 shape.
const wrapLabel = makeEl({ tag: 'LABEL', children: [
  makeEl({ tag: 'SPAN', attrs: { 'aloha-id': 'x-span' } }),
  makeEl({ tag: 'TEXTAREA', attrs: { 'aloha-id': 'x-body', id: 'body' } }),
]});
register(wrapLabel);
let r = probe(wrapLabel.children[0]);
check('label wrapper resolves to its textarea', r.acceptsText === true && r.redirectedTo === 'x-body');
check('and it focused that field', r.focused === true && wrapLabel.children[1].focused === true);
check('and it reports the tag it went to', r.redirectedTag === 'TEXTAREA');
check('and the tag it reports for the id passed is the span', r.tag === 'SPAN');

// 2. label[for] pointing at an input elsewhere.
const target2 = makeEl({ tag: 'INPUT', attrs: { 'aloha-id': 'y-in', id: 'title', type: 'text' } });
register(target2);
const lbl2 = makeEl({ tag: 'LABEL', attrs: { 'aloha-id': 'y-lbl', for: 'title' } });
register(lbl2);
r = probe(lbl2);
check('label[for] resolves by id', r.acceptsText === true && r.redirectedTo === 'y-in');

// 3. A plain div wrapping exactly one input.
const wrap3 = makeEl({ tag: 'DIV', attrs: { 'aloha-id': 'z-wrap' }, children: [
  makeEl({ tag: 'INPUT', attrs: { 'aloha-id': 'z-in', type: 'text' } }),
]});
register(wrap3);
r = probe(wrap3);
check('a wrapper around one field resolves', r.acceptsText === true && r.redirectedTo === 'z-in');

// 4. TWO fields inside -- must refuse rather than guess.
const wrap4 = makeEl({ tag: 'DIV', attrs: { 'aloha-id': 'w-wrap' }, children: [
  makeEl({ tag: 'INPUT', attrs: { 'aloha-id': 'w-a', type: 'text' } }),
  makeEl({ tag: 'TEXTAREA', attrs: { 'aloha-id': 'w-b' } }),
]});
register(wrap4);
r = probe(wrap4);
check('two candidate fields is a refusal, not a guess', r.acceptsText === false && r.ambiguous === '2');
check('and nothing was focused', doc.activeElement === null);

// 5. A bare span with nothing associated -- still refuses.
const lone = makeEl({ tag: 'SPAN', attrs: { 'aloha-id': 'l-span' } });
register(lone);
r = probe(lone);
check('an unassociated span still refuses', r.acceptsText === false && r.ambiguous === '0');

// 6. A password field is NEVER a redirect target -- the credential refusal must not be routed
//    around, since it is keyed on the id the model passed.
const wrap6 = makeEl({ tag: 'LABEL', children: [
  makeEl({ tag: 'SPAN', attrs: { 'aloha-id': 'p-span' } }),
  makeEl({ tag: 'INPUT', attrs: { 'aloha-id': 'p-pw', type: 'password' } }),
]});
register(wrap6);
r = probe(wrap6.children[0]);
check('a password field is never resolved to', r.acceptsText === false && r.redirectedTo === '');

// 7. A disabled/readonly field is not a candidate either.
const wrap7 = makeEl({ tag: 'DIV', attrs: { 'aloha-id': 'd-wrap' }, children: [
  makeEl({ tag: 'INPUT', attrs: { 'aloha-id': 'd-in', type: 'text' }, readOnly: true }),
]});
register(wrap7);
r = probe(wrap7);
check('a readonly field is not resolved to', r.acceptsText === false);

// 8. THE UNCHANGED PATH: a real textarea passed directly still just works, with no redirect.
const plain = makeEl({ tag: 'TEXTAREA', attrs: { 'aloha-id': 't-body' } });
register(plain);
r = probe(plain);
check('a typable element is unaffected', r.acceptsText === true && r.redirectedTo === '' && r.ambiguous === '0');
check('and is still the focused target', r.focused === true && plain.focused === true);
check('and the enumeration is not computed on the successful path', r.fields === '');

// 9. A button is still refused -- it is not text, and it has no field to resolve to.
const btn = makeEl({ tag: 'BUTTON', attrs: { 'aloha-id': 'b-1' } });
register(btn);
r = probe(btn);
check('a button is still refused', r.acceptsText === false);

// 10. The enumeration the refusal offers instead of "go and look". The t625 shape: a page whose
//     typable fields are a URL input, a Title textarea and a Body textarea, plus a checkbox, a
//     span and a password field that are NOT offered. The refusal must name the three, and only
//     the three.
const form = makeEl({ tag: 'FORM', attrs: { 'aloha-id': 'f-form' }, children: [
  makeEl({ tag: 'INPUT', attrs: { 'aloha-id': 'f-url', type: 'text', name: 'url' } }),
  makeEl({ tag: 'TEXTAREA', attrs: { 'aloha-id': 'f-title', name: 'title' } }),
  makeEl({ tag: 'TEXTAREA', attrs: { 'aloha-id': 'f-body', name: 'body' } }),
  makeEl({ tag: 'INPUT', attrs: { 'aloha-id': 'f-chk', type: 'checkbox', name: 'help' } }),
  makeEl({ tag: 'SPAN', attrs: { 'aloha-id': 'f-span' } }),
  makeEl({ tag: 'INPUT', attrs: { 'aloha-id': 'f-pw', type: 'password', name: 'pw' } }),
]});
register(form);
r = probe(form.children[4]);   // the span, as t625 did
check('the refusal enumerates the real fields', r.fields.includes('f-body (body) textarea')
      && r.fields.includes('f-title (title) textarea') && r.fields.includes('f-url (url) input'));
check('it does not offer the checkbox', !r.fields.includes('f-chk'));
check('it does not offer the password field', !r.fields.includes('f-pw'));
check('it does not offer the span itself', !r.fields.includes('f-span'));

// A field with no attribute name is named from its label, the way the page already names it.
const labelled = makeEl({ tag: 'LABEL', children: [
  makeEl({ tag: 'SPAN', attrs: { 'aloha-id': 'n-span' } }),
  makeEl({ tag: 'INPUT', attrs: { 'aloha-id': 'n-in', type: 'text' } }),
]});
labelled.children[1].labels = [{ textContent: '  Search terms  ' }];
labelled.children[1].readOnly = true; // so the span is refused rather than resolved
register(labelled);
r = probe(labelled.children[0]);
check('a refusal names a field by its label when it has no name', r.acceptsText === false
      && !r.fields.includes('n-in'));
labelled.children[1].readOnly = false;
r = probe(lone);
check('the label text is the name offered', r.fields.includes('n-in (Search terms) input'));

// 11. THE SHIPPED SHAPE gives the same answer as the extracted function.
const shipped = shippedProbe(wrapLabel.children[0], doc);
check('the shipped wrapper resolves the t625 shape too', shipped.found === true
      && shipped.acceptsText === true && shipped.redirectedTo === 'x-body');
check('and a missing element is still a miss', shippedProbe(null, doc).found === false);

console.log(pass + '/' + (pass + fail) + ' type probe assertions pass');
process.exit(fail ? 1 : 0);
