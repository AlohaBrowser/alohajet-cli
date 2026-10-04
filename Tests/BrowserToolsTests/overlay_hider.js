// Runs the page-side overlay hider (`AgentBrowserBridge.overlayHiderSource`) against a fake DOM.
// The source is EXTRACTED from ClickReceipts.swift by its BEGIN/END markers, so this exercises the
// bytes that ship rather than a copy that can drift. Run with:  node Tests/BrowserToolsTests/overlay_hider.js
//
// The shapes are the ones the guard exists for and the ones it must leave alone:
//   1. a fixed consent banner appended to <body> covering the target      -> hidden, note
//   2. a dialog + separate fixed backdrop (two layers)                     -> both hidden
//   3. a shadow-DOM host at the body holding a consent widget              -> hidden (structural)
//   4. a full-viewport fixed promo layer with no consent words, no form    -> hidden (blanket)
//   5. a full-viewport fixed modal that holds a form (a login, a drawer)   -> left alone
//   6. a small absolutely positioned dropdown covering the target          -> left alone
//   7. nothing covering the target                                          -> empty, nothing touched
//   8. the body scroll lock a consent library sets inline                  -> released only when hidden
//   9..15. consent controls as the click TARGET: OneTrust by id, a header button, a banner inside
//          an app root, a plain link, a paragraph, a "privacy preferences" settings modal, a
//          cookie sentence with no button
//   16..23. the measured zara.com shapes (2026-09-20/21): fixed header in a short app root whose
//          footer says COOKIE SETTINGS, "Settings" in an account header, a short wrapper holding
//          <main>, a fixed shell holding <main>, the inert app root under a privacy popup, Close
//          as the only button of a cookie notice, Close on a newsletter pop-up, OneTrust's dark
//          filter under a zero-height wrapper
//   24..29. NEGATIVE, each refused and hidden by the previous (label-and-vocabulary) version: a
//          login modal whose small print mentions the Privacy Policy, an age gate, a region
//          picker, a sticky checkout footer with a Privacy link, a notification-preferences
//          drawer, a fixed SPA shell whose footer says "Cookie settings"
//   30..36. POSITIVE, by layer: Cookiebot by id (dialog and underlay), an unknown CMP caught
//          structurally, a TCF-standard banner without cookie words plus `__tcfapi` reporting
//          visible (and NOT without it, NOT when it reports hidden), `__gpp` reporting visible,
//          a Usercentrics shadow root with the control inside it, a non-action label inside a
//          known CMP, the inert release rule (a modal root unlocks body children, a plain layer
//          only the target's ancestors)

const fs = require('fs');
const path = require('path');

const swift = fs.readFileSync(path.join(__dirname, '..', '..', 'Sources', 'BrowserTools', 'Runtime', 'ClickReceipts.swift'), 'utf8');
const begin = swift.indexOf('// BEGIN overlay-hider js');
const end = swift.indexOf('// END overlay-hider js');
if (begin < 0 || end < 0) { console.error('markers not found in ClickReceipts.swift'); process.exit(2); }
// The control words are one Swift constant the source interpolates (`\(consentActionPattern)`);
// put it in the way Swift does, THEN undo the literal's escaping (`\\s`, `\\u043f`) so JS sees
// `\s`, `п`.
const patternMatch = /static let consentActionPattern = "([^"]*)"/.exec(swift);
if (!patternMatch) { console.error('consentActionPattern not found in ClickReceipts.swift'); process.exit(2); }
const inline = (s) => s.split('\\(consentActionPattern)').join(patternMatch[1]).replace(/\\\\/g, '\\');
const source = inline(swift.slice(begin, end));
// The source is STATEMENTS (helpers + two function declarations); evaluate it and hand both back.
const { hideCoveringOverlay, hideConsentLayerContaining } =
  new Function(source + '\nreturn { hideCoveringOverlay, hideConsentLayerContaining };')();

// THE SHAPE THE BRIDGE SHIPS, compiled as-is. Both wrappers in ClickReceipts.swift inline the source
// as statements and then call one function on its own line. The source ENDS in a `//` comment
// (the END marker): an earlier wrapper put `)(el, document, window)` on that comment's line, so
// the whole probe was a SyntaxError the page answered in 2 ms and the bridge's `try?` silenced --
// eight clicks went into a cookie banner on 2026-09-17 while this harness, which added its own
// newline, stayed green. So the shipped shape is compiled here, END comment included.
const shippedSource = inline(swift.slice(begin, end + '// END overlay-hider js'.length));
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
// Enough of the Selectors API for what the hider asks: tag, #id, .class, [attr], [attr=v],
// [attr^=v], :not(compound), the descendant combinator, comma lists. Shadow roots hold their own
// children; a shadow child's parentNode is the root, whose `host` is the element.

function parseCompound(s) {
  const c = { tag: null, id: null, classes: [], attrs: [], nots: [] };
  let i = 0;
  const m = /^[a-zA-Z][\w-]*/.exec(s);
  if (m) { c.tag = m[0].toLowerCase(); i = m[0].length; }
  while (i < s.length) {
    const rest = s.slice(i);
    let r;
    if ((r = /^#([\w-]+)/.exec(rest))) { c.id = r[1]; i += r[0].length; }
    else if ((r = /^\.([\w-]+)/.exec(rest))) { c.classes.push(r[1]); i += r[0].length; }
    else if ((r = /^\[([\w-]+)(?:([\^$*]?=)"?([^"\]]*)"?)?\]/.exec(rest))) { c.attrs.push({ name: r[1], op: r[2] || null, value: r[3] }); i += r[0].length; }
    else if (rest.startsWith(':not(')) { const close = s.indexOf(')', i); c.nots.push(parseCompound(s.slice(i + 5, close))); i = close + 1; }
    else throw new Error('fake DOM: unsupported selector ' + JSON.stringify(s));
  }
  return c;
}
function matchCompound(el, c) {
  if (c.tag && String(el.tagName).toLowerCase() !== c.tag) return false;
  if (c.id && el.getAttribute('id') !== c.id) return false;
  const cls = (el.getAttribute('class') || '').split(/\s+/);
  for (const k of c.classes) if (!cls.includes(k)) return false;
  for (const a of c.attrs) {
    const v = el.getAttribute(a.name);
    if (v === null) return false;
    if (a.op === '=' && v !== a.value) return false;
    if (a.op === '^=' && !v.startsWith(a.value)) return false;
  }
  for (const n of c.nots) if (matchCompound(el, n)) return false;
  return true;
}
function matchesSelector(el, sel) {
  return sel.split(',').some(part => {
    const compounds = part.trim().split(/\s+/).map(parseCompound);
    if (!matchCompound(el, compounds[compounds.length - 1])) return false;
    let idx = compounds.length - 2, n = el.parentElement;
    while (idx >= 0 && n) { if (matchCompound(n, compounds[idx])) idx--; n = n.parentElement; }
    return idx < 0;
  });
}
function descendants(node) {
  const out = [];
  (function walk(n) { for (const c of n.children) { out.push(c); walk(c); } })(node);
  return out;
}

function makeEl(spec) {
  const el = {
    tagName: spec.tag || 'div',
    attrs: Object.assign({}, spec.attrs || {}),
    children: [],
    parentElement: null,
    parentNode: null,
    style: Object.assign({ _props: {}, setProperty(k, v) { this._props[k] = v; } }, spec.style || {}),
    position: spec.position || 'static',
    rect: spec.rect || { left: 0, top: 0, width: 0, height: 0 },
    textContent: spec.text || '',
    shadowRoot: null,
    getAttribute(k) { return Object.prototype.hasOwnProperty.call(this.attrs, k) ? this.attrs[k] : null; },
    setAttribute(k, v) { this.attrs[k] = String(v); },
    removeAttribute(k) { delete this.attrs[k]; },
    getBoundingClientRect() { return this.rect; },
    contains(other) { for (let n = other; n; n = n.parentElement) if (n === this) return true; return false; },
    matches(sel) { return matchesSelector(this, sel); },
    closest(sel) { for (let n = this; n; n = n.parentElement) if (matchesSelector(n, sel)) return n; return null; },
    querySelector(sel) { return descendants(this).find(d => matchesSelector(d, sel)) || null; },
    querySelectorAll(sel) { return descendants(this).filter(d => matchesSelector(d, sel)); },
    scrollIntoView() {},
    get innerText() { return this.textContent; },
    get hidden() { return this.style._props.display === 'none'; },
  };
  // `fields: ['input', 'main']` declares descendants by tag without spelling them out.
  (spec.fields || []).forEach(tag => { const stub = makeEl({ tag }); stub.parentElement = el; stub.parentNode = el; el.children.push(stub); });
  (spec.children || []).forEach(c => { c.parentElement = el; c.parentNode = el; el.children.push(c); });
  if (spec.shadowText != null || spec.shadowChildren) {
    const sr = {
      host: el, textContent: spec.shadowText || '', children: [],
      querySelector(sel) { return descendants(this).find(d => matchesSelector(d, sel)) || null; },
      querySelectorAll(sel) { return descendants(this).filter(d => matchesSelector(d, sel)); },
    };
    (spec.shadowChildren || []).forEach(c => { c.parentElement = null; c.parentNode = sr; sr.children.push(c); });
    el.shadowRoot = sr;
  }
  return el;
}

function makeDocument(bodyChildren, hit) {
  const html = makeEl({ tag: 'html' });
  const body = makeEl({ tag: 'body', children: bodyChildren });
  body.parentElement = html; body.parentNode = html; html.children.push(body);
  return {
    body, documentElement: html,
    // `hit` decides what elementFromPoint returns; it is re-evaluated each call so hiding a
    // layer can reveal the next one (the backdrop case) or the target itself.
    elementFromPoint() { return hit(); },
    querySelector() { return null; },
    getElementById(id) { return descendants(html).find(d => d.getAttribute('id') === id) || null; },
  };
}
const win = { innerWidth: 1000, innerHeight: 800, getComputedStyle: n => ({ position: n.position }) };
const FULL = { left: 0, top: 0, width: 1000, height: 800 };
const BOTTOM_BAND = { left: 0, top: 600, width: 1000, height: 200 };
// A window whose CMP answers the IAB ping the way every real CMP does: synchronously.
function winWithTcf(displayStatus) {
  return Object.assign({}, win, {
    location: { href: 'https://shop.example/#/home' },
    __tcfapi(command, version, cb) { if (command === 'ping') cb({ gdprApplies: true, cmpLoaded: true, cmpStatus: 'loaded', displayStatus, apiVersion: '2.2', cmpId: 28 }, true); },
  });
}

let failures = 0, checks = 0;
function check(name, cond, detail) {
  checks++;
  if (cond) console.log('ok   ' + name);
  else { failures++; console.log('FAIL ' + name + (detail ? ' -- ' + detail : '')); }
}
const TARGET = () => makeEl({ tag: 'a', rect: { left: 100, top: 300, width: 200, height: 40 } });

// 1. fixed consent banner at the body
{
  const target = TARGET();
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
  check('1 the note says which layer fired', /\[consent=heuristic\]/.test(note), note);
}

// 1b. the SAME case through the bridge-shaped wrapper: it must compile AND return the note.
{
  const target = TARGET();
  const banner = makeEl({ tag: 'div', position: 'fixed', rect: { left: 0, top: 500, width: 1000, height: 300 },
    text: 'This site uses cookies to improve your experience. Accept', children: [makeEl({ tag: 'button', text: 'Accept' })] });
  const doc = makeDocument([target, banner], () => banner.hidden ? target : banner);
  const note = shippedProbe(target, doc, win);
  check('1b bridge-shaped wrapper hides and reports', /Hid a covering overlay/.test(note) && banner.hidden, note);
}

// 2. dialog + separate backdrop
{
  const target = makeEl({ tag: 'button', rect: { left: 100, top: 300, width: 200, height: 40 } });
  const dialog = makeEl({ tag: 'div', position: 'fixed', rect: { left: 200, top: 200, width: 600, height: 400 },
    text: 'We use cookies to personalise content and analyse our traffic. Manage preferences Accept all',
    children: [makeEl({ tag: 'button', text: 'Manage preferences' }), makeEl({ tag: 'button', text: 'Accept all' })] });
  const backdrop = makeEl({ tag: 'div', position: 'fixed', rect: FULL, text: '' });
  const doc = makeDocument([target, backdrop, dialog], () => !dialog.hidden ? dialog : (!backdrop.hidden ? backdrop : target));
  const note = hideCoveringOverlay(target, doc, win);
  check('2 dialog hidden', dialog.hidden);
  check('2 backdrop hidden too (blanket, no form)', backdrop.hidden);
  check('2 note lists both', (note.match(/<div/g) || []).length === 2, note);
  check('2 note tells the consent layer from the blanket', /\[consent=heuristic\]/.test(note) && /\[blanket\]/.test(note), note);
}

// 3. shadow host at the body, no vendor id: caught by its shape and its own words
{
  const target = TARGET();
  const host = makeEl({ tag: 'cookie-widget', rect: BOTTOM_BAND, shadowText: 'We use cookies. Privacy Settings  Accept all  Deny',
    shadowChildren: [makeEl({ tag: 'button', text: 'Accept all' }), makeEl({ tag: 'button', text: 'Deny' })] });
  const doc = makeDocument([target, host], () => host.hidden ? target : host);
  const note = hideCoveringOverlay(target, doc, win);
  check('3 shadow-DOM consent host hidden', host.hidden, note);
}

// 4. full-viewport promo layer, no consent words, no form
{
  const target = TARGET();
  const promo = makeEl({ tag: 'div', position: 'fixed', rect: FULL, text: 'You might be interested in  TRF RIPPED JEANS' });
  const doc = makeDocument([target, promo], () => promo.hidden ? target : promo);
  const note = hideCoveringOverlay(target, doc, win);
  check('4 blanket promo layer hidden', promo.hidden);
  check('4 and marked as a blanket, not consent', /\[blanket\]/.test(note) && !/consent=/.test(note), note);
}

// 5. full-viewport modal holding a form: left alone
{
  const target = TARGET();
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
  const target = TARGET();
  const doc = makeDocument([target], () => target);
  check('7 clean target reports nothing', hideCoveringOverlay(target, doc, win) === '');
}

// 8. scroll lock released only when something was hidden
{
  const target = TARGET();
  const banner = makeEl({ tag: 'div', position: 'fixed', rect: { left: 0, top: 500, width: 1000, height: 300 },
    text: 'This site uses cookies to improve your experience. Accept', children: [makeEl({ tag: 'button', text: 'Accept' })] });
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
//    inside it, the button inside that. The vendor id names the whole widget.
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
  check('9 note says the vendor list fired', /\[consent=cmp:onetrust\]/.test(note), note);
}

// 10. A button inside a fixed site header with no consent wording: an ordinary click, nothing hidden.
{
  const btn = makeEl({ tag: 'button', text: 'Search' });
  const header = makeEl({ tag: 'div', position: 'fixed', rect: { left: 0, top: 0, width: 1000, height: 80 },
    text: 'Scores Rankings Players Fixtures Results Statistics Search', children: [btn] });
  const doc = makeDocument([header, makeEl({ tag: 'main', text: 'page' })], () => btn);
  check('10 header button is not a consent control', shippedConsentProbe(btn, doc, win) === '' && !header.hidden);
}

// 11. The banner lives INSIDE the app's root div (huge text): only the fixed banner is hidden,
//     never the app root.
{
  const reject = makeEl({ tag: 'a', text: 'Reject all' });
  const banner = makeEl({ tag: 'div', position: 'fixed', rect: BOTTOM_BAND,
    text: 'We use cookies to give you the best experience. Accept all Reject all', children: [makeEl({ tag: 'a', text: 'Accept all' }), reject] });
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
  const banner = makeEl({ tag: 'div', position: 'fixed', rect: BOTTOM_BAND, text: 'We value your privacy and use cookies. Accept', children: [para, makeEl({ tag: 'button', text: 'Accept' })] });
  const doc = makeDocument([banner], () => para);
  check('13 a paragraph in the banner is not refused', shippedConsentProbe(para, doc, win) === '');
}

// 14. The review's counter-example: a fixed settings modal that says "privacy preferences" and
//     holds a form. Its Save button is an ordinary click, and when it covers a target it is left
//     alone (it holds form fields).
{
  const save = makeEl({ tag: 'button', text: 'Save preferences' });
  const modal = makeEl({ tag: 'div', position: 'fixed', rect: FULL, text: 'Account settings  Privacy preferences  Email me about updates  Save preferences', fields: ['input'], children: [save] });
  const doc = makeDocument([makeEl({ tag: 'main', text: 'page' }), modal], () => save);
  check('14 a settings modal saying "privacy preferences" is not a consent prompt', shippedConsentProbe(save, doc, win) === '' && !modal.hidden);
  const target = TARGET();
  const doc2 = makeDocument([target, modal], () => modal);
  check('14 and it is not hidden when it covers a target', hideCoveringOverlay(target, doc2, win) === '' && !modal.hidden);
}

// 15. A cookie sentence with no control is not a prompt (and too small to be a blanket).
{
  const target = TARGET();
  const factOnly = makeEl({ tag: 'div', position: 'fixed', rect: BOTTOM_BAND, text: 'This site uses cookies to remember your settings.' });
  const doc = makeDocument([target, factOnly], () => factOnly);
  check('15 "uses cookies" with no button is not hidden as consent', hideCoveringOverlay(target, doc, win) === '' && !factOnly.hidden);
}

// ---- the measured zara.com shapes ------------------------------------------------------------

// 16. THE ZARA SHAPE (2026-09-20). The header is fixed and lives inside the app root; the app
//     root's visible text is short because the page is images; its footer link says "COOKIE
//     SETTINGS". The first version refused SEARCH, BAG, LOG IN and HELP as consent controls and
//     hid the whole app root: six runs read an empty page and gave up. Ordinary clicks, nothing hidden.
{
  const search = makeEl({ tag: 'a', text: 'SEARCH' });
  const bag = makeEl({ tag: 'a', text: 'BAG 0' });
  const header = makeEl({ tag: 'div', position: 'fixed', rect: { left: 0, top: 0, width: 1000, height: 60 },
    text: 'SEARCH BAG 0 LOG IN HELP', children: [search, bag] });
  const footer = makeEl({ tag: 'div', text: 'HELP COOKIE SETTINGS PRIVACY POLICY' });
  const app = makeEl({ tag: 'div', attrs: { id: 'app-root' }, fields: ['main', 'header'],
    text: 'SKIP TO MAIN CONTENT SEARCH BAG 0 LOG IN HELP ZARA Georgia | New Collection HELP COOKIE SETTINGS PRIVACY POLICY',
    children: [header, makeEl({ tag: 'main', text: 'ZARA Georgia | New Collection' }), footer] });
  const doc = makeDocument([app], () => search);
  check('16 SEARCH in a fixed header is not a consent control', shippedConsentProbe(search, doc, win) === '' && !app.hidden && !header.hidden);
  check('16 BAG is not one either', shippedConsentProbe(bag, doc, win) === '' && !app.hidden);
}

// 17. A consent-ACTION label outside any cookie notice ("Settings" in an account header).
{
  const settings = makeEl({ tag: 'a', text: 'Settings' });
  const header = makeEl({ tag: 'div', position: 'fixed', rect: { left: 0, top: 0, width: 1000, height: 60 },
    text: 'Home Profile Messages Notifications Settings Log out', children: [settings] });
  const doc = makeDocument([header, makeEl({ tag: 'main', text: 'page' })], () => settings);
  check('17 "Settings" outside a cookie notice is an ordinary click', shippedConsentProbe(settings, doc, win) === '' && !header.hidden);
}

// 18. Accept inside a fixed banner whose SHORT body-child wrapper also holds the page's <main>:
//     the landmark stops the widening, so the banner goes and the page stays.
{
  const accept = makeEl({ tag: 'button', text: 'Accept all' });
  const banner = makeEl({ tag: 'div', position: 'fixed', rect: BOTTOM_BAND,
    text: 'We use cookies to make this site work. Accept all', children: [accept] });
  const app = makeEl({ tag: 'div', fields: ['main'], text: 'Shop now We use cookies to make this site work. Accept all',
    children: [makeEl({ tag: 'main', text: 'Shop now' }), banner] });
  const doc = makeDocument([app], () => accept);
  const note = shippedConsentProbe(accept, doc, win);
  check('18 short app root with a landmark is kept, banner hidden', banner.hidden && !app.hidden && /NOT CLICKED/.test(note), note);
}

// 19. The covering-overlay path: a fixed, full-viewport wrapper that holds <main> is the app
//     (a sticky layout shell), not a layer over the target. Left alone even though it blankets.
{
  const target = makeEl({ tag: 'button', text: 'Go' });
  const shell = makeEl({ tag: 'div', position: 'fixed', rect: FULL, fields: ['main'], text: 'Home Go',
    children: [makeEl({ tag: 'main', text: 'Home' })] });
  const doc = makeDocument([shell, target], () => shell);
  check('19 a fixed shell holding <main> is never hidden', shippedProbe(target, doc, win) === '' && !shell.hidden);
}

// 20. THE ZARA US SHAPE (2026-09-20). A privacy-policy dialog (fixed, "Close" button) covers the
//     product card; the dialog framework marked `#app-root` inert while it is open. Hiding the
//     dialog alone left every click landing in <body>: thirteen "Open size selector" clicks and no
//     picker. The hide must also release the inert lock on the target's ancestors. (This popup
//     says "privacy", not "cookies": it is a BLANKET hide, and the policy note says so.)
{
  const btn = makeEl({ tag: 'button', attrs: { 'aria-label': 'Open size selector' } });
  const card = makeEl({ tag: 'li', text: '$ 99.90 Dark mink', children: [btn] });
  const app = makeEl({ tag: 'div', attrs: { id: 'app-root', inert: '' }, fields: ['main'], text: 'SEARCH BAG 0 $ 99.90 Dark mink',
    children: [makeEl({ tag: 'main', text: 'results', children: [card] })] });
  const popup = makeEl({ tag: 'div', position: 'fixed', rect: FULL,
    text: 'We have updated the information about the use of your personal data contained in our Privacy Policy Close',
    children: [makeEl({ tag: 'button', text: 'Close' })] });
  const slide = makeEl({ tag: 'div', attrs: { inert: '' }, text: 'off-screen carousel slide' });
  app.children.push(slide); slide.parentElement = app; slide.parentNode = app;
  const doc = makeDocument([app, popup], () => (popup.hidden ? btn : popup));
  const note = shippedProbe(btn, doc, win);
  check('20 privacy popup hidden', popup.hidden && /Hid a covering overlay/.test(note), note);
  check('20 as a blanket, not as consent', /\[blanket\]/.test(note), note);
  check('20 inert released on the app root', app.getAttribute('inert') === null);
  check('20 receipt says the page is interactive again', /interactive again/.test(note), note);
  check('20 an unrelated inert node (carousel slide) is left alone', slide.getAttribute('inert') !== null);
}

// 21. THE ZARA GEORGIA BANNER (measured 2026-09-21). A small fixed cookie notice in a corner with
//     ONE button, "Close" (aria-label "Close"). Clicking it granted every cookie category on the
//     real site. The OneTrust wrapper names it; Close inside is refused, the notice hidden.
{
  const close = makeEl({ tag: 'button', text: 'Close', attrs: { 'aria-label': 'Close', class: 'onetrust-close-btn-handler banner-close-button' } });
  const banner = makeEl({ tag: 'div', position: 'fixed', rect: { left: 20, top: 800, width: 375, height: 142 },
    text: 'We use first-party and third-party cookies for analytical purposes and to show you advertising related to your preferences Close', children: [close] });
  const widget = makeEl({ tag: 'div', attrs: { id: 'onetrust-consent-sdk' },
    text: 'We use first-party and third-party cookies for analytical purposes and to show you advertising related to your preferences Close', children: [banner] });
  const app = makeEl({ tag: 'div', attrs: { id: 'app-root' }, fields: ['main'], text: 'SEARCH BAG 0 LOG IN', children: [makeEl({ tag: 'main', text: 'products' })] });
  const doc = makeDocument([app, widget], () => close);
  const note = shippedConsentProbe(close, doc, win);
  check('21 Close inside a cookie notice is refused', /NOT CLICKED/.test(note) && /"Close"/.test(note), note);
  check('21 the notice is hidden, the app is kept', widget.hidden && !app.hidden, note);
  // an "×" with only an aria-label in a full-width German banner from an unknown vendor
  const x = makeEl({ tag: 'button', text: '×', attrs: { 'aria-label': 'Schließen' } });
  const bannerX = makeEl({ tag: 'div', position: 'fixed', rect: BOTTOM_BAND,
    text: 'Wir verwenden Cookies, um Ihnen Werbung zu zeigen ×', children: [x] });
  const docX = makeDocument([makeEl({ tag: 'main', text: 'seite' }), bannerX], () => x);
  const noteX = shippedConsentProbe(x, docX, win);
  check('21 an × close glyph inside a cookie notice is refused too', /NOT CLICKED/.test(noteX) && bannerX.hidden && /\[consent=heuristic\]/.test(noteX), noteX);
}

// 22. "Close" on a layer that is NOT a cookie notice (a newsletter pop-up): an ordinary click.
{
  const close = makeEl({ tag: 'button', text: 'Close', attrs: { 'aria-label': 'Close' } });
  const popup = makeEl({ tag: 'div', position: 'fixed', rect: { left: 200, top: 200, width: 600, height: 400 },
    text: 'Join our newsletter and get 10% off your first order Close', children: [close] });
  const doc = makeDocument([makeEl({ tag: 'main', text: 'page' }), popup], () => close);
  check('22 Close on a newsletter pop-up is not a consent control', shippedConsentProbe(close, doc, win) === '' && !popup.hidden);
}

// 23. THE ZARA-FROM-ABROAD SHAPE (measured 2026-09-21, run jacket-bag-luna-ge47, Dutch exit). The
//     target is the store-choice dialog's "YES, CONTINUE ON GEORGIA" button, inside a fixed modal
//     of its own. What covers it is OneTrust's full-viewport dark backdrop (fixed, no text), whose
//     ROOT is `#onetrust-consent-sdk`: a static wrapper with a ZERO-HEIGHT box, no visible text
//     (its banner is display:none), and form fields + a nav inside the hidden preference centre.
//     Judged by text and fields nothing qualified and ten clicks went into the backdrop. The
//     vendor id names the wrapper, so the whole widget goes; the dialog and the app stay.
{
  const yes = makeEl({ tag: 'button', text: 'YES, CONTINUE ON GEORGIA', rect: { left: 517, top: 428, width: 351, height: 32 } });
  const modal = makeEl({ tag: 'div', position: 'fixed', rect: FULL, attrs: { role: 'dialog' },
    text: 'HELLO, Yes, continue on Georgia YES, CONTINUE ON GEORGIA NO, GO TO THE WEBSITE FOR NEDERLAND', children: [yes] });
  const banner = makeEl({ tag: 'div', attrs: { id: 'onetrust-banner-sdk' }, position: 'fixed', rect: { left: 0, top: 0, width: 0, height: 0 }, text: '' });
  banner.style.setProperty('display', 'none');
  const darkFilter = makeEl({ tag: 'div', attrs: { class: 'onetrust-pc-dark-filter ot-fade-in' }, position: 'fixed', rect: FULL, text: '' });
  const wrapper = makeEl({ tag: 'div', attrs: { id: 'onetrust-consent-sdk' }, rect: { left: 0, top: 2441, width: 1369, height: 0 },
    text: '', fields: ['input', 'nav'], children: [banner, darkFilter] });
  const app = makeEl({ tag: 'div', attrs: { id: 'app-root' }, fields: ['main'], text: 'SEARCH BAG 0 results', children: [makeEl({ tag: 'main', text: 'results' })] });
  const doc = makeDocument([app, modal, wrapper], () => ((darkFilter.hidden || wrapper.hidden) ? yes : darkFilter));
  const note = shippedProbe(yes, doc, win);
  check('23 the backdrop no longer takes the click: its OneTrust wrapper is hidden by id', wrapper.hidden && /\[consent=cmp:onetrust\]/.test(note), note);
  check('23 the dialog and the app are left alone', !modal.hidden && !app.hidden);
  check('23 afterwards the point reaches the target', doc.elementFromPoint() === yes);
}

// ---- NEGATIVE: legitimate dialogs the label-and-vocabulary version refused --------------------

// 24. A fixed login modal: "By continuing you agree to our Terms and Privacy Policy", Continue,
//     an email and a password field. Previously: "continue" matched the action list, "agree" and
//     "privacy" matched the layer, refused and hidden. Text fields end it on both paths.
{
  const cont = makeEl({ tag: 'button', text: 'Continue' });
  const login = makeEl({ tag: 'div', position: 'fixed', rect: FULL, attrs: { role: 'dialog', 'aria-modal': 'true' },
    text: 'Sign in Email Password By continuing you agree to our Terms and Privacy Policy Continue',
    children: [makeEl({ tag: 'input', attrs: { type: 'email' } }), makeEl({ tag: 'input', attrs: { type: 'password' } }), cont] });
  const doc = makeDocument([makeEl({ tag: 'main', text: 'page' }), login], () => cont);
  check('24 Continue in a login modal is an ordinary click', shippedConsentProbe(cont, doc, win) === '' && !login.hidden);
  const target = TARGET();
  const doc2 = makeDocument([target, login], () => login);
  check('24 and the login modal is never hidden when it covers a target', shippedProbe(target, doc2, win) === '' && !login.hidden);
}

// 25. An age gate: "I confirm I am over 18", Continue / Leave, small print about privacy, a
//     backdrop behind it. Shaped exactly like a consent modal, no text fields -- only the
//     vocabulary tells them apart, and "confirm", "accept", "privacy" are not cookie words.
{
  const cont = makeEl({ tag: 'button', text: 'Continue' });
  const gate = makeEl({ tag: 'div', position: 'fixed', rect: { left: 200, top: 250, width: 600, height: 300 }, attrs: { role: 'dialog' },
    text: 'Are you over 18? By entering this site I confirm I am over 18 and accept the Terms and Privacy Policy Continue Leave',
    children: [cont, makeEl({ tag: 'button', text: 'Leave' })] });
  const backdrop = makeEl({ tag: 'div', position: 'fixed', rect: FULL, text: '' });
  const doc = makeDocument([makeEl({ tag: 'main', text: 'page' }), backdrop, gate], () => cont);
  check('25 Continue on an age gate is an ordinary click', shippedConsentProbe(cont, doc, win) === '' && !gate.hidden);
  const target = TARGET();
  const doc2 = makeDocument([target, backdrop, gate], () => gate);
  check('25 and the gate is not hidden as consent when it covers a target', shippedProbe(target, doc2, win) === '' && !gate.hidden);
}

// 26. A region picker: a fixed dialog with a <select> and Continue, small print about privacy.
{
  const cont = makeEl({ tag: 'button', text: 'Continue' });
  const picker = makeEl({ tag: 'div', position: 'fixed', rect: FULL, attrs: { role: 'dialog' },
    text: 'Choose your country and language Country Language We process your data as described in our Privacy Policy Continue',
    children: [makeEl({ tag: 'select' }), makeEl({ tag: 'select' }), cont] });
  const doc = makeDocument([makeEl({ tag: 'main', text: 'page' }), picker], () => cont);
  check('26 Continue on a region picker is an ordinary click', shippedConsentProbe(cont, doc, win) === '' && !picker.hidden);
}

// 27. A sticky checkout footer with a Privacy link and "Continue to payment". Previously the
//     action word plus the Privacy link made it a consent prompt.
{
  const pay = makeEl({ tag: 'button', text: 'Continue to payment' });
  const privacy = makeEl({ tag: 'a', text: 'Privacy' });
  const footer = makeEl({ tag: 'div', position: 'sticky', rect: { left: 0, top: 710, width: 1000, height: 90 },
    text: 'Subtotal $120.00 Shipping calculated at checkout Order tracking Privacy Terms Continue to payment',
    children: [makeEl({ tag: 'a', text: 'Order tracking' }), privacy, makeEl({ tag: 'a', text: 'Terms' }), pay] });
  const doc = makeDocument([makeEl({ tag: 'main', text: 'cart' }), footer], () => pay);
  check('27 Continue to payment in a sticky checkout footer is an ordinary click', shippedConsentProbe(pay, doc, win) === '' && !footer.hidden);
  check('27 and so is its Privacy link', shippedConsentProbe(privacy, doc, win) === '' && !footer.hidden);
}

// 28. A fixed notification-preferences drawer with checkboxes and Save, over a backdrop.
//     Checkboxes do not disqualify the shape (a preference centre is made of them), so only the
//     vocabulary decides: "preferences" and "settings" are not cookie words.
{
  const save = makeEl({ tag: 'button', text: 'Save' });
  const drawer = makeEl({ tag: 'div', position: 'fixed', rect: { left: 600, top: 0, width: 400, height: 800 },
    text: 'Notification preferences Email me about new followers Weekly digest Product updates Save',
    children: [makeEl({ tag: 'input', attrs: { type: 'checkbox' } }), makeEl({ tag: 'input', attrs: { type: 'checkbox' } }), save] });
  const backdrop = makeEl({ tag: 'div', position: 'fixed', rect: FULL, text: '' });
  const doc = makeDocument([makeEl({ tag: 'main', text: 'page' }), backdrop, drawer], () => save);
  check('28 Save in a notification-preferences drawer is an ordinary click', shippedConsentProbe(save, doc, win) === '' && !drawer.hidden);
}

// 29. A fixed SPA shell containing <main> whose footer says "Cookie settings": the landmark
//     makes it the page, on both paths, whatever its footer says.
{
  const cookieSettings = makeEl({ tag: 'a', text: 'Cookie settings' });
  const help = makeEl({ tag: 'a', text: 'Help' });
  const shell = makeEl({ tag: 'div', position: 'fixed', rect: FULL,
    text: 'Shop New in Sale Help Cookie settings Privacy',
    children: [makeEl({ tag: 'main', text: 'New in' }), makeEl({ tag: 'footer', text: 'Help Cookie settings Privacy', children: [help, cookieSettings] })] });
  const doc = makeDocument([shell], () => help);
  check('29 Help in a fixed shell with <main> is an ordinary click', shippedConsentProbe(help, doc, win) === '' && !shell.hidden);
  check('29 and so is the footer\'s own "Cookie settings" link (it is the page, not a prompt)', shippedConsentProbe(cookieSettings, doc, win) === '' && !shell.hidden);
  const target = makeEl({ tag: 'button', text: 'Go' });
  const doc2 = makeDocument([shell, target], () => shell);
  check('29 the shell is never hidden as a covering layer', shippedProbe(target, doc2, win) === '' && !shell.hidden);
}

// ---- POSITIVE, by layer -----------------------------------------------------------------------

// 30. Cookiebot by id: the dialog and, when the next click lands on it, the underlay.
{
  const deny = makeEl({ tag: 'button', text: 'Deny' });
  const dialog = makeEl({ tag: 'div', attrs: { id: 'CybotCookiebotDialog' }, position: 'fixed', rect: { left: 150, top: 150, width: 700, height: 500 },
    text: 'This website uses cookies Deny Allow selection Allow all', children: [deny, makeEl({ tag: 'button', text: 'Allow all' })] });
  const underlay = makeEl({ tag: 'div', attrs: { id: 'CybotCookiebotDialogBodyUnderlay' }, position: 'fixed', rect: FULL, text: '' });
  const doc = makeDocument([makeEl({ tag: 'main', text: 'page' }), underlay, dialog], () => deny);
  const note = shippedConsentProbe(deny, doc, win);
  check('30 Deny in a Cookiebot dialog is refused by the vendor id', /NOT CLICKED/.test(note) && /\[consent=cmp:cookiebot\]/.test(note) && dialog.hidden, note);
  const target = TARGET();
  const doc2 = makeDocument([target, underlay], () => underlay.hidden ? target : underlay);
  const note2 = shippedProbe(target, doc2, win);
  check('30 the underlay is hidden by the same id when it covers the next click', underlay.hidden && /\[consent=cmp:cookiebot\]/.test(note2), note2);
}

// 31. An unknown CMP, caught structurally: a bottom band saying "This site uses cookies" with
//     Accept and Reject. Either button is refused and the band hidden.
{
  const accept = makeEl({ tag: 'button', text: 'Accept' });
  const reject = makeEl({ tag: 'button', text: 'Reject' });
  const band = makeEl({ tag: 'div', position: 'fixed', rect: { left: 0, top: 620, width: 1000, height: 180 },
    text: 'This site uses cookies to analyse traffic and remember your settings. Accept Reject', children: [accept, reject] });
  const doc = makeDocument([makeEl({ tag: 'main', text: 'page' }), band], () => accept);
  const note = shippedConsentProbe(accept, doc, win);
  check('31 Accept on an unknown CMP\'s band is refused structurally', /NOT CLICKED/.test(note) && /\[consent=heuristic\]/.test(note) && band.hidden, note);
}

// 32. A hash-routed page whose banner carries the TCF standard text -- "store and/or access
//     information on a device", Agree, More options -- and no cookie word at all. Structure alone
//     is not enough; `__tcfapi` reporting a visible consent UI is what lets it through.
{
  const makeBanner = () => {
    const agree = makeEl({ tag: 'button', text: 'Agree' });
    const banner = makeEl({ tag: 'div', position: 'fixed', rect: { left: 0, top: 560, width: 1000, height: 240 },
      text: 'We and our partners store and/or access information on a device and process personal data for personalised ads and content. Agree More options',
      children: [agree, makeEl({ tag: 'button', text: 'More options' })] });
    return { agree, banner };
  };
  const a = makeBanner();
  const docA = makeDocument([makeEl({ tag: 'main', text: 'page' }), a.banner], () => a.agree);
  const noteA = shippedConsentProbe(a.agree, docA, winWithTcf('visible'));
  check('32 TCF banner without cookie words is refused when __tcfapi says visible', /NOT CLICKED/.test(noteA) && /\[consent=tcf\]/.test(noteA) && a.banner.hidden, noteA);
  const b = makeBanner();
  const docB = makeDocument([makeEl({ tag: 'main', text: 'page' }), b.banner], () => b.agree);
  check('32 and NOT without a CMP API on the page', shippedConsentProbe(b.agree, docB, win) === '' && !b.banner.hidden);
  const c = makeBanner();
  const docC = makeDocument([makeEl({ tag: 'main', text: 'page' }), c.banner], () => c.agree);
  check('32 and NOT when __tcfapi says the consent UI is hidden', shippedConsentProbe(c.agree, docC, winWithTcf('hidden')) === '' && !c.banner.hidden);
  // The API alone never fires: a login modal on a page whose CMP UI is visible keeps its Continue.
  const cont = makeEl({ tag: 'button', text: 'Continue' });
  const login = makeEl({ tag: 'div', position: 'fixed', rect: FULL, text: 'Sign in Email Password By continuing you agree to our Terms and Privacy Policy Continue',
    children: [makeEl({ tag: 'input', attrs: { type: 'email' } }), cont] });
  const docD = makeDocument([makeEl({ tag: 'main', text: 'page' }), login], () => cont);
  check('32 a visible CMP UI does not make a login modal a prompt', shippedConsentProbe(cont, docD, winWithTcf('visible')) === '' && !login.hidden);
}

// 33. GPP's ping carries the same display status under another name.
{
  const agree = makeEl({ tag: 'button', text: 'Agree' });
  const banner = makeEl({ tag: 'div', position: 'fixed', rect: { left: 0, top: 560, width: 1000, height: 240 },
    text: 'We and our partners store and/or access information on a device and process personal data. Agree More options',
    children: [agree, makeEl({ tag: 'button', text: 'More options' })] });
  const doc = makeDocument([makeEl({ tag: 'main', text: 'page' }), banner], () => agree);
  const w = Object.assign({}, win, { __gpp(command, cb) { if (command === 'ping') cb({ gppVersion: '1.1', cmpStatus: 'loaded', cmpDisplayStatus: 'visible', cmpId: 10 }, true); } });
  const note = shippedConsentProbe(agree, doc, w);
  check('33 __gpp reporting visible lets the structural match through', /NOT CLICKED/.test(note) && /\[consent=gpp\]/.test(note) && banner.hidden, note);
}

// 34. Usercentrics: `#usercentrics-root` is a shadow host and the control lives INSIDE the shadow
//     root, so the walk up from the control crosses the shadow boundary to the host.
{
  const acceptAll = makeEl({ tag: 'button', text: 'Accept All' });
  const host = makeEl({ tag: 'div', attrs: { id: 'usercentrics-root' }, rect: BOTTOM_BAND,
    shadowText: 'Privacy Settings We use cookies and similar technologies Accept All Deny More',
    shadowChildren: [makeEl({ tag: 'div', children: [acceptAll, makeEl({ tag: 'button', text: 'Deny' })] })] });
  const doc = makeDocument([makeEl({ tag: 'main', text: 'page' }), host], () => acceptAll);
  const note = shippedConsentProbe(acceptAll, doc, win);
  check('34 Accept All inside the Usercentrics shadow root is refused, the host hidden', /NOT CLICKED/.test(note) && /\[consent=cmp:usercentrics\]/.test(note) && host.hidden, note);
}

// 35. The label only words the receipt: a "Learn more" link inside a OneTrust banner is refused
//     like Accept is, and the receipt says it sits INSIDE the prompt rather than being one of its
//     answers.
{
  const learn = makeEl({ tag: 'a', text: 'Learn more' });
  const accept = makeEl({ tag: 'button', text: 'Accept All Cookies' });
  const banner = makeEl({ tag: 'div', attrs: { id: 'onetrust-banner-sdk' }, position: 'fixed', rect: BOTTOM_BAND,
    text: 'We use cookies to improve your experience. Learn more Accept All Cookies', children: [learn, accept] });
  const doc = makeDocument([makeEl({ tag: 'main', text: 'page' }), banner], () => learn);
  const note = shippedConsentProbe(learn, doc, win);
  check('35 a non-action control inside a known CMP is refused', /NOT CLICKED/.test(note) && banner.hidden, note);
  check('35 and the receipt words it as "inside" the prompt', /"Learn more" is a control inside a cookie\/consent prompt/.test(note), note);
  const banner2 = makeEl({ tag: 'div', attrs: { id: 'onetrust-banner-sdk' }, position: 'fixed', rect: BOTTOM_BAND,
    text: 'We use cookies to improve your experience. Accept All Cookies', children: [accept] });
  const doc2 = makeDocument([makeEl({ tag: 'main', text: 'page' }), banner2], () => accept);
  check('35 an action label is worded as a control "of" the prompt', /"Accept All Cookies" is a control of a cookie\/consent prompt/.test(shippedConsentProbe(accept, doc2, win)));
}

// 36. The inert release rule. A hidden root that carried a modal dialog (aria-modal) unlocks the
//     body's children it had locked; a plain layer unlocks only the target's ancestors.
{
  const accept = makeEl({ tag: 'button', text: 'Accept all' });
  const dialog = makeEl({ tag: 'div', attrs: { role: 'dialog', 'aria-modal': 'true' }, position: 'fixed', rect: { left: 200, top: 200, width: 600, height: 400 },
    text: 'We use cookies to personalise content. Accept all Reject all', children: [accept, makeEl({ tag: 'button', text: 'Reject all' })] });
  const widget = makeEl({ tag: 'div', attrs: { id: 'onetrust-consent-sdk' }, text: 'We use cookies to personalise content. Accept all Reject all', children: [dialog] });
  const app = makeEl({ tag: 'div', attrs: { id: 'app-root', inert: '' }, fields: ['main'], text: 'the page' });
  const aside = makeEl({ tag: 'aside', attrs: { inert: '' }, text: 'a sidebar' });
  const doc = makeDocument([app, aside, widget], () => accept);
  shippedConsentProbe(accept, doc, win);
  check('36 a modal root releases the body children it locked', widget.hidden && app.getAttribute('inert') === null && aside.getAttribute('inert') === null);
  // a promo layer with no dialog in it: the target's ancestors are released, other body children are not
  const target = makeEl({ tag: 'a', rect: { left: 100, top: 300, width: 200, height: 40 } });
  const app2 = makeEl({ tag: 'div', attrs: { id: 'app-root', inert: '' }, fields: ['main'], text: 'the page', children: [target] });
  const aside2 = makeEl({ tag: 'aside', attrs: { inert: '' }, text: 'a sidebar' });
  const promo = makeEl({ tag: 'div', position: 'fixed', rect: FULL, text: 'You might be interested in  TRF RIPPED JEANS' });
  const doc2 = makeDocument([app2, aside2, promo], () => promo.hidden ? target : promo);
  const note2 = shippedProbe(target, doc2, win);
  check('36 a plain layer releases the target\'s ancestors only', promo.hidden && app2.getAttribute('inert') === null && aside2.getAttribute('inert') !== null && /interactive again/.test(note2), note2);
}

if (failures) { console.log(failures + ' failure(s) of ' + checks + ' checks'); process.exit(1); }
console.log('all ' + checks + ' overlay-hider checks passed');
