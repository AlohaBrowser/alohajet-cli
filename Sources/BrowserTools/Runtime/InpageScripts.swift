import Foundation

/// Builds the page-side DOM-stability script: a debounced `MutationObserver` on
/// the main content node (`#app, #root, main, [role="main"]`, falling back to
/// `document.body`) that resolves once the DOM stops mutating for `stableTimeMs`,
/// with a 10s safety cap. Childlist/subtree mutations are observed; attribute
/// changes are ignored because they are usually animation/style churn. The
/// resolved promise is the DOM-stable signal feeding the page-readiness waiter. // @allow
public func buildDomStabilityScript(stableTimeMs: Int) -> String {
    """
    new Promise(function(resolve) {
      var debounceTimer;
      var stableTime = \(stableTimeMs);
      var observer = new MutationObserver(function() {
        clearTimeout(debounceTimer);
        debounceTimer = setTimeout(function() {
          observer.disconnect();
          resolve();
        }, stableTime);
      });
      var target = document.querySelector('#app, #root, main, [role="main"]') || document.body;
      if (target) {
        observer.observe(target, { childList: true, subtree: true, attributes: false });
      }
      debounceTimer = setTimeout(function() {
        observer.disconnect();
        resolve();
      }, stableTime);
      setTimeout(function() {
        observer.disconnect();
        resolve();
      }, 10000);
    })
    """
}

/// Builds the page-side runtime exposed as `window.__aloha`: element resolution
/// (piercing shadow DOM + same-origin iframes), viewport coordinate helpers,
/// editor detection, wait helpers, and the click/type/select/scroll/hover/query
/// API used by agent code. CDP-dependent operations enqueue pending requests for
/// the bridge to drain after execution.
public func buildInpageAlohaRuntime() -> String {
    #"""
    (function() {
      'use strict';
      if (window.__aloha) return;

      // Pending CDP requests — read by the page bridge after execution
      window.__alohaPending = [];

      \#(sensitiveFieldPredicateJS)

      // ── Element Resolution (pierces shadow DOM + same-origin iframes) ──────

      function findInShadowRoots(root, selector) {
        var all = root.querySelectorAll('*');
        for (var i = 0; i < all.length; i++) {
          var el = all[i];
          if (el.shadowRoot) {
            var found = el.shadowRoot.querySelector(selector);
            if (found) return { element: found, iframeChain: [] };
            var nested = findInShadowRoots(el.shadowRoot, selector);
            if (nested) return nested;
          }
        }
        return null;
      }

      function findInIframes(doc, selector, chain) {
        var iframes = doc.querySelectorAll('iframe');
        for (var i = 0; i < iframes.length; i++) {
          var iframe = iframes[i];
          try {
            var iframeDoc = iframe.contentDocument;
            if (!iframeDoc) continue;

            var direct = iframeDoc.querySelector(selector);
            if (direct) return { element: direct, iframeChain: chain.concat(iframe) };

            var fromShadow = findInShadowRoots(iframeDoc, selector);
            if (fromShadow) return { element: fromShadow.element, iframeChain: chain.concat(iframe) };

            var nested = findInIframes(iframeDoc, selector, chain.concat(iframe));
            if (nested) return nested;
          } catch (e) {
            // cross-origin iframe — skip
          }
        }
        return null;
      }

      function resolveElement(alohaId) {
        var selector = '[aloha-id="' + String(alohaId).replace(/"/g, '\\"') + '"]';

        var direct = document.querySelector(selector);
        if (direct) return { element: direct, iframeChain: [] };

        var fromShadow = findInShadowRoots(document, selector);
        if (fromShadow) return fromShadow;

        return findInIframes(document, selector, []);
      }

      function requireElement(alohaId) {
        var result = resolveElement(alohaId);
        if (!result) {
          var dotIdx = String(alohaId).lastIndexOf('.');
          if (dotIdx > 0) {
            var basePart = alohaId.substring(0, dotIdx);
            var baseResult = resolveElement(basePart);
            if (baseResult && baseResult.element.tagName === 'SELECT') {
              throw new Error('aloha-id "' + alohaId + '" is a select option index. Use aloha.select("' + basePart + '", ' + alohaId.substring(dotIdx + 1) + ') instead.');
            }
          }
          throw new Error('Element with aloha-id ' + alohaId + ' not found');
        }
        return result;
      }

      // ── Viewport coordinate helpers ────────────────────────────────────────

      function getViewportCoords(resolved) {
        var rect = resolved.element.getBoundingClientRect();
        var x = rect.left + rect.width / 2;
        var y = rect.top + rect.height / 2;

        for (var i = resolved.iframeChain.length - 1; i >= 0; i--) {
          var iframeRect = resolved.iframeChain[i].getBoundingClientRect();
          x += iframeRect.left;
          y += iframeRect.top;
        }

        return {
          x: x, y: y,
          width: rect.width, height: rect.height,
          top: rect.top, left: rect.left,
          bottom: rect.bottom, right: rect.right
        };
      }

      // ── Editor detection ───────────────────────────────────────────────────

      function detectEditorType(el) {
        if (!el) return 'standard';

        var node = el;
        for (var i = 0; i < 10 && node; i++) {
          if (node.classList) {
            if (node.classList.contains('ProseMirror')) return 'prosemirror';
            if (node.getAttribute && node.getAttribute('data-slate-editor') === 'true') return 'slate';
            if (node.classList.contains('ql-editor')) return 'quill';
            if (node.classList.contains('CodeMirror') || node.classList.contains('cm-editor'))
              return 'codemirror';
          }
          node = node.parentElement;
        }

        if (el.isContentEditable || (el.getAttribute && el.getAttribute('contenteditable') === 'true')) {
          return 'contenteditable';
        }

        return 'standard';
      }

      // ── Wait helpers ───────────────────────────────────────────────────────

      function waitForSelector(selector, timeoutMs) {
        timeoutMs = timeoutMs || 10000;
        return new Promise(function(resolve, reject) {
          var el = document.querySelector(selector);
          if (el) { resolve(el); return; }

          var timer = null;
          var observer = new MutationObserver(function() {
            var found = document.querySelector(selector);
            if (found) {
              observer.disconnect();
              if (timer) clearTimeout(timer);
              resolve(found);
            }
          });

          observer.observe(document.documentElement, { childList: true, subtree: true });

          timer = setTimeout(function() {
            observer.disconnect();
            reject(new Error('waitFor timeout: "' + selector + '" not found within ' + timeoutMs + 'ms'));
          }, timeoutMs);
        });
      }

      // ── Pending CDP request helper ─────────────────────────────────────────

      function enqueueCdp(type, params) {
        if (typeof window.__alohaEnqueueCdp !== 'function') return;
        window.__alohaEnqueueCdp(type, params);
      }

      // ── Runtime API ────────────────────────────────────────────────────────

      window.__aloha = {

        click: function(alohaIdOrX, maybeYOrOpts, maybeOpts) {
          if (typeof alohaIdOrX === 'number' && typeof maybeYOrOpts === 'number') {
            var coordParams = { x: alohaIdOrX, y: maybeYOrOpts };
            if (maybeOpts && typeof maybeOpts === 'object' && maybeOpts.files && maybeOpts.files.length) {
              coordParams.files = maybeOpts.files;
            }
            enqueueCdp('click', coordParams);
            return { success: true, pending: true, coords: { x: alohaIdOrX, y: maybeYOrOpts } };
          }

          var alohaId = alohaIdOrX;
          var opts = (typeof maybeYOrOpts === 'object' && maybeYOrOpts !== null) ? maybeYOrOpts : {};

          var dotIdx = String(alohaId).lastIndexOf('.');
          if (dotIdx > 0) {
            var selectPart = alohaId.substring(0, dotIdx);
            var optionIdx = parseInt(alohaId.substring(dotIdx + 1), 10);
            if (!isNaN(optionIdx)) {
              var selectResolved = resolveElement(selectPart);
              if (selectResolved && selectResolved.element.tagName === 'SELECT') {
                return window.__aloha.select(selectPart, { index: optionIdx });
              }
            }
          }

          var resolved = requireElement(alohaId);
          var el = resolved.element;
          el.scrollIntoView({ block: 'center', behavior: 'instant' });

          if (el.isContentEditable || (el.getAttribute && el.getAttribute('contenteditable') === 'true')) {
            el.focus();
          }

          var coords = getViewportCoords(resolved);
          var params = { x: coords.x, y: coords.y, alohaId: alohaId };
          if (opts.files && opts.files.length) {
            params.files = opts.files;
          }
          enqueueCdp('click', params);
          return { success: true, pending: true, coords: coords };
        },

        type: function(alohaId, text, opts) {
          opts = opts || {};
          var resolved = requireElement(alohaId);
          var el = resolved.element;

          // Refuse an element the keystrokes would never reach, the same way `select`
          // below refuses a non-<select>: check both the element's KIND and whether the
          // focus actually took — a hidden or readonly input is the right kind and still
          // swallows everything.
          var tag = el.tagName;
          var inputType = (el.getAttribute('type') || 'text').toLowerCase();
          var nonText = ['button','submit','reset','checkbox','radio','file','image','range','color','hidden'];
          var describe = '<' + tag.toLowerCase() + (tag === 'INPUT' ? ' type=' + inputType : '') + '>';
          var accepts = (tag === 'TEXTAREA'
              || (tag === 'INPUT' && nonText.indexOf(inputType) === -1)
              || el.isContentEditable === true)
            && el.disabled !== true && el.readOnly !== true;
          if (!accepts) {
            throw new Error('Element ' + alohaId + ' cannot accept typed text (got '
              + describe + ') — pass the aloha-id of the text field itself');
          }

          el.scrollIntoView({ block: 'center', behavior: 'instant' });
          el.focus();

          var active = document.activeElement;
          while (active && active.shadowRoot && active.shadowRoot.activeElement) {
            active = active.shadowRoot.activeElement;
          }
          if (active !== el) {
            throw new Error('Element ' + alohaId + ' (' + describe + ') could not take keyboard '
              + 'focus — it is hidden, detached or focus was moved away, so nothing would be '
              + 'typed into it. Pass the aloha-id of the VISIBLE field');
          }

          enqueueCdp('type', { alohaId: alohaId, text: text, replace: !!opts.replace });
          return { success: true, pending: true };
        },

        select: function(alohaId, valueOrOpts) {
          var resolved = requireElement(alohaId);
          var el = resolved.element;
          el.scrollIntoView({ block: 'center', behavior: 'instant' });

          if (el.tagName !== 'SELECT') {
            throw new Error('Element ' + alohaId + ' is not a <select> (got ' + el.tagName + ')');
          }

          var options = Array.from(el.options);
          var targetOption = null;
          var isToggle = false;

          if (typeof valueOrOpts === 'number') {
            targetOption = options[valueOrOpts];
            if (!targetOption) throw new Error('Option index ' + valueOrOpts + ' out of range (0-' + (options.length - 1) + ')');
          } else if (typeof valueOrOpts === 'object' && valueOrOpts !== null) {
            if (valueOrOpts.toggle) isToggle = true;
            if (typeof valueOrOpts.index === 'number') {
              targetOption = options[valueOrOpts.index];
              if (!targetOption) throw new Error('Option index ' + valueOrOpts.index + ' out of range (0-' + (options.length - 1) + ')');
            } else if (typeof valueOrOpts.label === 'string') {
              targetOption = options.find(function(o) { return o.text.trim() === valueOrOpts.label.trim(); });
              if (!targetOption) throw new Error('No option with label "' + valueOrOpts.label + '"');
            } else if (typeof valueOrOpts.value === 'string') {
              targetOption = options.find(function(o) { return o.value === valueOrOpts.value; });
              if (!targetOption) throw new Error('No option with value "' + valueOrOpts.value + '"');
            }
          } else if (typeof valueOrOpts === 'string') {
            targetOption = options.find(function(o) { return o.text.trim() === valueOrOpts.trim(); });
            if (!targetOption) targetOption = options.find(function(o) { return o.value === valueOrOpts; });
            if (!targetOption) throw new Error('No option matching "' + valueOrOpts + '"');
          }

          if (!targetOption) throw new Error('No valid selector provided for select');

          if (el.multiple && isToggle) {
            targetOption.selected = !targetOption.selected;
          } else if (el.multiple) {
            targetOption.selected = true;
          } else {
            el.value = targetOption.value;
          }

          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
          return { success: true, selected: { value: targetOption.value, label: targetOption.text } };
        },

        scrollTo: function(alohaId) {
          var resolved = requireElement(alohaId);
          var el = resolved.element;
          el.scrollIntoView({ block: 'center', behavior: 'smooth' });
          enqueueCdp('scrollTo', { alohaId: alohaId });
          var coords = getViewportCoords(resolved);
          return { success: true, pending: true, coords: coords };
        },

        focus: function(alohaId) {
          var resolved = requireElement(alohaId);
          resolved.element.focus();
          return { success: true };
        },

        hover: function(alohaId) {
          var resolved = requireElement(alohaId);
          var el = resolved.element;
          el.scrollIntoView({ block: 'center', behavior: 'instant' });

          var coords = getViewportCoords(resolved);
          el.dispatchEvent(new PointerEvent('pointerenter', { bubbles: false, cancelable: false, clientX: coords.x, clientY: coords.y }));
          el.dispatchEvent(new PointerEvent('pointerover', { bubbles: true, cancelable: true, clientX: coords.x, clientY: coords.y }));
          el.dispatchEvent(new MouseEvent('mouseenter', { bubbles: false, cancelable: false, clientX: coords.x, clientY: coords.y }));
          el.dispatchEvent(new MouseEvent('mouseover', { bubbles: true, cancelable: true, clientX: coords.x, clientY: coords.y }));

          enqueueCdp('hover', { x: coords.x, y: coords.y, alohaId: alohaId });
          return { success: true, pending: true, coords: coords };
        },

        getText: function(alohaId) {
          var resolved = requireElement(alohaId);
          var el = resolved.element;
          if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') {
            if (__alohaIsSensitiveField(el)) return \#(sensitiveFieldMaskJS);
            return el.value || '';
          }
          return el.textContent || '';
        },

        getAttribute: function(alohaId, attr) {
          var resolved = requireElement(alohaId);
          return resolved.element.getAttribute(attr);
        },

        isVisible: function(alohaId) {
          var result = resolveElement(alohaId);
          if (!result) return false;
          var el = result.element;
          var rect = el.getBoundingClientRect();
          if (rect.width === 0 && rect.height === 0) return false;
          var style = getComputedStyle(el);
          return style.display !== 'none' && style.visibility !== 'hidden' && style.opacity !== '0';
        },

        query: function(selector) {
          var elements = document.querySelectorAll(selector);
          var ids = [];
          for (var i = 0; i < elements.length; i++) {
            var id = elements[i].getAttribute('aloha-id');
            if (id) ids.push(id);
          }
          return ids;
        },

        queryAll: function(selector, opts) {
          var limit = (opts && opts.limit) || 50;
          var elements = document.querySelectorAll(selector);
          var results = [];
          for (var i = 0; i < Math.min(elements.length, limit); i++) {
            var el = elements[i];
            results.push({
              alohaId: el.getAttribute('aloha-id') || null,
              tagName: el.tagName,
              text: (el.textContent || '').trim().substring(0, 200),
              href: el.href || null,
              className: el.className || null
            });
          }
          return { count: elements.length, items: results };
        },

        findByText: function(text, opts) {
          var exact = opts && opts.exact;
          var limit = (opts && opts.limit) || 10;

          var normalizedQuery = text.replace(/\s+/g, ' ').trim();
          var lowerQuery = normalizedQuery.toLowerCase();

          var all = document.querySelectorAll('[aloha-id]');
          var candidates = [];

          for (var i = 0; i < all.length; i++) {
            var el = all[i];
            var raw = (el.textContent || '').replace(/\s+/g, ' ').trim();
            if (!raw) continue;

            var matched = exact
              ? raw === normalizedQuery
              : raw.toLowerCase().indexOf(lowerQuery) !== -1;

            if (matched) {
              candidates.push({ element: el, textLength: raw.length, raw: raw });
            }
          }

          candidates.sort(function(a, b) { return a.textLength - b.textLength; });

          var seen = new Set();
          var results = [];
          for (var j = 0; j < candidates.length && results.length < limit; j++) {
            var cand = candidates[j];
            var dominated = false;
            var parent = cand.element.parentElement;
            while (parent) {
              if (seen.has(parent)) { dominated = true; break; }
              parent = parent.parentElement;
            }
            if (dominated) continue;
            seen.add(cand.element);

            var alohaId = cand.element.getAttribute('aloha-id');
            var resolved = resolveElement(alohaId);
            var coords = resolved ? getViewportCoords(resolved) : null;

            results.push({
              alohaId: alohaId,
              tagName: cand.element.tagName,
              text: cand.raw.substring(0, 200),
              bounds: coords,
              isVisible: window.__aloha.isVisible(alohaId)
            });
          }

          return results;
        },

        waitFor: function(selector, timeoutMs) {
          return waitForSelector(selector, timeoutMs).then(function() {
            return { success: true };
          });
        },

        wait: function(seconds) {
          var ms = (seconds || 1);
          if (ms >= 100) ms = ms / 1000;
          ms = Math.min(ms, 30);
          return new Promise(function(resolve) {
            setTimeout(function() { resolve({ success: true }); }, ms * 1000);
          });
        },

        url: function() {
          return window.location.href;
        },

        getViewportCoords: function(alohaId) {
          var resolved = requireElement(alohaId);
          return getViewportCoords(resolved);
        },

        detectEditor: function(alohaId) {
          var resolved = requireElement(alohaId);
          return detectEditorType(resolved.element);
        },

        resolve: function(alohaId) {
          var result = resolveElement(alohaId);
          if (!result) return null;
          var coords = getViewportCoords(result);
          return {
            found: true,
            tagName: result.element.tagName,
            isVisible: window.__aloha.isVisible(alohaId),
            coords: coords,
            editorType: detectEditorType(result.element),
            iframeDepth: result.iframeChain.length
          };
        },

        doubleClick: function(alohaId) {
          var resolved = requireElement(alohaId);
          var el = resolved.element;
          el.scrollIntoView({ block: 'center', behavior: 'instant' });
          var coords = getViewportCoords(resolved);

          enqueueCdp('doubleClick', { x: coords.x, y: coords.y, alohaId: alohaId });
          return { success: true, pending: true, coords: coords };
        },

        tripleClick: function(alohaId) {
          var resolved = requireElement(alohaId);
          var el = resolved.element;
          el.scrollIntoView({ block: 'center', behavior: 'instant' });
          var coords = getViewportCoords(resolved);

          enqueueCdp('tripleClick', { x: coords.x, y: coords.y, alohaId: alohaId });
          return { success: true, pending: true, coords: coords };
        },

        rightClick: function(alohaId) {
          var resolved = requireElement(alohaId);
          var el = resolved.element;
          el.scrollIntoView({ block: 'center', behavior: 'instant' });
          var coords = getViewportCoords(resolved);

          enqueueCdp('rightClick', { x: coords.x, y: coords.y, alohaId: alohaId });
          return { success: true, pending: true, coords: coords };
        },

        pressKeys: function(keys) {
          enqueueCdp('pressKeys', { keys: keys });
          return { success: true, pending: true };
        },

        typeText: function(text) {
          enqueueCdp('typeText', { text: String(text) });
          return { success: true, pending: true };
        },

        goto: function(url) {
          enqueueCdp('goto', { url: url });
          return { success: true, pending: true };
        },

        back: function() {
          enqueueCdp('back', {});
          return { success: true, pending: true };
        },

        screenshot: function(opts) {
          var vw = window.innerWidth || document.documentElement.clientWidth || 0;
          var vh = window.innerHeight || document.documentElement.clientHeight || 0;
          var params = { viewport: { width: vw, height: vh } };
          if (opts && typeof opts.saveTo === 'string' && opts.saveTo.length > 0) {
            params.saveTo = opts.saveTo;
          }
          enqueueCdp('screenshot', params);
          return { success: true, pending: true };
        },

        drag: function(fromAlohaId, toAlohaId, opts) {
          var fromResolved = requireElement(fromAlohaId);
          fromResolved.element.scrollIntoView({ block: 'center', behavior: 'instant' });
          var fromCoords = getViewportCoords(fromResolved);

          var toResolved = requireElement(toAlohaId);
          var toCoords = getViewportCoords(toResolved);

          enqueueCdp('drag', {
            fromX: fromCoords.x, fromY: fromCoords.y,
            toX: toCoords.x, toY: toCoords.y,
            steps: (opts && opts.steps) || 10,
            duration: (opts && opts.duration) || 300
          });
          return { success: true, pending: true, fromCoords: fromCoords, toCoords: toCoords };
        },

        moveMouse: function(alohaId) {
          var resolved = requireElement(alohaId);
          resolved.element.scrollIntoView({ block: 'center', behavior: 'instant' });
          var coords = getViewportCoords(resolved);

          enqueueCdp('moveMouse', { x: coords.x, y: coords.y, alohaId: alohaId });
          return { success: true, pending: true, coords: coords };
        }
      };
    })()
    """#
}

/// Builds the wrapper script that runs agent-authored source in the page,
/// swapping in a private pending-CDP queue, compiling the source first as an
/// expression body then as a statement body, and returning
/// `{ result, error, pending }`.
///
/// `compile` decides HOW the source reaches the page, and on a site with a strict Content Security
/// Policy that decision is the difference between working and not working at all.
///
/// MEASURED 2026-08-06. Every WebArena reddit row that failed with
/// `Refused to evaluate a string as JavaScript because 'unsafe-eval' ... is not an allowed source of
/// script` died HERE, at `new Function(...)` — 19 rows across four runs, 14 of them failures, and
/// **every single one on reddit**, whose Postmill instance ships `script-src 'self' 'unsafe-inline'`
/// with no `unsafe-eval`. The outer script itself runs fine (CDP evaluation is not what the policy
/// blocks); what the policy refuses is the page compiling a string at runtime.
///
/// The tools that lost those rows do not need dynamic compilation at all: `page_click`, `page_type`,
/// `page_select` and `page_press_keys` send a FIXED call that Swift built (`aloha.click("2s")`), never
/// model-authored code. `.inline` puts that call straight in the script body, so nothing is compiled
/// from a string and the CSP has nothing to refuse.
///
/// `.dynamic` stays for callers that really do run arbitrary model-authored source — and it will
/// still fail on a page like reddit's. That is a genuine limit, not an oversight: the alternative is a
/// CDP isolated world, which is a much larger change to how `window.__aloha` is installed.
public enum AgentCodeCompilation {
    /// Compile the source at runtime with `new Function` — required for arbitrary model-authored code,
    /// and refused by any page whose CSP omits `unsafe-eval`.
    case dynamic
    /// Inline the source directly as an expression. For Swift-constructed fixed calls only.
    case inline
}

public func buildAgentCodeRunnerScript(_ source: String,
                                       compile: AgentCodeCompilation = .dynamic) -> String {
    let encodedSource = jsonStringLiteral(source)
    // ONE BLOCK OR THE OTHER, NEVER BOTH — the inline script must not even CONTAIN `new Function`.
    // Keeping the dynamic branch as dead code would still ship the construct into the page, where a
    // policy-analysis tool (or the next reader) cannot tell live code from dead, and a test asserting
    // "this script cannot ask the page to compile a string" could not be written honestly.
    let executionBlock = switch compile {
    case .inline:
        """
                // The call is INLINE, built in Swift from typed parameters. Nothing is compiled from a
                // string, so a page whose CSP omits 'unsafe-eval' has nothing to refuse.
                __rawResult = await (async () => (
        \(source)
                ))();
        """
    case .dynamic:
        """
                var __agentFn;
                try {
                  __agentFn = new Function('aloha', '__aloha', 'return (async () => (\\n' + __agentSrc + '\\n))()');
                } catch (_exprErr) {
                  __agentFn = new Function('aloha', '__aloha', 'return (async () => {\\n' + __agentSrc + '\\n})()');
                }
                __rawResult = await __agentFn(aloha, __aloha);
        """
    }
    return #"""
    (async function() {
      var __runPending = [];
      var __runClosed = false;
      var __priorPending = window.__alohaPending;
      var __priorEnqueueCdp = window.__alohaEnqueueCdp;
      window.__alohaPending = __runPending;
      function __runEnqueueCdp(type, params) {
        if (__runClosed) return;
        __runPending.push({ type: type, params: params });
      }
      window.__alohaEnqueueCdp = __runEnqueueCdp;
      var __aloha = window.__aloha || null;
      if (__aloha) __aloha.tab = __aloha;
      var aloha = __aloha;

      var __execError = null;
      var __rawResult = undefined;
      try {
        var __agentSrc =
    """# + encodedSource + #"""
    ;
    """# + executionBlock + #"""
      } catch (e) {
        __execError = { message: e && e.message ? e.message : String(e), stack: e && e.stack ? e.stack : null, name: e && e.name ? e.name : 'Error' };
      } finally {
        __runClosed = true;
        if (window.__alohaEnqueueCdp === __runEnqueueCdp) {
          if (__priorEnqueueCdp) window.__alohaEnqueueCdp = __priorEnqueueCdp;
          else delete window.__alohaEnqueueCdp;
        }
        if (window.__alohaPending === __runPending) {
          if (__priorPending) window.__alohaPending = __priorPending;
          else window.__alohaPending = [];
        }
      }

      return { result: __rawResult, error: __execError, pending: __runPending };
    })()
    """#
}

/// Encodes a string as a JSON string literal for safe embedding in generated
/// script source.
func jsonStringLiteral(_ value: String) -> String {
    guard let data = try? JSONEncoder().encode(value),
          let encoded = String(data: data, encoding: .utf8) else { return "\"\"" }
    return encoded
}
