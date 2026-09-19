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
    /// GENERAL BY CONSTRUCTION, not by vendor list. The cover is found by hit-testing the target
    /// and climbing to the covering subtree's root, so it works on any site's markup. It is hidden
    /// only when it is an OVERLAY in the layout sense -- a `position:fixed`/`sticky` layer, or a
    /// shadow-DOM host planted at the document root the way consent widgets are -- AND it either
    /// reads like a consent notice (cookie/privacy/accept vocabulary in the common European
    /// languages) or blankets at least 60% of the viewport while holding no form fields. That
    /// last clause keeps a modal the model itself opened, a size drawer or a login form, from
    /// being swept away because a stray click landed under it. A small absolute dropdown, a
    /// sticky header the target scrolled beneath, or an inline overlap is never touched.
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

    /// POLICY: NO NEW COOKIES. When the click's TARGET is a control of a consent prompt -- Accept,
    /// Reject, Manage, inside a fixed layer whose text reads like a cookie notice -- the prompt is
    /// hidden and nothing is clicked. The agent answers no consent prompt on the user's behalf,
    /// in either direction, so the site records nothing beyond what it set on load. Measured
    /// before this existed: in two of three ATP runs the model reached for "Accept All Cookies"
    /// as its way past the banner, and two OneTrust consent cookies were written each time.
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

    /// The page-side logic behind `hideCoveringOverlay(alohaId:)` and
    /// `hideConsentLayerContaining(alohaId:)`: shared helpers plus the two functions, as STATEMENTS
    /// the wrappers evaluate before calling one of them. `Tests/AgentRuntimeTests/overlay_hider.js`
    /// runs the identical source against a fake DOM in Node, extracting it by the two markers.
    static let overlayHiderSource = """
        // BEGIN overlay-hider js
        // A consent prompt names its TOPIC (cookies, consent, tracking, GDPR) AND offers an ACTION
        // (accept, reject, manage, preferences); the review's counter-example -- a fixed settings
        // modal reading "privacy preferences" -- has the action word and no topic, and must not
        // be treated as one. Seven languages on both sides; "privacy" alone qualifies for neither.
        var CONSENT_TOPIC = /cookie|cookies|consent|gdpr|tracking|we value your privacy|datenschutz|einwilligung|confidentialit|privacidad|\\u043a\\u0443\\u043a\\u0438|\\u0441\\u043e\\u0433\\u043b\\u0430\\u0441/i;
        var CONSENT_ACTION = /accept|agree|allow|reject|decline|deny|manage|preferences|settings|zustimmen|akzeptieren|ablehnen|accepter|refuser|aceptar|rechazar|accetta|rifiuta|aceitar|recusar|\\u043f\\u0440\\u0438\\u043d\\u044f\\u0442\\u044c|\\u043e\\u0442\\u043a\\u043b\\u043e\\u043d/i;
        function ohIsConsent(t) { return CONSENT_TOPIC.test(t) && CONSENT_ACTION.test(t); }
        function ohText(n) {
          var t = '';
          try { t = n.innerText || n.textContent || ''; } catch (e) {}
          if (!t && n.shadowRoot) { try { t = n.shadowRoot.textContent || ''; } catch (e) {} }
          return String(t).replace(/\\s+/g, ' ').trim();
        }
        function ohPosition(n, window) {
          try { return window.getComputedStyle(n).position || ''; } catch (e) { return ''; }
        }
        function ohHasFormFields(n) {
          try { return !!n.querySelector('input:not([type=hidden]), select, textarea'); } catch (e) { return false; }
        }
        function ohDescribe(n, t) {
          var id = n.getAttribute && n.getAttribute('aloha-id');
          var d = '<' + String(n.tagName || 'element').toLowerCase() + (id ? ' aloha-id="' + id + '"' : '') + '>';
          if (t) d += ' "' + (t.length > 60 ? t.slice(0, 60) : t) + '"';
          return d;
        }
        // display:none, marked for the DOM walk, and the body/html scroll lock consent libraries
        // set inline released. Never a click: nothing here answers a prompt.
        function ohHide(root, document) {
          try { root.setAttribute('data-aloha-hidden-overlay', '1'); } catch (e) {}
          root.style.setProperty('display', 'none', 'important');
          [document.body, document.documentElement].forEach(function (n) {
            try { if (n && n.style && /hidden/i.test(n.style.overflow || '')) n.style.overflow = ''; } catch (e) {}
          });
        }
        // COVERED TARGET: hide the fixed layer the click would land on instead of the target.
        function hideCoveringOverlay(el, document, window) {
          try { el.scrollIntoView({ block: 'center', inline: 'nearest' }); } catch (e) {}
          var hidden = [];
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
            var layered = false;
            for (var n = top; n; n = n.parentElement) {
              var pos = ohPosition(n, window);
              if (pos === 'fixed' || pos === 'sticky') { layered = true; break; }
              if (n === root) break;
            }
            if (!layered && root.shadowRoot && root.parentElement === document.body) layered = true;
            if (!layered) break;
            var t = ohText(root);
            var rr = root.getBoundingClientRect();
            var vw = Math.max(1, window.innerWidth || 1), vh = Math.max(1, window.innerHeight || 1);
            var coverage = (Math.max(0, rr.width) * Math.max(0, rr.height)) / (vw * vh);
            var consent = ohIsConsent(t);
            var blanket = coverage >= 0.6 && !ohHasFormFields(root);
            if (!consent && !blanket) break;
            try { ohHide(root, document); } catch (e) { break; }
            hidden.push(ohDescribe(root, t));
          }
          if (!hidden.length) return '';
          return ' Hid a covering overlay ' + hidden.join(' and ') + ' without answering it, so this click could reach its target. Nothing was accepted or rejected; the layer may reappear on the next page.';
        }
        // CONSENT CONTROL AS THE TARGET (policy: no new cookies). When the model aims at Accept,
        // Reject or Manage inside a consent prompt, the prompt is hidden and nothing is clicked.
        // The layer root is the HIGHEST ancestor that is itself fixed/sticky, or a direct child of
        // the body whose text is short -- a consent widget's root is a few hundred characters,
        // an app's root div is the whole page, and hiding the latter would take the site down.
        function hideConsentLayerContaining(el, document, window) {
          var tag = String(el.tagName || '').toLowerCase();
          var role = (el.getAttribute && el.getAttribute('role')) || '';
          var isControl = tag === 'button' || tag === 'a' || tag === 'input' || role === 'button' || role === 'link';
          if (!isControl) return '';
          var layered = false, root = null;
          for (var n = el.parentElement; n && n !== document.body && n !== document.documentElement; n = n.parentElement) {
            var pos = ohPosition(n, window);
            if (pos === 'fixed' || pos === 'sticky') { layered = true; root = n; continue; }
            if (n.shadowRoot && n.parentElement === document.body) { layered = true; root = n; continue; }
            if (layered && (n.parentElement === document.body || n.parentElement === document.documentElement)
                && ohText(n).length <= 2000) { root = n; }
          }
          if (!layered || !root) return '';
          var t = ohText(root);
          if (!ohIsConsent(t)) return '';
          var label = ohText(el);
          try { ohHide(root, document); } catch (e) { return ''; }
          return 'NOT CLICKED. "' + (label.length > 40 ? label.slice(0, 40) : label) + '" is a control of a cookie/consent prompt, and this agent answers none of them (policy: no new cookies). The prompt ' + ohDescribe(root, t) + ' was hidden instead; nothing was accepted or rejected. The page beneath is usable -- continue with the task.';
        }
        // END overlay-hider js
        """
}
