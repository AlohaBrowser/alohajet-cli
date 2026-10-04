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
//  12. an implicit label wrapping TWO fields                                -> refused (not label.control's first)
//  13. aria-controls as a list                                              -> every token resolved
//  14. a field disabled by an ancestor fieldset, or through ARIA            -> not a candidate, not listed
//  15. a password-LIKE text field (name="password")                         -> never resolved to
//  16. a unique candidate with no aloha-id                                  -> refused, not a silent redirect
//  17. more than twelve fields                                              -> twelve named, the total counted

const fs = require('fs');
const path = require('path');

const swift = fs.readFileSync(path.join(__dirname, '..', '..', 'Sources', 'BrowserTools', 'Runtime', 'PageBridge.swift'), 'utf8');
const begin = swift.indexOf('// BEGIN type-probe js');
const end = swift.indexOf('// END type-probe js');
if (begin < 0 || end < 0) { console.error('markers not found in PageBridge.swift'); process.exit(2); }
// The Swift literal escapes backslashes (`\\s`); undo that so JS sees `\s`.
const source = swift.slice(begin, end).replace(/\\\\/g, '\\');

// The sensitive-field predicate the probe consults is the one the DOM walker ships
// (`sensitiveFieldPredicateJS`, interpolated above the markers). Take it from its own source too.
const predicateSwift = fs.readFileSync(path.join(__dirname, '..', '..', 'Sources', 'BrowserTools', 'Runtime', 'SensitiveFieldScript.swift'), 'utf8');
const predStart = predicateSwift.indexOf('function __alohaIsSensitiveField(');
if (predStart < 0) { console.error('__alohaIsSensitiveField not found in SensitiveFieldScript.swift'); process.exit(2); }
let depth = 0, predEnd = -1;
for (let i = predicateSwift.indexOf('{', predStart); i < predicateSwift.length; i++) {
  if (predicateSwift[i] === '{') depth++;
  else if (predicateSwift[i] === '}') { depth--; if (depth === 0) { predEnd = i + 1; break; } }
}
const predicate = predicateSwift.slice(predStart, predEnd);

// The source is a STATEMENT (one function declaration); evaluate it and hand the function back.
const resolveTypeTarget = new Function(predicate + '\n' + source + '\nreturn resolveTypeTarget;')();

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
    + predicate + '\n' + shippedSource + '\n  return resolveTypeTarget(el, document);\n})')();
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
    // `<fieldset disabled>` above the element: `:disabled` matches, the property does not.
    effectivelyDisabled: spec.effectivelyDisabled === true,
    isContentEditable: spec.contentEditable === true,
    _parent: null,
    _next: null,
    labels: [],
    focused: false,
    getAttribute(k) { return Object.prototype.hasOwnProperty.call(this.attrs, k) ? this.attrs[k] : null; },
    matches(sel) { return sel === ':disabled' && (this.disabled || this.effectivelyDisabled); },
    focus() { this.focused = true; doc.activeElement = this; },
    scrollIntoView() {},
    // What `__alohaIsSensitiveField` reads off a real element.
    get type() { return this.getAttribute('type') || ''; },
    get name() { return this.getAttribute('name') || ''; },
    get id() { return this.getAttribute('id') || ''; },
    get placeholder() { return this.getAttribute('placeholder') || ''; },
    get htmlFor() { return this.getAttribute('for'); },
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
check('and the enumeration is not computed on the successful path', r.fields === '' && r.fieldsTotal === '0');

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
check('and the total matches what is listed when nothing is cut', r.fieldsTotal === String(r.fields.split(' | ').length));

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

// 12. An IMPLICIT label wrapping two fields. `label.control` would answer the first one and hide
//     the second from the count; the probe walks the label instead and refuses.
const twoInLabel = makeEl({ tag: 'LABEL', children: [
  makeEl({ tag: 'SPAN', attrs: { 'aloha-id': 'i-span' } }),
  makeEl({ tag: 'INPUT', attrs: { 'aloha-id': 'i-a', type: 'text' } }),
  makeEl({ tag: 'INPUT', attrs: { 'aloha-id': 'i-b', type: 'text' } }),
]});
register(twoInLabel);
r = probe(twoInLabel.children[0]);
check('an implicit label holding two fields is refused with the count', r.acceptsText === false && r.ambiguous === '2');

// 13. `aria-controls` is a whitespace-separated id list: every token is resolved.
const editor = makeEl({ tag: 'TEXTAREA', attrs: { 'aloha-id': 'ac-editor', id: 'editor' } });
const help = makeEl({ tag: 'DIV', attrs: { 'aloha-id': 'ac-help', id: 'help' } });
register(editor); register(help);
const toggle = makeEl({ tag: 'SPAN', attrs: { 'aloha-id': 'ac-span', 'aria-controls': 'editor  help' } });
register(toggle);
r = probe(toggle);
check('aria-controls with two tokens resolves the one field among them', r.acceptsText === true && r.redirectedTo === 'ac-editor');
const second = makeEl({ tag: 'INPUT', attrs: { 'aloha-id': 'ac-second', id: 'second', type: 'text' } });
register(second);
const toggle2 = makeEl({ tag: 'SPAN', attrs: { 'aloha-id': 'ac-span2', 'aria-controls': 'editor second' } });
register(toggle2);
r = probe(toggle2);
check('and two fields among the tokens is a refusal with the count', r.acceptsText === false && r.ambiguous === '2');

// 14. Effective disabled state: a field inside `<fieldset disabled>` (matches ':disabled') and a
//     custom field that says aria-disabled / aria-readonly are neither candidates nor listed.
const fieldsetWrap = makeEl({ tag: 'DIV', attrs: { 'aloha-id': 'fs-wrap' }, children: [
  makeEl({ tag: 'INPUT', attrs: { 'aloha-id': 'fs-in', type: 'text', name: 'fsfield' }, effectivelyDisabled: true }),
]});
register(fieldsetWrap);
r = probe(fieldsetWrap);
check('a field disabled by its fieldset is not resolved to', r.acceptsText === false && r.redirectedTo === '');
check('and is not listed', !r.fields.includes('fs-in'));
const ariaWrap = makeEl({ tag: 'DIV', attrs: { 'aloha-id': 'ar-wrap' }, children: [
  makeEl({ tag: 'INPUT', attrs: { 'aloha-id': 'ar-in', type: 'text', 'aria-disabled': 'true' } }),
]});
register(ariaWrap);
r = probe(ariaWrap);
check('an aria-disabled field is not resolved to', r.acceptsText === false && r.redirectedTo === '');
const ariaRO = makeEl({ tag: 'DIV', attrs: { 'aloha-id': 'ro-wrap' }, children: [
  makeEl({ tag: 'INPUT', attrs: { 'aloha-id': 'ro-in', type: 'text', 'aria-readonly': 'true' } }),
]});
register(ariaRO);
r = probe(ariaRO);
check('an aria-readonly field is not resolved to', r.acceptsText === false && r.redirectedTo === '');

// 15. A password-LIKE text field: type="text" but name="password". The Swift classifier refuses
//     it when the id is passed directly; the redirect must not be a way around that.
const pwLike = makeEl({ tag: 'LABEL', children: [
  makeEl({ tag: 'SPAN', attrs: { 'aloha-id': 'pl-span' } }),
  makeEl({ tag: 'INPUT', attrs: { 'aloha-id': 'pl-in', type: 'text', name: 'user_password' } }),
]});
register(pwLike);
r = probe(pwLike.children[0]);
check('a password-like text field is never resolved to', r.acceptsText === false && r.redirectedTo === '');
check('and never listed', !r.fields.includes('pl-in'));

// 16. A unique candidate with NO aloha-id (a field added since the last walk): refuse rather than
//     type into something the receipt cannot name.
const noId = makeEl({ tag: 'DIV', attrs: { 'aloha-id': 'ni-wrap' }, children: [
  makeEl({ tag: 'INPUT', attrs: { type: 'text', name: 'fresh' } }),
]});
register(noId);
r = probe(noId);
check('a candidate without an aloha-id is not a redirect', r.acceptsText === false && r.redirectedTo === '');
check('and nothing was focused', doc.activeElement === null);

// 17. More than twelve fields: twelve are named, the total is counted, so the refusal can say the
//     list is partial instead of posing as the whole page.
const big = makeEl({ tag: 'FORM', attrs: { 'aloha-id': 'big-form' },
  children: Array.from({ length: 15 }, (_, i) => makeEl({ tag: 'INPUT', attrs: { 'aloha-id': 'big-' + i, type: 'text', name: 'f' + i } })) });
register(big);
r = probe(lone);
check('twelve fields are named', r.fields.split(' | ').length === 12);
check('and the total counts every eligible field on the page', Number(r.fieldsTotal) > 12
      && Number(r.fieldsTotal) === doc.querySelectorAll('input, textarea, [contenteditable]').filter(
        f => f.getAttribute('aloha-id') && !f.readOnly && !f.disabled && !f.effectivelyDisabled
          && f.getAttribute('aria-disabled') !== 'true' && f.getAttribute('aria-readonly') !== 'true'
          && !['password', 'checkbox'].includes(f.getAttribute('type')) && !(f.getAttribute('name') || '').includes('password')).length);

console.log(pass + '/' + (pass + fail) + ' type probe assertions pass');
process.exit(fail ? 1 : 0);
