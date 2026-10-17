// Runs the page-side overlay hider (`AgentBrowserBridge.overlayHiderSource`) against a fake DOM.
// The source is EXTRACTED from ClickReceipts.swift by its BEGIN/END markers, so this exercises the
// bytes that ship rather than a copy that can drift. Run with:  node Tests/BrowserToolsTests/overlay_hider.js
//
// The shapes are the ones the guard exists for and the ones it must leave alone:
//   1. a fixed consent banner appended to <body> covering the target      -> hidden, note
//   2. a dialog + separate fixed backdrop (two layers)                     -> both hidden
//   3. a shadow-DOM host at the body holding a consent widget              -> hidden
//   4. a full-viewport fixed promo layer with no consent words, no form    -> hidden (blanket)
//   5. a full-viewport fixed modal that holds a form (a login, a drawer)   -> left alone
//   6. a small absolutely positioned dropdown covering the target          -> left alone
//   7. nothing covering the target                                          -> empty, nothing touched
//   8. the body scroll lock a consent library sets inline                  -> released only when hidden

const fs = require('fs');
const path = require('path');

const swift = fs.readFileSync(path.join(__dirname, '..', '..', 'Sources', 'BrowserTools', 'Runtime', 'ClickReceipts.swift'), 'utf8');
const begin = swift.indexOf('// BEGIN overlay-hider js');
const end = swift.indexOf('// END overlay-hider js');
if (begin < 0 || end < 0) { console.error('markers not found in ClickReceipts.swift'); process.exit(2); }
// The Swift literal escapes backslashes (`\\s`, `\\u043f`); undo that so JS sees `\s`, `п`.
const source = swift.slice(begin, end).replace(/\\\\/g, '\\');
// The source is STATEMENTS (helpers + two function declarations); evaluate it and hand both back.
const { hideCoveringOverlay, hideConsentLayerContaining } =
  new Function(source + '\nreturn { hideCoveringOverlay, hideConsentLayerContaining };')();

// THE SHAPE THE BRIDGE SHIPS, compiled as-is. Both wrappers in ClickReceipts.swift inline the source
// as statements and then call one function on its own line. The source ENDS in a `//` comment
// (the END marker): an earlier wrapper put `)(el, document, window)` on that comment's line, so
// the whole probe was a SyntaxError the page answered in 2 ms and the bridge's `try?` silenced --
// eight clicks went into a cookie banner on 2026-09-17 while this harness, which added its own
// newline, stayed green. So the shipped shape is compiled here, END comment included.
const shippedSource = swift.slice(begin, end + '// END overlay-hider js'.length).replace(/\\\\/g, '\\');
function shippedWrapper(call) {
  return '(function() {\n  try {\n    var el = arguments[0];\n    if (!el) return "";\n'
    + shippedSource + '\n    return ' + call + '(el, arguments[1], arguments[2]);\n  } catch (e) { return "THREW: " + e.message; }\n})';
}
let shippedProbe, shippedConsentProbe;
try {
  shippedProbe = new Function('return ' + shippedWrapper('hideCoveringOverlay') + ';')();
  shippedConsentProbe = new Function('return ' + shippedWrapper('hideConsentLayerContaining') + ';')();
} catch (e) { console.log('FAIL the bridge-shaped wrapper does not compile -- ' + e.message); process.exit(1); }

// ---- fake DOM -------------------------------------------------------------------------------

function makeEl(spec) {
  const el = {
    tagName: spec.tag || 'div',
    attrs: Object.assign({}, spec.attrs || {}),
    children: [],
    parentElement: null,
    style: Object.assign({ _props: {}, setProperty(k, v) { this._props[k] = v; } }, spec.style || {}),
    position: spec.position || 'static',
    rect: spec.rect || { left: 0, top: 0, width: 0, height: 0 },
    textContent: spec.text || '',
    shadowRoot: spec.shadowText != null ? { textContent: spec.shadowText } : null,
    fields: spec.fields || [],   // selectors it would answer querySelector for
    getAttribute(k) { return Object.prototype.hasOwnProperty.call(this.attrs, k) ? this.attrs[k] : null; },
    setAttribute(k, v) { this.attrs[k] = String(v); },
    getBoundingClientRect() { return this.rect; },
    contains(other) { for (let n = other; n; n = n.parentElement) if (n === this) return true; return false; },
    querySelector(sel) { return this.fields.some(f => sel.indexOf(f) !== -1) ? {} : null; },
    scrollIntoView() {},
    get innerText() { return this.textContent; },
    get hidden() { return this.style._props.display === 'none'; },
  };
  (spec.children || []).forEach(c => { c.parentElement = el; el.children.push(c); });
  return el;
}

function makeDocument(bodyChildren, hit) {
  const html = makeEl({ tag: 'html' });
  const body = makeEl({ tag: 'body', children: bodyChildren });
  body.parentElement = html; html.children.push(body);
  return {
    body, documentElement: html,
    // `hit` decides what elementFromPoint returns; it is re-evaluated each call so hiding a
    // layer can reveal the next one (the backdrop case) or the target itself.
    elementFromPoint() { return hit(); },
    querySelector() { return null },
  };
}
const win = { innerWidth: 1000, innerHeight: 800, getComputedStyle: n => ({ position: n.position }) };
const FULL = { left: 0, top: 0, width: 1000, height: 800 };

let failures = 0;
function check(name, cond, detail) {
  if (cond) console.log('ok   ' + name);
  else { failures++; console.log('FAIL ' + name + (detail ? ' -- ' + detail : '')); }
}

// 1. fixed consent banner at the body
{
  const target = makeEl({ tag: 'a', rect: { left: 100, top: 300, width: 200, height: 40 } });
  const btn = makeEl({ tag: 'button', text: 'Accept All Cookies' });
  const banner = makeEl({ tag: 'div', attrs: { 'aloha-id': '6fdf-4e9c230c' }, position: 'fixed',
    rect: { left: 0, top: 500, width: 1000, height: 300 },
    text: 'By clicking "Accept All Cookies", you agree to the storing of cookies', children: [btn] });
  const doc = makeDocument([target, banner], () => banner.hidden ? target : btn);
  const note = hideCoveringOverlay(target, doc, win);
  check('1 consent banner is hidden', banner.hidden);
  check('1 note names the layer and says nothing was answered',
        /Hid a covering overlay <div aloha-id="6fdf-4e9c230c">/.test(note) && /Nothing was accepted or rejected/.test(note), note);
  check('1 the layer is marked for the DOM walk', banner.getAttribute('data-aloha-hidden-overlay') === '1');
}

// 1b. the SAME case through the bridge-shaped wrapper: it must compile AND return the note.
{
  const target = makeEl({ tag: 'a', rect: { left: 100, top: 300, width: 200, height: 40 } });
  const banner = makeEl({ tag: 'div', position: 'fixed', rect: { left: 0, top: 500, width: 1000, height: 300 }, text: 'This site uses cookies. Accept' });
  const doc = makeDocument([target, banner], () => banner.hidden ? target : banner);
  const note = shippedProbe(target, doc, win);
  check('1b bridge-shaped wrapper hides and reports', /Hid a covering overlay/.test(note) && banner.hidden, note);
}

// 2. dialog + separate backdrop
{
  const target = makeEl({ tag: 'button', rect: { left: 100, top: 300, width: 200, height: 40 } });
  const dialog = makeEl({ tag: 'div', position: 'fixed', rect: { left: 200, top: 200, width: 600, height: 400 }, text: 'We use cookies. Manage preferences' });
  const backdrop = makeEl({ tag: 'div', position: 'fixed', rect: FULL, text: '' });
  const doc = makeDocument([target, backdrop, dialog], () => !dialog.hidden ? dialog : (!backdrop.hidden ? backdrop : target));
  const note = hideCoveringOverlay(target, doc, win);
  check('2 dialog hidden', dialog.hidden);
  check('2 backdrop hidden too (blanket, no form)', backdrop.hidden);
  check('2 note lists both', (note.match(/<div/g) || []).length === 2, note);
}

// 3. shadow host at the body
{
  const target = makeEl({ tag: 'a', rect: { left: 100, top: 300, width: 200, height: 40 } });
  const host = makeEl({ tag: 'usercentrics-root', rect: { left: 0, top: 600, width: 1000, height: 200 }, shadowText: 'We use cookies. Privacy Settings  Accept all  Deny' });
  const doc = makeDocument([target, host], () => host.hidden ? target : host);
  const note = hideCoveringOverlay(target, doc, win);
  check('3 shadow-DOM consent host hidden', host.hidden, note);
}

// 4. full-viewport promo layer, no consent words, no form
{
  const target = makeEl({ tag: 'a', rect: { left: 100, top: 300, width: 200, height: 40 } });
  const promo = makeEl({ tag: 'div', position: 'fixed', rect: FULL, text: 'You might be interested in  TRF RIPPED JEANS' });
  const doc = makeDocument([target, promo], () => promo.hidden ? target : promo);
  hideCoveringOverlay(target, doc, win);
  check('4 blanket promo layer hidden', promo.hidden);
}

// 5. full-viewport modal holding a form: left alone
{
  const target = makeEl({ tag: 'a', rect: { left: 100, top: 300, width: 200, height: 40 } });
  const login = makeEl({ tag: 'div', position: 'fixed', rect: FULL, text: 'Sign in to continue', fields: ['input'] });
  const doc = makeDocument([target, login], () => login);
  const note = hideCoveringOverlay(target, doc, win);
  check('5 modal with a form is not hidden', !login.hidden);
  check('5 and nothing is reported', note === '', JSON.stringify(note));
}

// 6. small absolute dropdown: left alone
{
  const target = makeEl({ tag: 'button', rect: { left: 100, top: 300, width: 200, height: 40 } });
  const menu = makeEl({ tag: 'ul', position: 'absolute', rect: { left: 100, top: 280, width: 220, height: 120 }, text: 'Option A Option B' });
  const doc = makeDocument([target, menu], () => menu);
  const note = hideCoveringOverlay(target, doc, win);
  check('6 dropdown is not hidden', !menu.hidden);
  check('6 and nothing is reported', note === '');
}

// 7. nothing covering
{
  const target = makeEl({ tag: 'a', rect: { left: 100, top: 300, width: 200, height: 40 } });
  const doc = makeDocument([target], () => target);
  check('7 clean target reports nothing', hideCoveringOverlay(target, doc, win) === '');
}

// 8. scroll lock released only when something was hidden
{
  const target = makeEl({ tag: 'a', rect: { left: 100, top: 300, width: 200, height: 40 } });
  const banner = makeEl({ tag: 'div', position: 'fixed', rect: { left: 0, top: 500, width: 1000, height: 300 }, text: 'This site uses cookies. Accept' });
  const doc = makeDocument([target, banner], () => banner.hidden ? target : banner);
  doc.body.style.overflow = 'hidden';
  hideCoveringOverlay(target, doc, win);
  check('8 body overflow lock released', doc.body.style.overflow === '');
  const doc2 = makeDocument([target], () => target);
  doc2.body.style.overflow = 'hidden';
  hideCoveringOverlay(target, doc2, win);
  check('8 lock untouched when nothing was hidden', doc2.body.style.overflow === 'hidden');
}

// ---- consent controls as the click TARGET (policy: no new cookies) --------------------------

// 9. "Accept All Cookies" inside a OneTrust-shaped widget: static root under body, fixed banner
//    inside it, the button inside that. Root chosen = the widget root (short text, child of body).
{
  const accept = makeEl({ tag: 'button', text: 'Accept All Cookies' });
  const banner = makeEl({ tag: 'div', position: 'fixed', rect: { left: 0, top: 500, width: 1000, height: 300 },
    text: 'By clicking "Accept All Cookies", you agree to the storing of cookies Accept All Cookies', children: [accept] });
  const backdrop = makeEl({ tag: 'div', position: 'fixed', rect: FULL });
  const widget = makeEl({ tag: 'div', attrs: { id: 'onetrust-consent-sdk' }, text: 'By clicking "Accept All Cookies", you agree to the storing of cookies Accept All Cookies', children: [backdrop, banner] });
  const doc = makeDocument([makeEl({ tag: 'main', text: 'page' }), widget], () => accept);
  const note = shippedConsentProbe(accept, doc, win);
  check('9 accept button is refused and the whole widget hidden', /NOT CLICKED/.test(note) && widget.hidden, note);
  check('9 the banner alone is not what got hidden (its root was)', !banner.hidden || widget.hidden);
  check('9 note names the control and the policy', /"Accept All Cookies"/.test(note) && /no new cookies/.test(note), note);
}

// 10. A button inside a fixed site header with no consent wording: an ordinary click, nothing hidden.
{
  const btn = makeEl({ tag: 'button', text: 'Search' });
  const header = makeEl({ tag: 'div', position: 'fixed', rect: { left: 0, top: 0, width: 1000, height: 80 }, text: 'Scores Rankings Players Search', children: [btn] });
  const doc = makeDocument([header, makeEl({ tag: 'main', text: 'page' })], () => btn);
  check('10 header button is not a consent control', shippedConsentProbe(btn, doc, win) === '' && !header.hidden);
}

// 11. The banner lives INSIDE the app's root div (huge text): only the fixed banner is hidden,
//     never the app root.
{
  const reject = makeEl({ tag: 'a', text: 'Reject all' });
  const banner = makeEl({ tag: 'div', position: 'fixed', rect: { left: 0, top: 600, width: 1000, height: 200 }, text: 'We use cookies. Accept all Reject all', children: [reject] });
  const app = makeEl({ tag: 'div', attrs: { id: 'app' }, text: 'x'.repeat(5000) + ' We use cookies. Accept all Reject all', children: [makeEl({ tag: 'main', text: 'x'.repeat(5000) }), banner] });
  const doc = makeDocument([app], () => reject);
  const note = shippedConsentProbe(reject, doc, win);
  check('11 reject link inside an app root: banner hidden, app kept', banner.hidden && !app.hidden && /NOT CLICKED/.test(note), note);
}

// 12. A plain page link with no layered ancestor: untouched.
{
  const link = makeEl({ tag: 'a', text: 'Rankings' });
  const nav = makeEl({ tag: 'nav', text: 'Overview Rankings', children: [link] });
  const doc = makeDocument([nav], () => link);
  check('12 ordinary link is not refused', shippedConsentProbe(link, doc, win) === '');
}

// 13. A non-control inside the consent layer (a paragraph) is not the policy's business.
{
  const para = makeEl({ tag: 'p', text: 'We value your privacy' });
  const banner = makeEl({ tag: 'div', position: 'fixed', rect: { left: 0, top: 600, width: 1000, height: 200 }, text: 'We value your privacy Accept', children: [para] });
  const doc = makeDocument([banner], () => para);
  check('13 a paragraph in the banner is not refused', shippedConsentProbe(para, doc, win) === '');
}

// 14. The review's counter-example: a fixed settings modal that says "privacy preferences" and
//     holds a form. Action word, no topic word: not a consent prompt. Its Save button is an
//     ordinary click, and when it covers a target it is left alone (it holds form fields).
{
  const save = makeEl({ tag: 'button', text: 'Save preferences' });
  const modal = makeEl({ tag: 'div', position: 'fixed', rect: FULL, text: 'Account settings  Privacy preferences  Email me about updates  Save preferences', fields: ['input'], children: [save] });
  const doc = makeDocument([makeEl({ tag: 'main', text: 'page' }), modal], () => save);
  check('14 a settings modal saying "privacy preferences" is not a consent prompt', shippedConsentProbe(save, doc, win) === '' && !modal.hidden);
  const target = makeEl({ tag: 'a', rect: { left: 100, top: 300, width: 200, height: 40 } });
  const doc2 = makeDocument([target, modal], () => modal);
  check('14 and it is not hidden when it covers a target', hideCoveringOverlay(target, doc2, win) === '' && !modal.hidden);
}

// 15. Topic without action is not consent on its own.
{
  const target = makeEl({ tag: 'a', rect: { left: 100, top: 300, width: 200, height: 40 } });
  const factOnly = makeEl({ tag: 'div', position: 'fixed', rect: { left: 0, top: 500, width: 1000, height: 200 }, text: 'This site uses cookies.' });
  const doc = makeDocument([target, factOnly], () => factOnly);
  check('15 "uses cookies" with no button is not hidden as consent (and is too small to be a blanket)', hideCoveringOverlay(target, doc, win) === '' && !factOnly.hidden);
}

if (failures) { console.log(failures + ' failure(s)'); process.exit(1); }
console.log('all overlay-hider checks passed');
