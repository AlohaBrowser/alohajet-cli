import Foundation

/// The in-page predicate that decides whether a form field's VALUE may leave the page.
///
/// One definition, injected into both page-side scripts — the document walker
/// (``buildAgentDomTreeScript(highlight:focusInteractive:)``, which feeds the read
/// markdown) and the `window.__aloha` runtime (``buildInpageAlohaRuntime()``, which
/// backs `get_text`). Those are the only two paths a page's own text takes to the
/// model, and a password typed into a login form travelled BOTH of them: the walker
/// folded `input.value` into the element's comprehensive text, so `read` printed
/// `input(password, "hunter2")`, and `get_text` returned `el.value` verbatim.
///
/// Masking happens in the page, not in Swift, because that is the only place the value
/// exists before it is copied into a CDP response — a Swift-side filter would be
/// redacting a secret that had already crossed the wire and into whatever the host logs.
///
/// The fragment list mirrors ``SENSITIVE_FIELD_NAMES`` in ToolABI (which drives the
/// credential-typing guard) with one deliberate difference: bare `pass` is NOT here.
/// It matches "Passenger", "Passport" and "Bypass", and blanking those fields' values
/// would corrupt ordinary page reads silently — the exact failure mode that makes a
/// serializer untrustworthy. `password` / `passwd` / `pwd`, plus `type=password` and
/// the `autocomplete` tokens, cover the fields that actually hold a credential.
/// `passphrase` is added on top of ToolABI's list: a live page named its field that and
/// the value came through in the clear.
nonisolated let sensitiveFieldPredicateJS = """
function __alohaIsSensitiveField(el) {
  try {
    if (!el || !el.tagName) return false;
    var tag = el.tagName.toLowerCase();
    if (tag !== 'input' && tag !== 'textarea') return false;
    if ((el.type || '').toLowerCase() === 'password') return true;
    var hay = [
      el.name || '', el.id || '', el.placeholder || '',
      (el.getAttribute && el.getAttribute('aria-label')) || '',
      (el.getAttribute && el.getAttribute('autocomplete')) || ''
    ].join(' ').toLowerCase();
    var frags = ['password', 'passwd', 'passphrase', 'pwd', 'new-password',
                 'current-password', 'newpassword', 'currentpassword'];
    for (var i = 0; i < frags.length; i++) { if (hay.indexOf(frags[i]) !== -1) return true; }
    return false;
  } catch (e) { return false; }
}
"""

/// What a masked field reads as. Named rather than blank: a caller that sees an empty
/// string assumes the field is empty and types into it again; one that sees this knows
/// the field has a value it is not allowed to read.
nonisolated let sensitiveFieldMaskJS = "'[redacted: credential field]'"
