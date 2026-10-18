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
/// The fragment list mirrors ``sensitiveFieldNames`` in ToolABI (which drives the
/// credential-typing guard) with one deliberate difference: bare `pass` is NOT here.
/// It matches "Passenger", "Passport" and "Bypass", and blanking those fields' values
/// would corrupt ordinary page reads silently — the exact failure mode that makes a
/// serializer untrustworthy. `password` / `passwd` / `pwd`, plus `type=password` and
/// the `autocomplete` tokens, cover the fields that actually hold a credential.
/// `passphrase` is added on top of ToolABI's list: a live page named its field that and
/// the value came through in the clear.
///
/// AND A KEY, A TOKEN, A SECRET, A RECOVERY CODE, A SEED PHRASE, as whole words of the field's
/// name, id, placeholder or label (`api_key`, "API key", `accessToken`, `client-secret`,
/// "Recovery code", "Seed phrase", "Mnemonic"), or a value in the shape of a well-known key
/// (`sk-live-…`, `ghp_…`, `xoxb-…`, `AKIA…`, `AIza…`): since the app's reads carry field values
/// (alohajet 88f4abd5), `<input name=api_key aria-label="API key" value="sk-live-…">` read
/// `input("API key", value="sk-live-…")` into the model's context and the backend's trajectory
/// (W6 client review). Aligned with the snips mask's whole tokens (`SnipsCredentialMask`).
/// ``isSecretInputField(type:autocomplete:attributes:placeholder:value:)`` holds the same rule
/// on the Swift side (``secretFieldWords``, ``secretValueShapes``).
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
    var words = [el.name || '', el.id || '', el.placeholder || '',
      (el.getAttribute && el.getAttribute('aria-label')) || ''].join(' ')
      .replace(/([a-z])([A-Z])/g, '$1 $2').toLowerCase().replace(/[^a-z0-9]+/g, ' ');
    if (/\\b(?:api ?key|api ?token|access ?(?:key|token)|secret ?key|private ?key|client ?secret|auth ?token|bearer|refresh ?token|token|secret|recovery ?(?:code|key|phrase)s?|backup ?codes?|seed ?(?:phrase|words?)|mnemonic)\\b/.test(' ' + words + ' ')) return true;
    var value = (el.value || '').trim();
    if (/^(?:(?:sk|pk|rk)[-_](?:live|test)[-_]|sk-[A-Za-z0-9_-]{16,}$|gh[pousr]_[A-Za-z0-9]{20,}$|xox[abposr]-|AKIA[0-9A-Z]{16}$|AIza[0-9A-Za-z_-]{30,}$)/.test(value)) return true;
    return false;
  } catch (e) { return false; }
}
"""

/// What a masked field reads as. Named rather than blank: a caller that sees an empty
/// string assumes the field is empty and types into it again; one that sees this knows
/// the field has a value it is not allowed to read.
nonisolated let sensitiveFieldMaskJS = "'[redacted: credential field]'"

/// The same mask as the Swift side sees it once the page has sent it back: `parseDomNode` treats
/// a field holding exactly this text as secret, so it renders `value=(hidden)` like a password
/// rather than quoting the mask as if it were the field's contents.
nonisolated let sensitiveFieldMaskText = "[redacted: credential field]"
