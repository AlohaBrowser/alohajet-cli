import Foundation
import ToolABI

// THE RECEIPTS A CLICK CAN CARRY, and the two probes that keep a click off a consent prompt.
//
// Ported from AlohaBrowser/alohajet's `AlohaBridge` (branch windows-on-snips), where the agent's
// copies of the page tools carried them before this package replaced those copies. Each helper
// keeps the measurement that justified it in its own doc comment.

extension AgentBrowserBridge {
    /// WHY A CLICK THAT "WORKED" CHANGED NOTHING — the two answers the page can give and the receipt
    /// never asked for.
    ///
    /// `handleClickPendingRequest` computes coordinates from `getBoundingClientRect` and dispatches
    /// `Input.dispatchMouseEvent`; if no exception is thrown it reports success. Nothing hit-tests the
    /// point. `elementFromPoint` exists in this codebase only inside the DOM WALK, where it drives the
    /// `occ:` markers — so a click delivered onto whatever is covering the target is indistinguishable
    /// from a click on the target.
    ///
    /// Measured on run 33889241270, tasks 647/649: the model filled the Postmill submit form
    /// correctly — the snapshot shows the title and a 330-character body in their fields — clicked
    /// `[Create submission]`, and got a byte-identical page back. It clicked it five more times, then
    /// gave up and returned the post text as its answer. Nothing was ever posted. Two mechanisms
    /// produce exactly that, and the receipt distinguished neither:
    ///
    ///   * the forum combobox one row above the button was left `aria: EXPANDED`, so an open overlay
    ///     may sit over the button and take the click;
    ///   * the form has two `This field is required` fields and HTML5 validation refuses the submit,
    ///     which draws a NATIVE BUBBLE — not a DOM node — so the page genuinely does not change.
    ///
    /// Runs only when the click landed and the URL did not move, so the happy path pays nothing.
    /// Returns nil when the page cannot answer or has nothing to add: a probe must never turn a
    /// working receipt into a broken one.
    func clickObstructionNote(alohaId: String) async -> String? {
        let escaped = alohaId.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        (function() {
          try {
            var el = document.querySelector('[aloha-id="\(escaped)"]');
            if (!el) return "";
            var r = el.getBoundingClientRect();
            var top = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
            var hitSelf = !!top && (top === el || el.contains(top) || top.contains(el));
            var note = "";
            if (!hitSelf && top) {
              var other = top.getAttribute && top.getAttribute('aloha-id');
              note += " The click was delivered to <" + top.tagName.toLowerCase()
                   + (other ? " aloha-id=\\"" + other + "\\"" : "")
                   + ">, which is NOT that element and is covering it — close whatever is open over it"
                   + " (an expanded dropdown, a dialog) and click again.";
            }
            // ONLY A SUBMIT CONTROL CAN BE REFUSED. Run 33898833957 shipped this note on every
            // landed click inside a form, so clicking the title field or the combobox reported
            // "the form REFUSED to submit" when nothing had been submitted -- true about the
            // form's validity at that instant, false about what had just happened. The model read
            // it as a rejected submit and re-typed the fields: `page_type` went 34 -> 163 across
            // the same three tasks and every attempt ran past 720s, three into the 902s cap.
            // A <button> with no type IS a submit button, which is exactly what Postmill uses.
            var tag = (el.tagName || '').toLowerCase();
            var typeAttr = ((el.getAttribute && el.getAttribute('type')) || '').toLowerCase();
            var isSubmitControl = (tag === 'button' && typeAttr !== 'button' && typeAttr !== 'reset')
                               || (tag === 'input' && (typeAttr === 'submit' || typeAttr === 'image'));
            var form = isSubmitControl ? (el.form || (el.closest ? el.closest('form') : null)) : null;
            if (form && typeof form.checkValidity === 'function' && !form.checkValidity()) {
              var bad = form.querySelector(':invalid');
              var name = bad ? (bad.getAttribute('name') || bad.getAttribute('id')
                                || bad.getAttribute('aloha-id') || bad.tagName.toLowerCase()) : "a field";
              var why = bad && bad.validationMessage ? " (" + bad.validationMessage + ")" : "";
              note += " The form REFUSED to submit because " + name + " is not valid" + why
                   + ". The browser shows that as a native bubble, which is not part of the page, so"
                   + " nothing here changes however many times you click. Fill or correct that field.";
            }
            // A SUBMIT THAT DID NOTHING AND EXPLAINED NOTHING is the largest silent failure this
            // bench has, and until now it was indistinguishable from a click that missed.
            //
            // Measured on run 34023177675 across 488 clicks on a submit control: 52% landed,
            // moved nothing, and produced no note at all, against 3% that failed HTML5 validity
            // and 19% that actually created something. One attempt clicked the same submit button
            // 62 times, another 50, another 37 -- because every click "succeeded" and said so.
            //
            // The two branches above cover a click that hit the wrong element and a form the
            // BROWSER rejects. Neither covers the common case: a widget-backed field (a combobox
            // or autocomplete whose real value lives in a hidden input) that the model filled
            // visually without committing, so `checkValidity()` is perfectly happy and the page's
            // own handler declines. Nothing about that is specific to one site -- it is what every
            // rich form looks like from outside.
            //
            // So say the one thing that IS known: the submit did not take, and the page is not
            // complaining. That turns an invisible no-op into a fact, and it is deliberately not
            // advice about which field to fix, because this probe cannot know.
            //
            // NOT `isSubmitControl && form`. That was the first cut and it fired ZERO times on
            // run 34027485836, while 226 clicks on `button.button` landed, moved nothing and said
            // nothing -- 53% of every click on a real submit control. Two assumptions in it are
            // wrong on a modern form: that a submit control declares `type="submit"` (a JS-driven
            // button is `type="button"`, which `isSubmitControl` excludes ON PURPOSE, because the
            // VALIDITY branch above needs that exclusion -- see `320d5e6`), and that it is
            // associated with a `<form>` at all (this page's forum field is a select2 widget).
            //
            // So the condition is what is actually known rather than what the markup ought to be:
            // the thing clicked is a BUTTON, the click landed, the page did not navigate, nothing
            // about the control changed, and neither branch above had anything to say.
            //
            // `input` is admitted ONLY for the four button-shaped types. Admitting `input`
            // wholesale would put this note on every text field a model clicks into, which is
            // exactly the regression `320d5e6` was written to undo (page_type 34 -> 163).
            var buttonRole = (el.getAttribute && el.getAttribute('role')) === 'button';
            var buttonInput = tag === 'input'
              && (typeAttr === 'submit' || typeAttr === 'image'
                  || typeAttr === 'button' || typeAttr === 'reset');
            var buttonish = tag === 'button' || buttonInput || buttonRole;
            if (buttonish && note === "") {
              // WHAT THE PROBE COULD SEE, so the next run answers this rather than another guess:
              // whether a form was found at all, and whether the browser considers it valid. The
              // first cut assumed both and was silently inert for a whole run.
              var anyForm = el.form || (el.closest ? el.closest('form') : null);
              var found = anyForm
                ? (typeof anyForm.checkValidity === 'function'
                     ? (anyForm.checkValidity() ? 'a valid form' : 'an invalid form')
                     : 'a form')
                : 'no form';
              note = " That click did NOTHING observable: the page did not navigate, nothing on"
                   + " the control changed, and nothing here reports an error (" + found + ")."
                   + " Clicking it again will do the same thing. If this was meant to submit, a"
                   + " field whose value is held by a widget -- a combobox, an autocomplete, a"
                   + " date picker -- can look filled while holding nothing the page accepts:"
                   + " re-read this page, check that each field you set now SHOWS the value you"
                   + " intended, and commit any open widget before pressing it again.";
            }
            return note;
          } catch (e) { return ""; }
        })()
        """
        guard let value = try? await backend.evaluateViaCdp(script),
              let text = value.stringValue, !text.isEmpty else { return nil }
        return text
    }

    /// WHAT THE CONTROL SAYS ABOUT ITSELF, read either side of a click.
    ///
    /// `pageFingerprint` below compares the document generation, the element count and the URL.
    /// A toggle changes none of the three: `Subscribe` becomes `Unsubscribe` in the same node, in
    /// the same document, at the same address. So the receipt said the page had not changed, the
    /// model concluded the click had done nothing, and clicked again — see `ControlStateChange`
    /// for the six runs in which that cost every discarded attempt on the preset.
    ///
    /// Cheap enough to run on both sides of every landed click: one `querySelector` and a handful
    /// of property reads, nothing that serializes the document. Returns nil when the page cannot
    /// answer, which is treated as "no note" and never as "the element vanished".
    func controlState(alohaId: String) async -> ControlState? {
        let escaped = alohaId.replacingOccurrences(of: "\"", with: "\\\"")
        let script = #"""
        (function() {
          try {
            var el = document.querySelector('[aloha-id="\#(escaped)"]');
            if (!el) return JSON.stringify({ present: false });
            function attr(n) {
              var v = el.getAttribute ? el.getAttribute(n) : null;
              return (v === null || v === undefined) ? null : String(v);
            }
            function cap(s) {
              s = (s === null || s === undefined) ? '' : String(s);
              return s.length > 80 ? s.slice(0, 80) : s;
            }
            // THE NAME A READER WOULD USE. For a form control its own text is empty, so the label
            // is what names it; for everything else the text IS the name, and it is the half that
            // flips on a toggle.
            var tag = (el.tagName || '').toLowerCase();
            var name = '';
            if (tag === 'input' || tag === 'textarea' || tag === 'select') {
              name = attr('aria-label') || attr('placeholder') || attr('name') || '';
            } else {
              name = (el.textContent || '').replace(/\s+/g, ' ').trim();
              if (!name) name = attr('aria-label') || attr('title') || '';
            }
            // A DOM property when the element has one, the ARIA mirror otherwise: a real checkbox
            // reports `checked`, a div pretending to be one reports `aria-checked`, and a receipt
            // should not care which kind of button the site chose to build.
            var checked = (typeof el.checked === 'boolean')
              ? (el.checked ? 'true' : 'false') : attr('aria-checked');
            var disabled = (typeof el.disabled === 'boolean')
              ? (el.disabled ? 'true' : 'false') : attr('aria-disabled');
            var value = (typeof el.value === 'string') ? cap(el.value) : null;
            // For page_click's duplicate-submit read: is this a submit control inside a form? A
            // <button> with no type IS a submit button (Postmill's shape); a type="button" is not.
            var form = el.form || (el.closest ? el.closest('form') : null);
            var typeAttr = String((el.getAttribute && el.getAttribute('type')) || '').toLowerCase();
            var submits = (tag === 'button' && typeAttr !== 'button' && typeAttr !== 'reset')
                       || (tag === 'input' && (typeAttr === 'submit' || typeAttr === 'image'));
            return JSON.stringify({
              present: true,
              inForm: !!form,
              submits: !!submits,
              name: cap(name),
              pressed: attr('aria-pressed'),
              checked: checked,
              expanded: attr('aria-expanded'),
              selected: attr('aria-selected'),
              disabled: disabled,
              value: value
            });
          } catch (e) { return ''; }
        })()
        """#
        guard let value = try? await backend.evaluateViaCdp(script) else { return nil }
        return ControlState.parse(value.stringValue)
    }

    /// WHAT IS CURRENTLY TYPED INTO THIS PAGE'S FORM FIELDS, as one opaque string.
    ///
    /// Only used to tell one filled-in form from another, so that submitting the identical form a
    /// second time can be refused -- see `submissionKey`. `pageFingerprint` cannot serve: it is
    /// generation, element count and href, so a blank form and a filled one look the same, and two
    /// different titles look the same too.
    ///
    /// SECRETS ARE NEVER READ. Password and hidden inputs are skipped by type, not by name, so a
    /// credential does not enter this string even before it is digested. Each value is capped so a
    /// long post body cannot make the read expensive, and the caller digests the result, so what is
    /// retained is never the text itself.
    func formValues() async -> String? {
        let script = #"""
        (function() {
          try {
            // EVERY control and the WHOLE value, digested here so the wire carries one short hash
            // rather than the form: the first version kept 60 controls and 200 characters per value,
            // so two forms differing only in a 61st field or the tail of a long body collided and
            // the second was refused (review of the first version). FNV-1a, 32-bit, like the
            // fingerprint. Password, hidden and file inputs stay out of the identity.
            var nodes = document.querySelectorAll("input, textarea, select");
            var hash = 0x811c9dc5, count = 0;
            function mix(s) {
              s = String(s == null ? "" : s);
              for (var j = 0; j < s.length; j++) { hash ^= s.charCodeAt(j); hash = Math.imul(hash, 0x01000193) >>> 0; }
              hash ^= 0x1f; hash = Math.imul(hash, 0x01000193) >>> 0;
            }
            for (var i = 0; i < nodes.length; i++) {
              var el = nodes[i];
              var type = String(el.type || "").toLowerCase();
              if (type === "password" || type === "hidden" || type === "file") { continue; }
              var value;
              if (type === "checkbox" || type === "radio") {
                value = el.checked ? "1" : "0";
              } else if (el.tagName && el.tagName.toLowerCase() === "select" && el.multiple) {
                var picked = [];
                for (var k = 0; k < el.options.length; k++) { if (el.options[k].selected) picked.push(el.options[k].value); }
                value = picked.join("\u001f");
              } else {
                value = el.value == null ? "" : el.value;
              }
              mix(el.name || el.id || String(i)); mix(value); count++;
            }
            return count ? ("v1:" + count + ":" + hash.toString(16)) : "";
          } catch (e) { return ""; }
        })()
        """#
        guard let value = try? await backend.evaluateViaCdp(script),
              let text = value.stringValue else { return nil }
        return text
    }

    /// HIDE WHATEVER COVERS THE CLICK TARGET, without answering it, and say so.
    ///
    /// WHY. A click is delivered as a mouse event at the target's centre, so a consent banner or
    /// a promo layer sitting on top receives it instead. The read already flags the cover
    /// (`occ:` legend, "dismiss/close it to interact") and `clickObstructionNote` explains it
    /// after the fact, but nothing removed it: on the US Open run (llmdex tag
    /// `usopen-search-20260917-155625-b02b`) the agent clicked the same covered control four
    /// times, navigated away and back, re-read the same blocked page, and only proceeded once
    /// the user pressed "Accept All Cookies" by hand.
    ///
    /// NOT ACCEPTING, NOT REJECTING. Consent is the user's decision, and banners do not all
    /// offer the same buttons. Hiding the layer (`display:none`) records nothing, changes no
    /// cookie, and leaves the page underneath usable. The layer may come back on the next
    /// document; this runs before every click, so that costs one probe.
    ///
    /// GENERAL BY CONSTRUCTION, with a vendor list on top. The cover is found by hit-testing the
    /// target and climbing to the covering subtree's root, so it works on any site's markup. It
    /// is hidden only when it is an OVERLAY in the layout sense -- a `position:fixed`/`sticky`
    /// layer, or a shadow-DOM host planted at the document root the way consent widgets are --
    /// AND one of three things holds: it is a known CMP's own container (`[consent=cmp:<vendor>]`);
    /// it is a consent prompt by the container test `hideConsentLayerContaining` uses (banner or
    /// modal shape, no landmark, no text field, 40..2500 characters, 1..8 controls, cookie
    /// vocabulary in its name -- or a visible consent UI per the page's `__tcfapi`/`__gpp` ping);
    /// or it blankets at least 60% of the viewport while holding no form fields (`[blanket]`).
    /// A layer holding text fields, selects or textareas is NEVER hidden, whatever its text: a
    /// login, a size drawer or a checkout the model itself opened must not be swept away because
    /// a stray click landed under it. A small absolute dropdown, a sticky header the target
    /// scrolled beneath, or an inline overlap is never touched. A hidden modal's `inert` lock on
    /// the rest of the page is released with it.
    ///
    /// THREE PASSES because consent libraries split into a backdrop and a dialog: hiding the
    /// dialog leaves the backdrop taking the click, so the probe repeats until the target is hit
    /// or nothing qualifies. The body/html scroll lock these libraries set inline is released too.
    ///
    /// Returns the sentence to append to the receipt, or nil when nothing was hidden, when the
    /// element is not on the page, or when the probe throws -- a failed probe must never cost the
    /// caller its click.
    func hideCoveringOverlay(alohaId: String) async -> String? {
        let escaped = alohaId.replacingOccurrences(of: "\"", with: "\\\"")
        // THE CALL SITS ON ITS OWN LINE. `overlayHiderSource` ends in a `//` comment, and a Swift
        // multi-line literal drops the newline before its closing delimiter, so `(\(source))(el…)`
        // on one line put the call INSIDE that comment: a SyntaxError the page answered in 2 ms,
        // `try?` turned into nil, and eight clicks went into the banner while the fake-DOM
        // harness -- which added its own newline -- stayed green. `overlay_hider.js` now compiles
        // this exact shape.
        let script = """
        (function() {
          try {
            var el = document.querySelector('[aloha-id="\(escaped)"]');
            if (!el) return "";
        \(Self.overlayHiderSource)
            return hideCoveringOverlay(el, document, window);
          } catch (e) { return ""; }
        })()
        """
        guard let value = try? await backend.evaluateViaCdp(script),
              let text = value.stringValue, !text.isEmpty else { return nil }
        return text
    }

    /// POLICY: NO NEW COOKIES. When the click's TARGET is a control inside a consent prompt --
    /// Accept, Reject, Manage, Close, a toggle -- the prompt is hidden and nothing is clicked. The
    /// agent answers no consent prompt on the user's behalf, in either direction, so the site
    /// records nothing beyond what it set on load. Measured before this existed: in two of three
    /// ATP runs the model reached for "Accept All Cookies" as its way past the banner, and two
    /// OneTrust consent cookies were written each time.
    ///
    /// THE PROMPT IS FOUND AS A CONTAINER, not by the control's label. The first version asked
    /// "label sounds like a consent action AND a consent word anywhere in the fixed layer", and a
    /// login dialog whose small print mentioned the privacy policy, an age gate, a region picker
    /// and a checkout footer each qualified: their Continue and Save were refused and the dialogs
    /// hidden. Three layers now decide, strongest first (see `overlayHiderSource`): the page's
    /// CMP API reporting a visible consent UI (IAB TCF v2 / GPP ping), a known CMP's container by
    /// the id or class its own script writes, and a structural match -- shape, no landmark, no
    /// text field, 40..2500 characters, 1..8 controls -- with cookie vocabulary in the container's
    /// NAME. The receipt ends in `[consent=tcf|gpp|cmp:<vendor>|heuristic]` so a run archive says
    /// which layer fired; `consentActionPattern` only words it.
    ///
    /// Returns the receipt text to return INSTEAD of a click, or nil when the target is not a
    /// consent control (the ordinary click proceeds). Not an error: the model's goal, getting
    /// past the prompt, is met, and the fresh page it needs comes with the receipt.
    func hideConsentLayerContaining(alohaId: String) async -> String? {
        let escaped = alohaId.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        (function() {
          try {
            var el = document.querySelector('[aloha-id="\(escaped)"]');
            if (!el) return "";
        \(Self.overlayHiderSource)
            return hideConsentLayerContaining(el, document, window);
          } catch (e) { return ""; }
        })()
        """
        guard let value = try? await backend.evaluateViaCdp(script),
              let text = value.stringValue, !text.isEmpty else { return nil }
        return text
    }

    /// The labels a consent prompt's controls carry -- Accept, Reject, Manage, Settings, Save,
    /// Close, an "x" glyph, in the languages the agent meets. It GATES NOTHING: whether a click is
    /// refused is decided by the container the control sits in (see `overlayHiderSource`). It
    /// only words the receipt ("a control of" against "a control inside" a prompt), and it is
    /// exported for the callers that classify a landed click's label the same way.
    nonisolated static let consentActionPattern = "accept|agree|allow|consent|cookie|required|necessary|essential|reject|decline|refuse|deny|manage|settings|preferences|options|customi[sz]e|save|confirm|got it|^ok(ay)?$|continue|understand|zustimmen|akzeptieren|ablehnen|einstellungen|accepter|refuser|param|aceptar|rechazar|configur|accetta|rifiuta|aceitar|recusar|\\u043f\\u0440\\u0438\\u043d\\u044f\\u0442\\u044c|\\u043e\\u0442\\u043a\\u043b\\u043e\\u043d\\u0438\\u0442\\u044c|\\u043d\\u0430\\u0441\\u0442\\u0440\\u043e\\u0439\\u043a|\\u0441\\u043e\\u0433\\u043b\\u0430\\u0441|close|dismiss|schlie(\\u00df|ss)en|cerrar|fermer|chiudi|fechar|\\u0437\\u0430\\u043a\\u0440\\u044b\\u0442\\u044c|^\\s*[x\\u00d7\\u2715\\u2716]\\s*$"

    /// The page-side logic behind `hideCoveringOverlay(alohaId:)` and
    /// `hideConsentLayerContaining(alohaId:)`: shared helpers plus the two functions, as STATEMENTS
    /// the wrappers evaluate before calling one of them. `Tests/BrowserToolsTests/overlay_hider.js`
    /// runs the identical source against a fake DOM in Node, extracting it by the two markers and
    /// substituting `\(consentActionPattern)` the way Swift does.
    static let overlayHiderSource = """
        // BEGIN overlay-hider js
        // CONTAINER FIRST. The question is never "does this button's label sound like Accept" but
        // "does this button sit inside a cookie-consent prompt". Three layers answer it, strongest
        // first, and the first that fires decides:
        //   1. the page's own CMP API -- IAB TCF v2 `__tcfapi` ping (PingReturn.displayStatus),
        //      IAB GPP `__gpp` ping (cmpDisplayStatus): 'visible' says a consent UI is on screen.
        //      It names no node, so it only lets a structural match through without the vocabulary.
        //   2. a known CMP's container, by the id or class its vendor's own script writes.
        //   3. a structural match -- the highest fixed/sticky ancestor, a dialog, or a shadow host at the
        //      body, shaped like a banner (full-width band at the top or bottom) or a backdropped modal,
        //      holding no page landmark, no text field, 40..2500 characters and 1..8 controls -- AND
        //      cookie vocabulary in its NAME: aria-label, aria-labelledby, first heading, first 200
        //      characters. Not anywhere in its text: every dialog's small print mentions privacy.
        // The control's own label gates nothing any more; it only words the receipt. The previous
        // version asked "action word in the label AND a consent word anywhere in the layer", and a
        // fixed login dialog ("By continuing you agree to our Privacy Policy", Continue), an age gate,
        // a region picker and a sticky checkout footer with a Privacy link each satisfied it: refused,
        // and hidden. Each receipt carries [consent=tcf|gpp|cmp:<vendor>|heuristic] so a run archive
        // says which layer fired.
        var CONSENT_ACTION = /\(consentActionPattern)/i;
        // Words that are only ever about cookies, in the languages the agent meets. "privacy",
        // "accept", "agree", "preferences", "Datenschutz" (= privacy) qualify for nothing. "tracking"
        // is kept off the checkout page's order tracking.
        var CONSENT_WORDS = /cookie|consent|consenso|gdpr|rgpd|dsgvo|ccpa|(?<!order |shipment |parcel |package )tracking(?! number| code| id| your order)|we use|einwilligung|\\u043a\\u0443\\u043a\\u0438|\\u0441\\u043e\\u0433\\u043b\\u0430\\u0441/i;
        // The containers the consent-management platforms ship, by the ids and classes their own
        // scripts write. A hit names the node to hide outright. Hand-written, twenty vendors;
        // autoconsent's and EasyList Cookie's rule files are the follow-up, not this list.
        var CMP_CONTAINERS = [
          ['onetrust', '#onetrust-consent-sdk, #onetrust-banner-sdk, #onetrust-pc-sdk, .onetrust-pc-dark-filter'],
          ['cookiebot', '#CybotCookiebotDialog, #CybotCookiebotDialogBodyUnderlay'],
          ['didomi', '#didomi-host, #didomi-popup'],
          ['usercentrics', '#usercentrics-root, #usercentrics-cmp-ui'],
          ['quantcast', '#qc-cmp2-container'],
          ['trustarc', '#truste-consent-track, #consent_blackbar, .truste_box_overlay'],
          ['sourcepoint', 'iframe[id^="sp_message_iframe"], [id^="sp_message_container"]'],
          ['klaro', '#klaro, .klaro .cookie-modal'],
          ['osano', '.osano-cm-window'],
          ['cookieyes', '#cky-consent-container, .cky-overlay'],
          ['complianz', '#cmplz-cookiebanner-container'],
          ['iubenda', '#iubenda-cs-banner'],
          ['axeptio', '#axeptio_overlay'],
          ['borlabs', '#BorlabsCookieBox'],
          ['tarteaucitron', '#tarteaucitronRoot, #tarteaucitronAlertBig'],
          ['termly', '#termly-code-snippet-support'],
          ['cookieinformation', '#coiOverlay'],
          ['cookiefirst', '#cookiefirst-root'],
          ['fundingchoices', '.fc-consent-root'],
          ['shopify', '#shopify-pc__banner']
        ];
        function ohText(n) {
          var t = '';
          try { t = n.innerText || n.textContent || ''; } catch (e) {}
          if (!t && n.shadowRoot) { try { t = n.shadowRoot.textContent || ''; } catch (e) {} }
          return String(t).replace(/\\s+/g, ' ').trim();
        }
        function ohPosition(n, window) {
          try { return window.getComputedStyle(n).position || ''; } catch (e) { return ''; }
        }
        // The parent across a shadow boundary: a control inside a CMP's shadow root climbs to its host.
        function ohParent(n) {
          if (!n) return null;
          if (n.parentElement) return n.parentElement;
          try { var r = n.parentNode; if (r && r.host) return r.host; } catch (e) {}
          return null;
        }
        function ohMatches(n, sel) { try { return !!(n && n.matches && n.matches(sel)); } catch (e) { return false; } }
        // Descendants, the host's shadow tree included: a shadow host's own querySelectorAll sees none of it.
        function ohAll(n, sel) {
          var out = [];
          try { var a = n.querySelectorAll(sel); for (var i = 0; i < a.length; i++) out.push(a[i]); } catch (e) {}
          try { if (n.shadowRoot) { var b = n.shadowRoot.querySelectorAll(sel); for (var j = 0; j < b.length; j++) out.push(b[j]); } } catch (e) {}
          return out;
        }
        // NEVER THE PAGE ITSELF. A node that holds a landmark (main, header, nav) is the app, not a
        // layer over it; hiding it blanks the site (zara.com, 2026-09-20, six runs on a white page).
        function ohHasLandmark(n) { return ohAll(n, 'main, [role=main], header, nav, [role=navigation]').length > 0; }
        // A vendor's container is not the page by construction, but it is still never hidden while it
        // holds the page's main content; a nav inside its preference centre (OneTrust's does) is fine.
        function ohHoldsMain(n) { return ohAll(n, 'main, [role=main]').length > 0; }
        // Text fields. A checkbox or a switch is what a preference centre is made of and does not count.
        function ohHasFormFields(n) {
          return ohAll(n, 'input:not([type=hidden]):not([type=checkbox]):not([type=button]):not([type=submit]):not([type=reset]):not([type=image]), select, textarea').length > 0;
        }
        function ohControls(n) { return ohAll(n, 'button, a, [role=button], [role=link], input[type=button], input[type=submit]'); }
        function ohCoverage(n, window) {
          var vw = Math.max(1, window.innerWidth || 1), vh = Math.max(1, window.innerHeight || 1);
          var r = n.getBoundingClientRect();
          return (Math.max(0, r.width) * Math.max(0, r.height)) / (vw * vh);
        }
        // What the container calls itself: accessible name, first heading, first 200 characters.
        function ohName(n, document) {
          var parts = [];
          try {
            var al = n.getAttribute && n.getAttribute('aria-label'); if (al) parts.push(al);
            var by = n.getAttribute && n.getAttribute('aria-labelledby');
            if (by) String(by).split(/\\s+/).forEach(function (id) { var e = id && document.getElementById(id); if (e) parts.push(ohText(e)); });
          } catch (e) {}
          var h = ohAll(n, 'h1, h2, h3, h4, [role=heading]');
          if (h.length) parts.push(ohText(h[0]));
          parts.push(ohText(n).slice(0, 200));
          return parts.join(' ');
        }
        function ohDescribe(n, t) {
          var id = n.getAttribute && n.getAttribute('aloha-id');
          var d = '<' + String(n.tagName || 'element').toLowerCase() + (id ? ' aloha-id="' + id + '"' : '') + '>';
          if (t) d += ' "' + (t.length > 60 ? t.slice(0, 60) : t) + '"';
          return d;
        }
        // LAYER 1: the CMP's own API. Real CMPs answer `ping` synchronously; the IAB stub (before the
        // CMP loads) answers with cmpLoaded:false and no displayStatus, which reads as "unknown" here.
        // Only `ping` is ever sent: nothing here records a choice through the API either.
        function ohCmpApi(window) {
          var out = { api: '', visible: null, id: null };
          function probe(w) {
            try {
              if (typeof w.__tcfapi === 'function') {
                var p = null; w.__tcfapi('ping', 2, function (r) { p = r; });
                if (p && typeof p === 'object') { out.api = 'tcf'; out.id = p.cmpId || null; if (p.displayStatus) out.visible = p.displayStatus === 'visible'; }
              }
              if (!out.api && typeof w.__gpp === 'function') {
                var g = null; w.__gpp('ping', function (r) { g = r; });
                if (g && typeof g === 'object') { out.api = 'gpp'; out.id = g.cmpId || null; if (g.cmpDisplayStatus) out.visible = g.cmpDisplayStatus === 'visible'; }
              }
              if (!out.api && typeof w.__uspapi === 'function') out.api = 'usp';
            } catch (e) {}
          }
          probe(window);
          if (!out.api) { try { if (window.top && window.top !== window) probe(window.top); } catch (e) {} }
          return out;
        }
        // LAYER 2: the highest known CMP container on the ancestor chain, shadow hosts included.
        function ohKnownCmp(n, document) {
          var found = null;
          for (var a = n; a && a !== document.body && a !== document.documentElement; a = ohParent(a)) {
            for (var i = 0; i < CMP_CONTAINERS.length; i++) {
              if (ohMatches(a, CMP_CONTAINERS[i][1])) { found = { node: a, name: CMP_CONTAINERS[i][0] }; break; }
            }
          }
          return found;
        }
        // LAYER 3, the candidate: the HIGHEST fixed/sticky ancestor, else a shadow host planted at the
        // body, else the nearest dialog.
        function ohCandidate(el, document, window) {
          var cand = null, dialog = null;
          for (var n = ohParent(el); n && n !== document.body && n !== document.documentElement; n = ohParent(n)) {
            var pos = ohPosition(n, window);
            if (pos === 'fixed' || pos === 'sticky') cand = n;
            else if (n.shadowRoot && ohParent(n) === document.body) cand = n;
            if (!dialog && ohMatches(n, '[role=dialog], [role=alertdialog], dialog[open]')) dialog = n;
          }
          return cand || dialog;
        }
        // Shaped like a consent prompt: a band spanning the viewport at its top or bottom, or a modal
        // over a backdrop -- its own box covering most of the viewport, or a textless sibling doing so.
        function ohShape(c, el, document, window) {
          var vw = Math.max(1, window.innerWidth || 1), vh = Math.max(1, window.innerHeight || 1);
          var r = c.getBoundingClientRect();
          if (r.width >= 0.6 * vw && (r.top <= 8 || r.top + r.height >= vh - 8)) return 'banner';
          if (ohCoverage(c, window) >= 0.6) return 'modal';
          var sets = [];
          try { var p = ohParent(c); if (p && p.children) sets.push(p.children); } catch (e) {}
          try { if (document.body && document.body.children) sets.push(document.body.children); } catch (e) {}
          for (var s = 0; s < sets.length; s++) {
            for (var k = 0; k < sets[s].length; k++) {
              var sib = sets[s][k];
              try {
                if (sib === c || sib.contains(c) || sib.contains(el)) continue;
                if (ohCoverage(sib, window) >= 0.6 && ohText(sib).length < 40) return 'modal';
              } catch (e) {}
            }
          }
          return '';
        }
        function ohStructural(c, el, document, window) {
          if (!c || ohHasLandmark(c) || ohHasFormFields(c)) return false;
          var t = ohText(c);
          if (t.length < 40 || t.length > 2500) return false;
          var k = ohControls(c).length;
          if (k < 1 || k > 8) return false;
          return !!ohShape(c, el, document, window);
        }
        // What gets hidden for a structural hit: the candidate, widened to a body child only while
        // the child stays short and holds no landmark and no text field -- a consent widget's wrapper
        // never contains the page, an app root always does.
        function ohWiden(c, document) {
          var root = c;
          for (var p = ohParent(c); p && p !== document.body && p !== document.documentElement; p = ohParent(p)) {
            if (ohText(p).length > 2000 || ohHasLandmark(p) || ohHasFormFields(p)) break;
            root = p;
          }
          return root;
        }
        // THE DECISION for a control the click aims at: the node to hide and the layer that fired, or null.
        function ohDetectConsent(el, document, window, api) {
          var cmp = ohKnownCmp(el, document);
          if (cmp && !ohHoldsMain(cmp.node)) return { node: cmp.node, signal: 'cmp:' + cmp.name };
          var c = ohCandidate(el, document, window);
          if (!c || !ohStructural(c, el, document, window)) return null;
          var vocab = CONSENT_WORDS.test(ohName(c, document));
          if (!vocab && api.visible !== true) return null;
          return { node: ohWiden(c, document), signal: api.visible === true ? api.api : 'heuristic' };
        }
        // display:none, marked for the DOM walk, and the body/html scroll lock consent libraries
        // set inline released. Never a click: nothing here answers a prompt.
        //
        // AND THE MODAL LOCK ON THE REST OF THE PAGE IS RELEASED. A dialog framework marks everything
        // outside its dialog `inert` while the dialog is open; hiding the dialog's node leaves that mark
        // in place, and an inert subtree swallows every click into <body>. Measured on zara.com/us
        // (llmdex tag jacket-bag-luna2-20260920-132331-177a): the privacy-policy popup was hidden here,
        // `#app-root` stayed inert, and the model clicked "Open size selector" thirteen times -- each
        // click hit <body>, no picker ever opened. With `inert` cleared the same click opened S / M / L.
        // Released on the target's ancestors (they must accept the click), and on the body's direct
        // children only when the hidden root carried a modal dialog -- that is what locked them.
        // `[inert]` elsewhere -- an off-screen carousel slide -- is the site's business.
        // Returns true when a lock was released, so the receipt can say so.
        function ohHide(root, document, el) {
          try { root.setAttribute('data-aloha-hidden-overlay', '1'); } catch (e) {}
          root.style.setProperty('display', 'none', 'important');
          [document.body, document.documentElement].forEach(function (n) {
            try { if (n && n.style && /hidden/i.test(n.style.overflow || '')) n.style.overflow = ''; } catch (e) {}
          });
          var released = false;
          function unlock(n) {
            try {
              if (n && n !== root && n.getAttribute && n.getAttribute('inert') !== null && !root.contains(n)) {
                if (n.removeAttribute) n.removeAttribute('inert'); else n.setAttribute('inert', null);
                released = true;
              }
            } catch (e) {}
          }
          try { for (var a = el; a; a = ohParent(a)) unlock(a); } catch (e) {}
          var modal = ohMatches(root, '[aria-modal="true"], dialog') || ohAll(root, '[aria-modal="true"], dialog').length > 0;
          if (modal) {
            try {
              var kids = (document.body && document.body.children) || [];
              for (var i = 0; i < kids.length; i++) unlock(kids[i]);
            } catch (e) {}
          }
          return released;
        }
        // COVERED TARGET: hide the fixed layer the click would land on instead of the target.
        function hideCoveringOverlay(el, document, window) {
          try { el.scrollIntoView({ block: 'center', inline: 'nearest', behavior: 'instant' }); } catch (e) {}
          var hidden = [];
          var unlocked = false;
          var api = null;
          for (var pass = 0; pass < 3; pass++) {
            var r = el.getBoundingClientRect();
            var top = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
            if (!top || top === el || el.contains(top) || top.contains(el)) break;
            // The covering subtree's ROOT: climb from the hit element until the next parent
            // would also contain the target (i.e. the common ancestor), or the document root.
            var root = top;
            while (root.parentElement && root.parentElement !== document.body
                   && root.parentElement !== document.documentElement
                   && !root.parentElement.contains(el)) {
              root = root.parentElement;
            }
            // An OVERLAY in the layout sense: some node between the hit and the root is
            // fixed/sticky, or the root is a shadow host planted at the body (consent widgets).
            var layered = false, layer = null;
            for (var n = top; n; n = n.parentElement) {
              var pos = ohPosition(n, window);
              if (pos === 'fixed' || pos === 'sticky') { layered = true; layer = n; break; }
              if (n === root) break;
            }
            if (!layered && root.shadowRoot && root.parentElement === document.body) layered = true;
            if (!layered) break;
            // THE ROOT FIRST, THEN THE LAYER ITSELF. The root (the covering subtree's top, a body
            // child) is what a consent widget is best hidden by: banner, backdrop and preference
            // centre go together. But a root can be a static wrapper with a ZERO-HEIGHT box whose
            // only visible child is a full-viewport fixed backdrop: MEASURED on zara.com/ge from a
            // Dutch exit (run jacket-bag-luna-ge47), `#onetrust-consent-sdk` had coverage 0, no
            // visible text, form fields and a landmark inside its hidden preference centre, and
            // its `div.onetrust-pc-dark-filter` (fixed, 100% of the viewport) swallowed ten clicks
            // on the store-choice dialog. Each candidate is judged in turn: a known CMP container
            // goes whatever it holds; otherwise a layer holding text fields is NEVER hidden, whatever
            // its text (a login, a drawer, a checkout); otherwise it is a consent prompt by the same
            // container test as the click-target path, or a blanket -- most of the viewport, no
            // form fields -- and either goes.
            var candidates = [root];
            if (layer && layer !== root) candidates.push(layer);
            var chosen = null, chosenText = '', signal = '';
            for (var c = 0; c < candidates.length && !chosen; c++) {
              var cand = candidates[c];
              var cmp = ohKnownCmp(cand, document);
              if (cmp && !cmp.node.contains(el) && !ohHoldsMain(cmp.node)) { chosen = cmp.node; signal = 'cmp:' + cmp.name; break; }
              if (ohHasLandmark(cand) || ohHasFormFields(cand)) continue;
              if (ohStructural(cand, el, document, window)) {
                if (api === null) api = ohCmpApi(window);
                if (CONSENT_WORDS.test(ohName(cand, document))) { chosen = cand; signal = 'heuristic'; break; }
                if (api.visible === true) { chosen = cand; signal = api.api; break; }
              }
              if (ohCoverage(cand, window) >= 0.6) { chosen = cand; signal = 'blanket'; break; }
            }
            if (!chosen) break;
            chosenText = ohText(chosen);
            var released = false;
            try { released = ohHide(chosen, document, el); } catch (e) { break; }
            hidden.push(ohDescribe(chosen, chosenText) + (signal === 'blanket' ? ' [blanket]' : ' [consent=' + signal + ']'));
            if (released) unlocked = true;
          }
          if (!hidden.length) return '';
          return ' Hid a covering overlay ' + hidden.join(' and ') + ' without answering it, so this click could reach its target. Nothing was accepted or rejected; the layer may reappear on the next page.'
            + (unlocked ? ' The page underneath had been locked (inert) by that layer and is interactive again.' : '');
        }
        // CONSENT CONTROL AS THE TARGET (policy: no new cookies). When the model aims at any control
        // inside a consent prompt -- Accept, Reject, Manage, Close, a toggle, a "learn more" link --
        // the prompt is hidden and nothing is clicked. CLOSE COUNTS AS AN ANSWER: measured 2026-09-21
        // on zara.com, the OneTrust banner's only button read "Close" and clicking it wrote every
        // consent category plus _ga, _fbp, _gcl_au, FPID.
        function hideConsentLayerContaining(el, document, window) {
          var tag = String(el.tagName || '').toLowerCase();
          var role = (el.getAttribute && el.getAttribute('role')) || '';
          var isControl = tag === 'button' || tag === 'a' || tag === 'input'
            || role === 'button' || role === 'link' || role === 'switch' || role === 'checkbox';
          if (!isControl) return '';
          var api = ohCmpApi(window);
          var hit = ohDetectConsent(el, document, window, api);
          if (!hit) return '';
          var label = ohText(el);
          if (!label && el.getAttribute) {
            label = el.getAttribute('aria-label') || el.getAttribute('value') || el.getAttribute('title') || '';
          }
          var root = hit.node;
          var t = ohText(root);
          try { ohHide(root, document, el); } catch (e) { return ''; }
          var what = CONSENT_ACTION.test(label) ? 'is a control of a cookie/consent prompt' : 'is a control inside a cookie/consent prompt';
          return 'NOT CLICKED. "' + (label.length > 40 ? label.slice(0, 40) : label) + '" ' + what + ', and this agent answers none of them (policy: no new cookies). The prompt ' + ohDescribe(root, t) + ' was hidden instead [consent=' + hit.signal + ']; nothing was accepted or rejected. The page beneath is usable -- continue with the task.';
        }
        // END overlay-hider js
        """
}
