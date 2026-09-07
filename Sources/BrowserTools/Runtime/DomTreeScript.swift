import Foundation

/// Produces the page-side document walker injected via the tab layer. It walks
/// the live document, decides which nodes are interactive / visible / topmost,
/// assigns each kept node a stable hashed `aloha-id` (also written back onto the
/// element as an attribute so it can be relocated by `[aloha-id="..."]`), and
/// returns a flat `metadata` array grouped into element / positioning /
/// interactivity / content. The returned id is derived in one place
/// (`alohaIdFor`) by hashing either an authored name (`#id`, `[data-testid]`) or
/// the node's frame-scoped xpath, so it stays stable across walks of the same page.
///
/// `focusInteractive` maps to the in-page `collectAllInteractive` flag: when
/// `true` every interactive node is kept/highlighted; when `false` only
/// interactive nodes lacking their own comprehensive text are highlighted.
/// `highlight` is accepted for call-site symmetry; the overlay it controls is
/// torn down separately by the caller.
nonisolated public func buildAgentDomTreeScript(highlight: Bool, focusInteractive: Bool) -> String {
    let collectAllInteractive = focusInteractive
    let debug = false
    _ = highlight
    return #"""
(() => {
    const DEBUG = \#(debug);
    \#(sensitiveFieldPredicateJS)
    const buildDomTree = (collectAllInteractive = true, debug = false) => {
  const DEBUG = debug;

  const SEMANTIC_STRUCTURE_TAGS = new Set(["header", "footer", "aside", "main", "article", "fieldset", "section", "nav"]);

  const comprehensiveTextCache = new WeakMap();
  const descendantTextCache = new WeakMap();
  const interactiveCache = new WeakMap();
  const caches = {
    boundingRects: new WeakMap(),
    computedStyles: new WeakMap(),
    scrollProperties: new WeakMap(),
    elementVisibility: new WeakMap(),
    elementData: new WeakMap(),
    clearCache: () => {
      caches.boundingRects = new WeakMap();
      caches.computedStyles = new WeakMap();
      caches.scrollProperties = new WeakMap();
      caches.elementVisibility = new WeakMap();
      caches.elementData = new WeakMap();
    }
  };

  const INTERACTIVE_TAGS = new Set(["a", "button", "input", "select", "textarea", "details", "summary", "label", "option", "optgroup", "fieldset", "legend"]);
  const INTERACTIVE_CURSORS = new Set(["pointer", "move", "text", "grab", "grabbing", "cell", "copy", "alias", "all-scroll", "col-resize", "context-menu", "crosshair", "e-resize", "ew-resize", "help", "n-resize", "ne-resize", "nesw-resize", "ns-resize", "nw-resize", "nwse-resize", "row-resize", "s-resize", "se-resize", "sw-resize", "vertical-text", "w-resize", "zoom-in", "zoom-out"]);
  const DISABLED_CURSORS = new Set(["not-allowed", "no-drop", "wait", "progress"]);
  const HIGHLIGHT_LABEL_TAGS = new Set(["a", "button", "input", "select", "textarea", "textarea-shape", "details", "summary"]);
  const LEAF_NODE_TAGS = new Set(["a", "button", "input", "select", "textarea", "summary", "details", "label", "option"]);
  const INTERACTIVE_ROLES = new Set(["button", "link", "menuitem", "menuitemradio", "menuitemcheckbox", "radio", "checkbox", "tab", "switch", "slider", "spinbutton", "combobox", "searchbox", "textbox", "listbox", "option", "scrollbar"]);
  const DISABLED_ATTRIBUTES = new Set(["disabled", "readonly", "aria-disabled", "aria-readonly", "hidden", "inert"]);
  const ALWAYS_ACCEPTED_TAGS = new Set(["body", "div", "main", "article", "section", "nav", "header", "footer"]);
  const NEVER_ACCEPTED_TAGS = new Set(["script", "style", "link", "meta", "noscript", "template"]);
  const TEXT_CONTAINER_TAGS = new Set(["a", "button", "label", "option", "li", "p", "summary", "dt", "dd", "th", "td", "h1", "h2", "h3", "h4", "h5", "h6"]);
  const EVENT_HANDLER_ATTRS = ["onclick", "onmousedown", "onmouseup", "ondblclick", "oncontextmenu", "onmouseenter", "onmouseleave", "onmouseover", "onmouseout", "onkeydown", "onkeyup", "onchange", "oninput", "onfocus", "onblur", "onpointerdown", "onpointerup", "onpointermove", "onpointerenter", "onpointerleave", "onpointerover", "onpointerout", "onpointercancel", "ontouchstart", "ontouchend", "ontouchmove", "ontouchcancel"];
  const DROPZONE_CLASS_HINTS = ["dropzone", "drop-zone", "file-drop", "file-upload", "upload-area", "drag-drop", "file-dropzone", "upload-zone", "drop-area"];
  const DRAG_EVENT_ATTRS = ["ondragover", "ondragenter", "ondragleave", "ondrop"];

  function truncateText(text, maxLength = 3000) {
    const length = text?.length || 0;
    if (length <= maxLength) return text || "";
    {
      const hidden = length - maxLength;
      if (hidden > 100) {
        const marker = `... [content truncated, ${hidden} chars hidden] ...`;
        const budget = maxLength - marker.length;
        const headLength = Math.floor(budget / 2);
        const tailLength = budget - headLength;
        const head = text?.substring(0, headLength) || "";
        const tail = text?.substring(length - tailLength) || "";
        return `${head}${marker}${tail}`;
      } else return text || "";
    }
  }

  function findDescendantAriaLabel(element) {
    if (!element || !element.children || element.children.length === 0 || element.children.length > 30) return null;
    const queue = Array.from(element.children);
    for (let i = 0; i < queue.length; i++) {
      const child = queue[i];
      const label = child.getAttribute("aria-label");
      if (label && label.trim()) return label.trim();
      const grandChildren = child.children;
      if (grandChildren && grandChildren.length)
        for (let j = 0; j < grandChildren.length; j++) queue.push(grandChildren[j]);
    }
    return null;
  }

  function getElementData(element) {
    if (!element) return null;
    if (caches.elementData.has(element)) return caches.elementData.get(element) || null;
    const rect = element.getBoundingClientRect();
    const style = window.getComputedStyle(element);
    const el = element;
    const data = {
      rect,
      style,
      offsetWidth: el.offsetWidth || 0,
      offsetHeight: el.offsetHeight || 0,
      isVisible:
        (el.offsetWidth || 0) > 0 &&
        (el.offsetHeight || 0) > 0 &&
        style.visibility !== "hidden" &&
        style.display !== "none" &&
        element.getAttribute("aria-hidden") !== "true",
      tagName: element.tagName ? element.tagName.toLowerCase() : null
    };
    caches.elementData.set(element, data);
    return data;
  }

  function getBoundingRect(element) {
    const data = getElementData(element);
    return data ? data.rect : null;
  }

  function getComputedStyleCached(element) {
    const data = getElementData(element);
    return data ? data.style : null;
  }

  const nodeMap = {};
  const takenAlohaIds = new Set();

  // THE ONLY PLACE AN ALOHA-ID COMES FROM. Read `identity` top to bottom; the first rung
  // that answers is what gets hashed:
  //   1. a name the page's authors declared (#id, [data-testid]) — survives a re-render
  //      that moves the element among its siblings;
  //   2. the element's position — frame/shadow scope + xpath. Survives a walk of an
  //      unchanged page, and changes when the element moves.
  // Same input, same id, on every walk. That is what lets an id from an earlier read still
  // address the same element, and what lets the stuck-loop guard see a repeated click as a
  // repeat instead of as a new action. It is not free: these hashed ids measure 2534 tokens
  // on a /f/books read against 2316 for the base36 walk counter they replaced, so every step
  // costs +218 tokens (+9.4%). A loop that ends at round three pays that back.
  // The body's id is the constant hashString("|/body") on every page and every tab — an id
  // need only be unique within its walk and resolvable within its page, and an iframe's body
  // is never walked as a body.
  // Memoised on the descriptor because the highlight labels a node sixty lines before the
  // walk registers it; one memo is what lets both read one id without reordering the walk.
  function alohaIdFor(descriptor, element) {
    if (descriptor.alohaId) return descriptor.alohaId;
    const identity = scopeKey(descriptor.contextPath) + (authoredIdentity(element) || descriptor.xpath);
    return (descriptor.alohaId = uniqueAlohaId(hashString(identity)));
  }

  // What the page says this element IS, when it says anything durable. getAttribute("id"),
  // not element.id: HTMLFormElement's named getter shadows the property, so
  // <form><input name="id"></form> makes form.id return the input, not a string.
  function authoredIdentity(element) {
    if (!element || !element.getAttribute) return null;
    const authored = element.getAttribute("id");
    if (authored && !looksGenerated(authored)) return `#${authored}`;
    const testId = element.getAttribute("data-testid") || element.getAttribute("data-test");
    return testId && !looksGenerated(testId) ? `@${testId}` : null;
  }

  // Refuse a name the framework minted this render. #ember1234, #mui-5 and #radix-:r1: are
  // renumbered on remount, so hashing one would make the id LESS stable than the position it
  // replaced — on exactly the pages this change exists for.
  // ponytail: two regexes, not a framework list. Widen if real ids start churning between walks.
  function looksGenerated(value) {
    return !/^[A-Za-z][\w-]*$/.test(value) || /\d{3,}$/.test(value) || /[-_]\d+$/.test(value);
  }

  // Which document the identity is relative to. Without it these are exact-string duplicates,
  // not unlucky hash collisions: iframe children are walked with parentXPath "/body" — the
  // same literal the top document uses — with the iframe's own <body> skipped, and a shadow
  // child is walked with its host's own xpath, the same path its light siblings get. A
  // duplicate does not merely leave two elements matching [aloha-id="…"]; nodeMap[id] hands
  // the map to the later node and re-parents the earlier one's children onto it.
  function scopeKey(contextPath) {
    return (contextPath || []).map((s) => s.selector || `shadow${s.index}`).join(">") + "|";
  }

  // hashString is 32 bits, Math.abs-folded, over inputs that share long prefixes, and duplicate
  // #id attributes are legal in practice. An undetected collision hands nodeMap to the later
  // node while querySelector hands the click to the earlier one. "-", never "." (aloha.click
  // splits an id on its last dot for a select-option index) and never "," (get_text splits a
  // batch of ids on commas).
  function uniqueAlohaId(base) {
    let id = base;
    for (let n = 2; takenAlohaIds.has(id); n++) id = `${base}-${n}`;
    takenAlohaIds.add(id);
    return id;
  }

  function clearStaleAlohaIds(root) {
    if (!root || !root.querySelectorAll) return;
    for (const stale of root.querySelectorAll("[aloha-id]")) stale.removeAttribute("aloha-id");
    for (const host of root.querySelectorAll("*")) {
      if (host.shadowRoot) clearStaleAlohaIds(host.shadowRoot);
    }
    for (const frame of root.querySelectorAll("iframe")) {
      try { if (frame.contentDocument) clearStaleAlohaIds(frame.contentDocument); } catch (e) {}
    }
  }

  function hashString(input) {
    let hash = 0;
    for (let i = 0; i < input.length; i++) hash = ((hash << 5) - hash + input.charCodeAt(i)) | 0;
    return `${Math.abs(hash).toString(16).slice(0, 10)}`;
  }

  const HIGHLIGHT_CONTAINER_ID = "alohajet-highlight-container";
  const highlightedElements = new Set();
  let scrollListenersAttached = false;
  let updateScheduled = false;

  function attachScrollListeners() {
    if (scrollListenersAttached) return;
    scrollListenersAttached = true;
    const onChange = () => scheduleHighlightUpdate();
    window.addEventListener("scroll", onChange, true);
    window.addEventListener("resize", onChange);
  }

  function scheduleHighlightUpdate() {
    if (!updateScheduled) {
      updateScheduled = true;
      requestAnimationFrame(() => {
        updateScheduled = false;
        updateAllHighlights();
      });
    }
  }

  function updateAllHighlights() {
    if (highlightedElements.size !== 0)
      for (const entry of highlightedElements) updateHighlightPosition(entry);
  }

  function updateHighlightPosition(entry) {
    const element = entry.element;
    if (!element || !element.isConnected) return;
    const rects = element.getClientRects();
    const offset = { x: 0, y: 0 };
    if (entry.parentIframe) {
      const iframeRect = entry.parentIframe.getBoundingClientRect();
      offset.x = iframeRect.left;
      offset.y = iframeRect.top;
    }
    for (let i = 0; i < entry.overlays.length; i++) {
      const overlay = entry.overlays[i];
      if (i < rects.length) {
        const rect = rects[i];
        const top = rect.top + offset.y;
        const left = rect.left + offset.x;
        overlay.element.style.top = `${top}px`;
        overlay.element.style.left = `${left}px`;
        overlay.element.style.width = `${rect.width}px`;
        overlay.element.style.height = `${rect.height}px`;
        overlay.element.style.display = rect.width === 0 || rect.height === 0 ? "none" : "block";
      } else overlay.element.style.display = "none";
    }
    const label = entry.label;
    if (label && rects.length > 0) {
      const rect = rects[0];
      const top = rect.top + offset.y;
      const left = rect.left + offset.x;
      let labelTop = top - entry.labelHeight - 2;
      let labelLeft = left + rect.width - entry.labelWidth - 2;
      if (labelTop < offset.y) {
        labelTop = top + 2;
        if (labelLeft < offset.x) labelLeft = left + 2;
        else if (labelLeft + entry.labelWidth > window.innerWidth) {
          labelLeft = window.innerWidth - entry.labelWidth - 2;
          labelLeft = Math.max(left + 2, labelLeft);
        }
      } else if (labelLeft < offset.x) labelLeft = offset.x;
      else if (labelLeft + entry.labelWidth > window.innerWidth) labelLeft = window.innerWidth - entry.labelWidth - 2;
      labelTop = Math.max(offset.y, labelTop);
      label.style.top = `${labelTop}px`;
      label.style.left = `${labelLeft}px`;
      label.style.display = "block";
    } else if (label) label.style.display = "none";
  }

  function isVisibleAndTop(element) {
    if (!element) return false;
    const inViewport = isInViewport(element, 0);
    const top = isTopElement(element);
    return inViewport && top;
  }

  function highlightElement(element, label, parentIframe = null) {
    if (!element) return false;
    const overlays = [];
    let labelEl = null;
    let labelWidth = 20;
    let labelHeight = 16;
    try {
      let container = document.getElementById(HIGHLIGHT_CONTAINER_ID);
      if (!container) {
        container = document.createElement("div");
        container.id = HIGHLIGHT_CONTAINER_ID;
        container.style.cssText =
          "position:fixed;pointer-events:none;top:0;left:0;width:100%;height:100%;z-index:2147483647;background-color:transparent";
        document.body.appendChild(container);
      }
      if (isVisibleAndTop(element) === false) return false;
      const rects = element.getClientRects();
      if (!rects || rects.length === 0) return false;
      const palette = ["#8B0000", "#4B0082", "#00008B"];
      const colorIndex = Math.floor(Math.random() * palette.length);
      const color = palette[colorIndex];
      const borderColor = color + "B1";
      const offset = { x: 0, y: 0 };
      if (parentIframe) {
        const iframeRect = parentIframe.getBoundingClientRect();
        offset.x = iframeRect.left;
        offset.y = iframeRect.top;
      }
      for (const rect of rects) {
        if (rect.width === 0 || rect.height === 0) continue;
        const overlay = document.createElement("div");
        overlay.style.position = "fixed";
        overlay.style.border = `1px solid ${borderColor}`;
        overlay.style.pointerEvents = "none";
        overlay.style.boxSizing = "border-box";
        const top = rect.top + offset.y;
        const left = rect.left + offset.x;
        overlay.style.top = `${top}px`;
        overlay.style.left = `${left}px`;
        overlay.style.width = `${rect.width}px`;
        overlay.style.height = `${rect.height}px`;
        container.appendChild(overlay);
        overlays.push({ element: overlay, initialRect: rect });
      }
      const firstRect = rects[0];
      labelEl = document.createElement("div");
      labelEl.className = "alohajet-highlight-label";
      labelEl.style.position = "fixed";
      labelEl.style.background = color;
      labelEl.style.color = "white";
      labelEl.style.fontWeight = "bold";
      labelEl.style.padding = "2px 3px";
      labelEl.style.borderRadius = "4px";
      labelEl.style.fontSize = "13px";
      labelEl.textContent = `${label}`;
      labelWidth = labelEl.offsetWidth > 0 ? labelEl.offsetWidth : labelWidth;
      labelHeight = labelEl.offsetHeight > 0 ? labelEl.offsetHeight : labelHeight;
      const firstTop = firstRect.top + offset.y;
      const firstLeft = firstRect.left + offset.x;
      let labelTop = firstTop - labelHeight - 2;
      let labelLeft = firstLeft + firstRect.width - labelWidth - 2;
      if (labelTop < offset.y) {
        labelTop = firstTop + 2;
        if (labelLeft < offset.x) labelLeft = firstLeft + 2;
        else if (labelLeft + labelWidth > window.innerWidth) {
          labelLeft = window.innerWidth - labelWidth + 4;
          labelLeft = Math.max(firstLeft + 2, labelLeft);
        }
      } else if (labelLeft < offset.x) labelLeft = offset.x;
      else if (labelLeft + labelWidth > window.innerWidth) labelLeft = window.innerWidth - labelWidth - 2;
      labelTop = Math.max(offset.y, labelTop);
      labelEl.style.top = `${labelTop}px`;
      labelEl.style.left = `${labelLeft}px`;
      container.appendChild(labelEl);
      const entry = {
        element,
        parentIframe,
        overlays,
        label: labelEl,
        labelWidth,
        labelHeight
      };
      highlightedElements.add(entry);
      attachScrollListeners();
      scheduleHighlightUpdate();
      return true;
    } finally {
    }
  }

  function getSiblingIndex(element) {
    const parent = element.parentElement;
    if (!parent) return 0;
    const tagName = element.tagName;
    let count = 0;
    let indexOfElement = 0;
    let sibling = parent.firstElementChild;
    for (; sibling; ) {
      if (sibling.tagName === tagName && sibling.id !== HIGHLIGHT_CONTAINER_ID) {
        count++;
        if (sibling === element) indexOfElement = count;
      }
      sibling = sibling.nextElementSibling;
    }
    return count <= 1 ? 0 : indexOfElement;
  }

  function hasVisibleTextRect(textNode) {
    try {
      const range = document.createRange();
      range.selectNodeContents(textNode);
      const rects = range.getClientRects();
      if (!rects || rects.length === 0) return false;
      let hasVisibleRect = false;
      for (let i = 0; i < rects.length; i++) {
        const rect = rects[i];
        if (rect.width > 0 && rect.height > 0) {
          hasVisibleRect = true;
          break;
        }
      }
      if (!hasVisibleRect) return false;
      const parent = textNode.parentElement;
      if (!parent) return false;
      const style = getComputedStyleCached(parent);
      return style ? style.display !== "none" && style.visibility !== "hidden" && parseFloat(style.opacity) > 0 : false;
    } catch {
      return false;
    }
  }

  function isElementAccepted(element) {
    if (!element || !element.tagName) return false;
    const tag = element.tagName.toLowerCase();
    return ALWAYS_ACCEPTED_TAGS.has(tag) ? true : !NEVER_ACCEPTED_TAGS.has(tag);
  }

  function isElementVisible(element) {
    if (!element) return false;
    if (caches.elementVisibility.has(element)) return caches.elementVisibility.get(element);
    const data = getElementData(element);
    const visible = data ? data.isVisible : false;
    caches.elementVisibility.set(element, visible);
    return visible;
  }

  function isInteractive(element) {
    if (!element || element.nodeType !== Node.ELEMENT_NODE) return false;
    if (interactiveCache.has(element)) return !!interactiveCache.get(element);
    const interactiveCursors = INTERACTIVE_CURSORS;
    const disabledCursors = DISABLED_CURSORS;

    function hasInteractiveCursor(el) {
      if (el.tagName.toLowerCase() === "html") return false;
      const style = getComputedStyleCached(el);
      return style ? !!interactiveCursors.has(style.cursor) : false;
    }

    const cursorIsInteractive = hasInteractiveCursor(element);
    const tag = element.tagName.toLowerCase();
    const interactiveTags = INTERACTIVE_TAGS;

    function hasInteractiveAncestor(el) {
      try {
        let ancestor = el.parentElement;
        let depth = 0;
        for (; ancestor && depth < 8; ) {
          const ancestorTag = ancestor.tagName ? ancestor.tagName.toLowerCase() : "";
          if (INTERACTIVE_TAGS.has(ancestorTag)) return true;
          const role = ancestor.getAttribute && ancestor.getAttribute("role");
          if (
            (role && INTERACTIVE_ROLES.has(role)) ||
            (ancestor.hasAttribute && ancestor.hasAttribute("onclick")) ||
            typeof ancestor.onclick == "function"
          )
            return true;
          ancestor = ancestor.parentElement;
          depth++;
        }
      } catch {}
      return false;
    }

    const style = getComputedStyleCached(element);
    if (interactiveTags.has(tag)) {
      for (const attr of DISABLED_ATTRIBUTES) {
        const value = element.getAttribute(attr);
        if (attr === "aria-disabled" || attr === "aria-readonly") {
          if (value === "true") return false;
        } else if (element.hasAttribute(attr)) return false;
      }
      const el = element;
      let disabled = false;
      let readOnly = false;
      if (tag === "input") {
        const input = element;
        disabled = input.disabled;
        readOnly = input.readOnly;
      } else if (tag === "textarea") {
        const textarea = element;
        disabled = textarea.disabled;
        readOnly = textarea.readOnly;
      } else if (tag === "button" || tag === "select") disabled = element.disabled;
      if (disabled || readOnly || el.inert) return false;
      if (tag === "a") {
        const role = element.getAttribute("role");
        const href = element.getAttribute("href");
        const tabindex = element.getAttribute("tabindex");
        const hasValidTabindex = tabindex !== null && !Number.isNaN(parseInt(tabindex, 10));
        if (href !== null || (role && (INTERACTIVE_ROLES.has(role) || role === "link" || role === "option")) || hasValidTabindex) {
          interactiveCache.set(element, true);
          return true;
        }
      }
      if (tag === "label") {
        const label = element;
        const control = label.control || (label.getAttribute("for") ? document.getElementById(label.getAttribute("for")) : null);
        if (control && control.tagName?.toLowerCase() === "input") {
          const inputType = (control.type || "").toLowerCase();
          if (inputType === "checkbox" || inputType === "radio") {
            const rects = element.getClientRects();
            if (rects && rects.length > 0) {
              for (const rect of rects)
                if (rect.width > 0 && rect.height > 0) {
                  interactiveCache.set(element, true);
                  return true;
                }
            }
          }
        }
      }
      return cursorIsInteractive ? true : tag === "input" || tag === "select" || tag === "textarea" || tag === "button";
    }
    const role = element.getAttribute("role");
    if (role === "switch" || role === "checkbox" || role === "radio")
      return !(
        element.getAttribute("aria-disabled") === "true" ||
        element.hasAttribute("disabled") ||
        (style && style.cursor === "not-allowed")
      );
    const ariaChecked = element.getAttribute("aria-checked");
    const ariaPressed = element.getAttribute("aria-pressed");
    if (ariaChecked !== null || ariaPressed !== null)
      return !(
        element.getAttribute("aria-disabled") === "true" ||
        element.hasAttribute("disabled") ||
        (style && style.cursor === "not-allowed")
      );
    if (style && (disabledCursors.has(style.cursor) || style.pointerEvents === "none" || parseFloat(style.opacity) < 0.3)) return false;
    if (
      element.classList &&
      (element.classList.contains("button") ||
        element.classList.contains("dropdown-toggle") ||
        element.classList.contains("toggle") ||
        element.classList.contains("switch") ||
        element.getAttribute("data-toggle") === "dropdown" ||
        element.getAttribute("aria-haspopup") === "true")
    ) {
      if (element.getAttribute("aria-disabled") === "true" || element.hasAttribute("disabled") || (style && style.cursor === "not-allowed"))
        return false;
      const tabindex = element.getAttribute("tabindex");
      const hasValidTabindex = tabindex !== null && !Number.isNaN(parseInt(tabindex, 10));
      return !!(cursorIsInteractive || hasValidTabindex);
    }
    if (interactiveTags.has(tag) || (role && INTERACTIVE_ROLES.has(role)))
      return !(element.getAttribute("aria-disabled") === "true" || (style && style.cursor === "not-allowed"));
    if (
      element.getAttribute("draggable") === "true" ||
      isFileInputLike(element) ||
      EVENT_HANDLER_ATTRS.some((attr) => (element.hasAttribute(attr) ? true : typeof element[attr] == "function"))
    )
      return true;
    if (hasInteractiveAncestor(element)) {
      const tabindex = element.getAttribute("tabindex");
      return !(tabindex !== null && !Number.isNaN(parseInt(tabindex, 10))) && !cursorIsInteractive ? false : cursorIsInteractive;
    }
    interactiveCache.set(element, false);
    return false;
  }

  function getFirstDescendantText(element) {
    if (!element || element.nodeType !== Node.ELEMENT_NODE) return "";
    const skipTags = new Set(["script", "style", "template", "noscript", "code"]);
    const cached = descendantTextCache.get(element);
    if (cached !== void 0) return cached;
    const parts = [];
    let collectedLength = 0;
    const maxLength = 3000;
    const maxNodes = 2000;
    let visited = 0;

    function visit(node) {
      if (!node || collectedLength >= maxLength || visited++ >= maxNodes) return;
      if (node.nodeType === Node.TEXT_NODE) {
        const textNode = node;
        const text = (textNode.textContent || "").trim();
        if (text && hasVisibleTextRect(textNode)) {
          parts.push(text);
          collectedLength += text.length;
        }
        return;
      }
      if (node.nodeType !== Node.ELEMENT_NODE) return;
      const el = node;
      const tag = el.tagName ? el.tagName.toLowerCase() : "";
      if (skipTags.has(tag)) return;
      if (tag === "img") {
        const alt = el.getAttribute("alt");
        if (alt && alt.trim()) {
          parts.push(alt.trim());
          collectedLength += alt.length;
        }
        return;
      }
      if (tag === "svg") {
        const titleEl = el.querySelector("title");
        if (titleEl && titleEl.textContent) {
          const title = titleEl.textContent.trim();
          if (title) {
            parts.push(title);
            collectedLength += title.length;
          }
        }
        const ariaLabel = el.getAttribute("aria-label");
        if (ariaLabel && ariaLabel.trim()) {
          parts.push(ariaLabel.trim());
          collectedLength += ariaLabel.length;
        }
        return;
      }
      if (el !== element && isInteractive(el)) return;
      const children = el.childNodes;
      for (let i = 0; i < children.length && collectedLength < maxLength; i++) visit(children[i]);
    }

    visit(element);
    const result = parts.join(" ").replace(/\s+/g, " ").trim();
    descendantTextCache.set(element, result);
    return result;
  }

  function getAriaLabelledByText(element) {
    try {
      const labelledBy = element.getAttribute && element.getAttribute("aria-labelledby");
      if (!labelledBy) return "";
      const ids = labelledBy.split(/\s+/).filter((id) => id.trim());
      const parts = [];
      for (let i = 0; i < ids.length; i++) {
        const id = ids[i];
        const referenced = document.getElementById(id);
        if (referenced) {
          const text = referenced.textContent ? referenced.textContent.trim() : "";
          if (text) parts.push(text);
        }
      }
      return parts.join(" ");
    } catch {
      return "";
    }
  }

  function getNestedAriaLabels(element) {
    try {
      if ((element.childElementCount || 0) > 120) return "";
      const labelled = element.querySelectorAll("[aria-label], [aria-labelledby]");
      const parts = [];
      const seen = new Set();
      const maxLabels = 50;
      for (let i = 0; i < labelled.length && i < maxLabels; i++) {
        const el = labelled[i];
        if (el.getAttribute && el.getAttribute("aria-hidden") === "true") continue;
        let text = "";
        const ariaLabel = el.getAttribute && el.getAttribute("aria-label");
        if (ariaLabel && ariaLabel.trim()) text = ariaLabel.trim();
        else {
          const labelledByText = getAriaLabelledByText(el);
          if (labelledByText && labelledByText.trim()) text = labelledByText.trim();
        }
        if (text) {
          const lower = text.toLowerCase();
          if (!seen.has(lower)) {
            seen.add(lower);
            parts.push(text);
          }
        }
      }
      return parts.join(" ");
    } catch {
      return "";
    }
  }

  function getFormValue(element) {
    try {
      const tag = element.tagName ? element.tagName.toLowerCase() : "";
      if (tag === "input" || tag === "textarea") {
        return __alohaIsSensitiveField(element) ? \#(sensitiveFieldMaskJS) : (element.value || "");
      }
      if (tag === "select") {
        const select = element;
        if (select.selectedIndex >= 0) {
          const option = select.options[select.selectedIndex];
          return (option && (option.text || option.textContent || "")) || "";
        }
        return "";
      }
    } catch {}
    return "";
  }

  function getComprehensiveText(element) {
    if (!element) return "";
    const cached = comprehensiveTextCache.get(element);
    if (cached !== void 0) return cached;
    try {
      const tag = element.tagName ? element.tagName.toLowerCase() : "";
      if (tag === "style" || tag === "script" || tag === "code") return "";
    } catch {}
    const parts = [];
    const seen = new Set();
    function add(text) {
      if (!text || typeof text != "string") return;
      const trimmed = text.trim();
      if (!trimmed) return;
      const lower = trimmed.toLowerCase();
      if (!seen.has(lower)) {
        seen.add(lower);
        parts.push(trimmed);
      }
    }
    try {
      const labelledBy = element.getAttribute && element.getAttribute("aria-labelledby");
      if (labelledBy) {
        const ids = labelledBy.split(/\s+/).filter((id) => id.trim());
        const maxIds = 5;
        for (let i = 0; i < ids.length && i < maxIds; i++) {
          const referenced = document.getElementById(ids[i]);
          if (referenced) add(getComprehensiveText(referenced));
        }
      }
    } catch {}
    try {
      const ariaLabel = element.getAttribute && element.getAttribute("aria-label");
      if (ariaLabel) add(ariaLabel);
    } catch {}
    try {
      const describedBy = element.getAttribute && element.getAttribute("aria-describedby");
      if (describedBy) {
        const ids = describedBy.split(/\s+/).filter((id) => id.trim());
        const maxIds = 5;
        for (let i = 0; i < ids.length && i < maxIds; i++) {
          const referenced = document.getElementById(ids[i]);
          if (referenced) add(getComprehensiveText(referenced));
        }
      }
    } catch {}
    try {
      const tag = element.tagName ? element.tagName.toLowerCase() : "";
      if (tag === "input") {
        const input = element;
        // A credential field's VALUE never joins the text the model reads. Everything
        // else about the field — its label, placeholder, type — still does.
        if (input.value && !__alohaIsSensitiveField(input)) add(input.value);
        if (input.placeholder) add(input.placeholder);
        if ((input.type === "checkbox" || input.type === "radio") && input.labels)
          for (let i = 0; i < input.labels.length; i++) add(input.labels[i].textContent || "");
      } else if (tag === "textarea") {
        const textarea = element;
        if (textarea.value && !__alohaIsSensitiveField(textarea)) add(textarea.value);
        if (textarea.placeholder) add(textarea.placeholder);
      } else if (tag === "select") {
        const select = element;
        if (select.selectedIndex >= 0) {
          const selected = select.options[select.selectedIndex];
          if (selected) add(selected.text || selected.textContent || "");
        }
        const maxOptions = 50;
        for (let i = 0; i < select.options.length && i < maxOptions; i++) {
          const option = select.options[i];
          add(option.text || option.textContent || "");
        }
      } else if (tag === "option") {
        const option = element;
        add(option.text || option.textContent || "");
        if (option.value && option.value !== option.text) add(option.value);
      }
    } catch {}
    try {
      const attrs = ["alt", "title", "aria-placeholder", "data-label", "data-text", "data-tooltip"];
      for (let i = 0; i < attrs.length; i++) {
        const value = element.getAttribute && element.getAttribute(attrs[i]);
        if (value) add(value);
      }
    } catch {}
    try {
      const directText = Array.from(element.childNodes)
        .filter((node) => node.nodeType === Node.TEXT_NODE)
        .map((node) => (node.textContent || "").trim())
        .filter((text) => !!text)
        .join(" ");
      if (directText) add(directText);
    } catch {}
    try {
      const descendantText = getFirstDescendantText(element);
      if (descendantText) add(descendantText);
    } catch {}
    try {
      const nestedLabels = getNestedAriaLabels(element);
      if (nestedLabels) add(nestedLabels);
    } catch {}
    try {
      const el = element;
      if (el.shadowRoot) {
        const shadowParts = [];
        const shadowChildren = Array.from(el.shadowRoot.childNodes);
        const maxShadowChildren = 100;
        for (let i = 0; i < shadowChildren.length && i < maxShadowChildren; i++) {
          const node = shadowChildren[i];
          if (node.nodeType === Node.ELEMENT_NODE) {
            const childEl = node;
            const childTag = childEl.tagName ? childEl.tagName.toLowerCase() : "";
            if (childTag === "style" || childTag === "script" || childTag === "code") continue;
            shadowParts.push(getComprehensiveText(childEl));
          } else if (node.nodeType === Node.TEXT_NODE) {
            const text = (node.textContent || "").trim();
            if (text) shadowParts.push(text);
          }
        }
        const shadowText = shadowParts.join(" ").replace(/\s+/g, " ").trim();
        if (shadowText) add(shadowText);
      }
    } catch {}
    if (parts.length === 0)
      try {
        const fallbackParts = [];
        const collect = (node) => {
          if (node.nodeType === Node.TEXT_NODE) {
            const text = (node.textContent || "").trim();
            if (text) fallbackParts.push(text);
            return;
          }
          if (node.nodeType !== Node.ELEMENT_NODE) return;
          const el = node;
          const tag = el.tagName ? el.tagName.toLowerCase() : "";
          if (tag === "script" || tag === "style" || tag === "template" || tag === "noscript") return;
          if (tag === "img") {
            const alt = el.getAttribute("alt");
            if (alt && alt.trim()) fallbackParts.push(alt.trim());
            return;
          }
          if (tag === "svg") {
            const titleEl = el.querySelector("title");
            if (titleEl && titleEl.textContent) {
              const title = titleEl.textContent.trim();
              if (title) fallbackParts.push(title);
            }
            const ariaLabel = el.getAttribute("aria-label");
            if (ariaLabel && ariaLabel.trim()) fallbackParts.push(ariaLabel.trim());
            return;
          }
          const children = el.childNodes;
          for (let i = 0; i < children.length; i++) collect(children[i]);
        };
        collect(element);
        const fallbackText = fallbackParts.join(" ").replace(/\s+/g, " ").trim();
        if (fallbackText) add(fallbackText);
      } catch {}
    // Different collectors above (direct text nodes, getFirstDescendantText, aria) can each
    // add a text where one is a SUBSTRING of another — e.g. the direct text "Submitted by"
    // plus the first-descendant text "Submitted by t3_… 3 years ago". The exact-match `seen`
    // set misses that overlap, so the join reads "Submitted by Submitted by t3_…". Drop any
    // part fully contained in a longer part; the longer one already carries it.
    const kept = parts.filter(function (p) {
      const pl = p.toLowerCase();
      return !parts.some(function (q) { return q.length > p.length && q.toLowerCase().indexOf(pl) !== -1; });
    });
    const result = kept.join(" ").replace(/\s+/g, " ").trim();
    comprehensiveTextCache.set(element, result);
    return result;
  }

  function attachComprehensiveText(node, element) {
    try {
      const comprehensiveText = getComprehensiveText(element);
      node.comprehensiveText = comprehensiveText;
      node.textSources = {
        ariaLabel: (element.getAttribute && (element.getAttribute("aria-label") || "")) || "",
        ariaLabelledby: getAriaLabelledByText(element),
        formValue: getFormValue(element),
        placeholder: (element.getAttribute && (element.getAttribute("placeholder") || "")) || "",
        ariaPlaceholder: (element.getAttribute && (element.getAttribute("aria-placeholder") || "")) || "",
        alt: (element.getAttribute && (element.getAttribute("alt") || "")) || "",
        title: (element.getAttribute && (element.getAttribute("title") || "")) || "",
        textContent: (element.textContent || "").trim(),
        descendantText: getFirstDescendantText(element)
      };
    } catch {}
  }

  let cachedModalContainers;

  function getVisibleModalContainers() {
    if (cachedModalContainers) return cachedModalContainers;
    let containers = [];
    try {
      const candidates = Array.from(
        document.querySelectorAll(
          '[data-baseweb="modal"], [data-baseweb="drawer"], [role="dialog"], [aria-modal="true"], [aria-label="dialog"], [data-animated-popover-backdrop]'
        )
      );
      for (const candidate of candidates) {
        const rects = candidate.getClientRects();
        if (!rects || rects.length === 0) continue;
        let visible = false;
        for (const rect of rects)
          if (
            rect.width > 0 &&
            rect.height > 0 &&
            !(rect.bottom < 1 || rect.top > window.innerHeight + -1 || rect.right < 1 || rect.left > window.innerWidth + -1)
          ) {
            visible = true;
            break;
          }
        if (visible) containers.push(candidate);
      }
    } catch {
      containers = [];
    }
    cachedModalContainers = containers;
    return cachedModalContainers;
  }

  function isTopElement(element) {
    const rects = element.getClientRects();
    if (!rects || rects.length === 0) return false;
    let hasVisibleRect = false;
    for (const rect of rects)
      if (
        rect.width > 0 &&
        rect.height > 0 &&
        !(rect.bottom < 1 || rect.top > window.innerHeight + -1 || rect.right < 1 || rect.left > window.innerWidth + -1)
      ) {
        hasVisibleRect = true;
        break;
      }
    if (element.ownerDocument !== window.document) return true;
    if (element.getRootNode() instanceof ShadowRoot) {
      rects[Math.floor(rects.length / 2)].left + rects[Math.floor(rects.length / 2)].width / 2;
      rects[Math.floor(rects.length / 2)].top + rects[Math.floor(rects.length / 2)].height / 2;
      return true;
    }
    if (!hasVisibleRect) return true;
    const centerX = rects[Math.floor(rects.length / 2)].left + rects[Math.floor(rects.length / 2)].width / 2;
    const centerY = rects[Math.floor(rects.length / 2)].top + rects[Math.floor(rects.length / 2)].height / 2;
    try {
      const topElementAtPoint = document.elementFromPoint(centerX, centerY);
      if (!topElementAtPoint) return false;
      let current = topElementAtPoint;
      for (; current && current !== document.documentElement; ) {
        if (current === element) return true;
        current = current.parentElement;
      }
      const tag = element.tagName.toLowerCase();
      if (
        tag === "input" ||
        tag === "button" ||
        tag === "select" ||
        tag === "textarea" ||
        element.getAttribute("role") === "switch" ||
        element.getAttribute("role") === "checkbox" ||
        element.getAttribute("role") === "radio" ||
        element.hasAttribute("aria-checked") ||
        element.hasAttribute("aria-pressed")
      ) {
        if (topElementAtPoint.contains(element)) return true;
        const elementParent = element.parentElement;
        const topParent = topElementAtPoint.parentElement;
        if ((elementParent && elementParent === topParent) || (elementParent?.parentElement && elementParent.parentElement === topParent?.parentElement))
          return true;
        if (tag === "input") {
          const id = element.getAttribute("id");
          if (id) {
            let current2 = topElementAtPoint;
            for (; current2 && current2 !== document.documentElement; ) {
              if (current2.tagName.toLowerCase() === "label" && current2.getAttribute("for") === id) return true;
              current2 = current2.parentElement;
            }
          }
          let ancestor = element.parentElement;
          for (; ancestor && ancestor !== document.documentElement; ) {
            if (ancestor.tagName.toLowerCase() === "label") {
              if (ancestor.contains(topElementAtPoint)) return true;
              break;
            }
            ancestor = ancestor.parentElement;
          }
        }
      }
      return false;
    } catch {
      return true;
    }
  }

  // Hit-test probe: returns the element visually covering `element`, or null if `element` is
  // reachable at any sampled point. An occluder is reported ONLY when EVERY in-viewport sampled
  // point is intercepted by a foreign element (none reaches `element`) — the dual of the click
  // path's "any free point => clickable". document.elementFromPoint is pointer-events aware: a
  // `pointer-events:none` (transparent, non-clickable) overlay is skipped and never counts as an
  // occluder, while a transparent BUT clickable interceptor is returned. Opacity is irrelevant by
  // construction. The sampled geometry is kept identical to clickablePointScript in
  // AgentDOMService.swift (center + four 25% quadrants + four 5px edge midpoints) so the read's
  // reachable-set matches the click's: a partially exposed element the click can still reach is
  // never reported as occluded, while a full-cover overlay (modal / cookie wall) covers every
  // point and is still reported. Keep the two point lists in sync.
  function probeOccluder(element) {
    try {
      if (element.ownerDocument !== window.document) return null;
      if (element.getRootNode() instanceof ShadowRoot) return null;
      const rects = element.getClientRects();
      if (!rects || rects.length === 0) return null;
      const rect = rects[Math.floor(rects.length / 2)];
      if (rect.width <= 0 || rect.height <= 0) return null;
      const pad = 5;
      const points = [
        [rect.left + rect.width / 2, rect.top + rect.height / 2],
        [rect.left + rect.width * 0.25, rect.top + rect.height * 0.25],
        [rect.left + rect.width * 0.75, rect.top + rect.height * 0.25],
        [rect.left + rect.width * 0.25, rect.top + rect.height * 0.75],
        [rect.left + rect.width * 0.75, rect.top + rect.height * 0.75],
        [rect.left + pad, rect.top + rect.height / 2],
        [rect.right - pad, rect.top + rect.height / 2],
        [rect.left + rect.width / 2, rect.top + pad],
        [rect.left + rect.width / 2, rect.bottom - pad]
      ];
      let cover = null;
      let sampled = 0;
      for (const point of points) {
        const px = point[0];
        const py = point[1];
        if (px < 0 || py < 0 || px > window.innerWidth || py > window.innerHeight) continue;
        sampled++;
        const hit = document.elementFromPoint(px, py);
        // An empty hit-test means nothing intercepts this point: the element is reachable here, so
        // it cannot be fully covered.
        if (!hit) return null;
        if (hit === element || element.contains(hit)) return null;
        if (hit.contains && hit.contains(element)) return null;
        let current = hit;
        for (; current && current !== document.documentElement; ) {
          if (current === element) return null;
          current = current.parentElement;
        }
        const hitTag = (hit.tagName || "").toLowerCase();
        // Clicking a <label for=this> (or a wrapping <label>) delegates to this element — the hit
        // is the element's own control surface, not an occluder.
        if (hitTag === "label") {
          const labelFor = hit.getAttribute("for");
          if ((labelFor && labelFor === element.id) || hit.contains(element)) return null;
        }
        // An INTERACTIVE sibling sharing this element's container is most likely the intended click
        // target (a custom <select>, an overlaid <a>/<button>), not an occluding overlay — a real
        // modal/backdrop is a NON-interactive container, so it is still reported as the cover.
        const hitRole = (hit.getAttribute && hit.getAttribute("role")) || "";
        const hitInteractive =
          hitTag === "a" || hitTag === "button" || hitTag === "input" || hitTag === "select" ||
          hitTag === "textarea" || hitTag === "label" ||
          hitRole === "button" || hitRole === "link" || hitRole === "menuitem" ||
          hitRole === "tab" || hitRole === "option" || hitRole === "checkbox" || hitRole === "radio";
        const sharesContainer =
          !!element.parentElement &&
          (hit.parentElement === element.parentElement ||
            (!!element.parentElement.parentElement && hit.parentElement === element.parentElement.parentElement));
        if (hitInteractive && sharesContainer) continue;
        if (!cover) cover = hit;
      }
      if (sampled === 0) return null;
      return cover;
    } catch {
      return null;
    }
  }

  // A scrollable container hides part of its content behind its own clip box; the flat text read
  // gives no sign of that, so a custom scroll region (a date/time wheel, an overflow list) reads as
  // an undifferentiated run of values with no position. getScrollDescriptor annotates such a
  // container with its overflow geometry and, for value-selector wheels, the child currently sitting
  // at the container's center. Computed style and bounding rects come from the same per-element cache
  // the walker already populated, so this adds no extra layout; the result is memoized in
  // caches.scrollProperties (reset per walk by clearCache, so it never goes stale).
  function getScrollDescriptor(element) {
    if (caches.scrollProperties.has(element)) return caches.scrollProperties.get(element);
    let result = null;
    try {
      const style = getComputedStyleCached(element);
      if (!style) {
        caches.scrollProperties.set(element, null);
        return null;
      }
      const oy = style.overflowY;
      const ox = style.overflowX;
      // The four scroll metrics are read once and carried on the result; reading them is a
      // layout-read, not a write, so it does not invalidate the cached rects of other elements.
      const sh = element.scrollHeight | 0;
      const ch = element.clientHeight | 0;
      const sw = element.scrollWidth | 0;
      const cw = element.clientWidth | 0;
      const BUF = 4; // tolerate sub-pixel rounding between scroll/client measurements
      const vScrollable = (oy === "scroll" || oy === "auto") && sh > ch + BUF;
      const hScrollable = (ox === "scroll" || ox === "auto") && sw > cw + BUF;
      if (vScrollable || hScrollable) {
        result = {
          vertical: vScrollable ? { scrollTop: element.scrollTop | 0, scrollHeight: sh, clientHeight: ch } : null,
          horizontal: hScrollable ? { scrollLeft: element.scrollLeft | 0, scrollWidth: sw, clientWidth: cw } : null,
          centeredChild: null
        };
        // Only resolve the centered child when the container looks like a value-selector wheel:
        // declared scroll-snap (the strong, intent-declared signal) or a short list of similar,
        // short-text children (the fallback for JS-driven wheels without snap CSS). Ordinary scroll
        // regions and the page body never pay for the per-child scan below.
        const snap = (style.scrollSnapType || "").trim();
        const looksLikeSelector = (snap && snap !== "none") || isShortSimilarChildList(element);
        if (looksLikeSelector && vScrollable) result.centeredChild = nearestCenteredChildText(element);
      }
    } catch {}
    caches.scrollProperties.set(element, result);
    return result;
  }

  // "Looks like a value selector": a short-to-medium list of homogeneous, short-text children. A
  // wheel picker is a handful of like-tagged rows ("21:30", "22:00", a day number), not a long feed.
  // This is a tagName/text check over direct children only — no geometry, so it is cheap.
  function isShortSimilarChildList(element) {
    const kids = element.children;
    if (!kids) return false;
    const count = kids.length;
    if (count < 3 || count > 60) return false;
    const sample = Math.min(count, 8);
    const tagCounts = {};
    let shortText = 0;
    for (let i = 0; i < sample; i++) {
      const kid = kids[i];
      const tag = (kid.tagName || "").toLowerCase();
      if (tag) tagCounts[tag] = (tagCounts[tag] || 0) + 1;
      const text = (kid.textContent || "").trim();
      if (text.length <= 12) shortText++;
    }
    let topTagCount = 0;
    for (const tag in tagCounts) if (tagCounts[tag] > topTagCount) topTagCount = tagCounts[tag];
    const majorityHomogeneous = topTagCount * 2 > sample;
    const majorityShort = shortText * 2 > sample;
    return majorityHomogeneous && majorityShort;
  }

  // Trimmed text of the direct child whose box center is nearest the container's viewport center —
  // i.e. the currently "selected" value in a snap/wheel selector. Iterates direct children only
  // (capped), reusing cached rects, so it forces no new layout for already-walked children.
  function nearestCenteredChildText(element) {
    const cr = getBoundingRect(element);
    if (!cr) return null;
    const cy = cr.top + cr.height / 2;
    let best = null;
    let bestDist = Infinity;
    const kids = element.children;
    const MAX = 60;
    for (let i = 0; i < kids.length && i < MAX; i++) {
      const kr = getBoundingRect(kids[i]);
      if (!kr || kr.height <= 0) continue;
      const kc = kr.top + kr.height / 2;
      // Restrict to children whose center is within the container's visible window.
      if (kc < cr.top - 2 || kc > cr.bottom + 2) continue;
      const d = Math.abs(kc - cy);
      if (d < bestDist) {
        bestDist = d;
        best = kids[i];
      }
    }
    if (!best) return null;
    const t = (best.textContent || "").trim().replace(/\s+/g, " ");
    return t ? t.slice(0, 40) : null;
  }

  function isInViewport(node, margin) {
    if (margin === -1) return true;
    let rects = null;
    if (node.nodeType === Node.TEXT_NODE)
      try {
        const range = document.createRange();
        range.selectNodeContents(node);
        rects = range.getClientRects();
        if (!rects || rects.length === 0) {
          const rect = range.getBoundingClientRect();
          rects = rect && rect.width > 0 && rect.height > 0 ? [rect] : null;
        }
      } catch {
        rects = null;
      }
    else {
      const element = node;
      try {
        rects = typeof element.getClientRects == "function" ? element.getClientRects() : null;
      } catch {
        rects = null;
      }
      if (!rects || rects.length === 0) {
        const rect = getBoundingRect(element);
        return !rect || rect.width === 0 || rect.height === 0
          ? false
          : !(rect.bottom < -margin || rect.top > window.innerHeight + margin || rect.right < -margin || rect.left > window.innerWidth + margin);
      }
    }
    if (!rects || rects.length === 0) return false;
    for (const rect of Array.from(rects))
      if (
        !(rect.width === 0 || rect.height === 0) &&
        !(rect.bottom < -margin || rect.top > window.innerHeight + margin || rect.right < -margin || rect.left > window.innerWidth + margin)
      )
        return true;
    return false;
  }

  function isLikelyInteractive(element) {
    if (!element || element.nodeType !== Node.ELEMENT_NODE) return false;
    const tag = element.tagName.toLowerCase();
    return !!(
      HIGHLIGHT_LABEL_TAGS.has(tag) ||
      isTextInput(element) ||
      isMultilineInput(element) ||
      isSelectElement(element) ||
      element.hasAttribute("onclick") ||
      element.hasAttribute("role") ||
      element.hasAttribute("tabindex") ||
      element.hasAttribute("data-action") ||
      element.getAttribute("contenteditable") == "true" ||
      element.hasAttribute("aria-expanded") ||
      element.hasAttribute("aria-selected") ||
      element.hasAttribute("aria-pressed") ||
      element.hasAttribute("aria-current") ||
      element.hasAttribute("aria-haspopup") ||
      element.hasAttribute("aria-invalid") ||
      element.hasAttribute("aria-busy") ||
      element.hasAttribute("aria-controls") ||
      isFileInputLike(element)
    );
  }

  function hasInteractiveSignals(element) {
    if (!element || element.nodeType !== Node.ELEMENT_NODE) return false;
    const tag = element.tagName.toLowerCase();
    const role = element.getAttribute("role");
    if (
      tag === "iframe" ||
      LEAF_NODE_TAGS.has(tag) ||
      (role && INTERACTIVE_ROLES.has(role)) ||
      element.hasAttribute("aria-checked") ||
      element.hasAttribute("aria-pressed") ||
      element.isContentEditable ||
      element.getAttribute("contenteditable") === "true" ||
      element.hasAttribute("data-testid") ||
      element.hasAttribute("data-cy") ||
      element.hasAttribute("data-test") ||
      element.hasAttribute("onclick") ||
      typeof element.onclick == "function"
    )
      return true;
    const tabindex = element.getAttribute("tabindex");
    if (tabindex !== null) {
      const parsed = parseInt(tabindex, 10);
      if (!Number.isNaN(parsed) && parsed >= 0) return true;
    }
    const className = element.className || "";
    if (
      (typeof className == "string" && /\b(link|listitem|list-item|entry|row|clickable)\b/i.test(className)) ||
      isFileInputLike(element)
    )
      return true;
    try {
      const getEventListeners = window.getEventListeners;
      if (typeof getEventListeners == "function") {
        const listeners = getEventListeners(element);
        const events = ["mousedown", "mouseup", "keydown", "keyup", "submit", "change", "input", "focus", "blur"];
        for (const event of events) if (listeners[event] && listeners[event].length > 0) return true;
      } else if (
        [
          "onclick",
          "onmousedown",
          "onmouseup",
          "onmouseenter",
          "onmouseleave",
          "onmouseover",
          "onmouseout",
          "ondblclick",
          "oncontextmenu",
          "onpointerdown",
          "onpointerup",
          "onpointerover",
          "onpointerout",
          "onkeydown",
          "onkeyup",
          "onsubmit",
          "onchange",
          "oninput",
          "onfocus",
          "onblur"
        ].some((attr) => element.hasAttribute(attr))
      )
        return true;
    } catch {}
    return false;
  }

  function isFileInputLike(element) {
    if (!element || element.nodeType !== Node.ELEMENT_NODE) return false;
    try {
      const tag = element.tagName.toLowerCase();
      const type = element.getAttribute && element.getAttribute("type");
      if (tag === "input" && type && type.toLowerCase() === "file") return true;
    } catch {}
    const fileInputs = element.querySelectorAll('input[type="file"]');
    if (fileInputs.length > 0)
      for (const fileInput of fileInputs) {
        const style = getComputedStyleCached(fileInput);
        if (
          style &&
          (style.display === "none" ||
            style.visibility === "hidden" ||
            fileInput.classList.contains("hidden") ||
            fileInput.hasAttribute("hidden"))
        )
          return true;
      }
    const classList = element.classList;
    if (classList) {
      for (let i = 0; i < DROPZONE_CLASS_HINTS.length; i++)
        if (classList.contains(DROPZONE_CLASS_HINTS[i])) {
          const text = element.textContent?.toLowerCase() || "";
          if (text.includes("drop") || text.includes("upload") || text.includes("file") || text.includes("drag")) return true;
        }
      if (classList.contains("border-dashed") || classList.contains("dashed")) {
        const text = element.textContent?.toLowerCase() || "";
        if (text.includes("drop") && (text.includes("upload") || text.includes("file"))) return true;
      }
    }
    try {
      const getEventListeners = window.getEventListeners;
      if (typeof getEventListeners == "function") {
        const listeners = getEventListeners(element);
        let dragListenerCount = 0;
        if (listeners.dragover?.length) dragListenerCount++;
        if (listeners.dragenter?.length) dragListenerCount++;
        if (listeners.dragleave?.length) dragListenerCount++;
        if (listeners.drop?.length) dragListenerCount++;
        if (dragListenerCount >= 2) {
          const text = element.textContent?.toLowerCase() || "";
          if (text.includes("drop") || text.includes("upload") || text.includes("file")) return true;
        }
      } else {
        let dragAttrCount = 0;
        for (let i = 0; i < DRAG_EVENT_ATTRS.length; i++) if (element.hasAttribute(DRAG_EVENT_ATTRS[i])) dragAttrCount++;
        if (dragAttrCount >= 2) {
          const text = element.textContent?.toLowerCase() || "";
          if (text.includes("drop") || text.includes("upload") || text.includes("file")) return true;
        }
      }
    } catch {}
    return false;
  }

  function isTextInput(element) {
    if (!element || element.nodeType !== Node.ELEMENT_NODE) return false;
    const tag = element.tagName.toLowerCase();
    const role = element.getAttribute("role");
    return !!(
      tag === "input" ||
      tag === "textarea" ||
      (role && new Set(["searchbox", "combobox", "spinbutton", "slider", "textbox"]).has(role))
    );
  }

  function isMultilineInput(element) {
    if (!element || element.nodeType !== Node.ELEMENT_NODE) return false;
    const tag = element.tagName.toLowerCase();
    const role = element.getAttribute("role");
    return tag === "textarea" || (role === "textbox" && element.getAttribute("aria-multiline") === "true");
  }

  function isSelectElement(element) {
    return !element || element.nodeType !== Node.ELEMENT_NODE ? false : element.tagName.toLowerCase() === "select";
  }

  function extractInputData(element) {
    if (!element) return null;
    const tag = element.tagName.toLowerCase();
    const role = element.getAttribute("role");
    let data = {
      type: "text",
      value: "",
      placeholder: "",
      required: false,
      disabled: false,
      readonly: false,
      multiline: false,
      checked: false
    };
    if (tag === "input") {
      const input = element;
      data = {
        type: input.type || "text",
        value: __alohaIsSensitiveField(input) ? \#(sensitiveFieldMaskJS) : (input.value || ""),
        placeholder: input.placeholder || "",
        required: input.required || false,
        disabled: input.disabled || false,
        readonly: input.readOnly || false,
        multiline: false,
        checked: input.checked || false
      };
      const style = getComputedStyleCached(element);
      if (style && (style.cursor === "not-allowed" || style.cursor === "no-drop")) data.disabled = true;
    } else if (tag === "textarea") {
      const textarea = element;
      data = {
        type: "textarea",
        value: __alohaIsSensitiveField(textarea) ? \#(sensitiveFieldMaskJS) : (textarea.value || ""),
        placeholder: textarea.placeholder || "",
        required: textarea.required || false,
        disabled: textarea.disabled || false,
        readonly: textarea.readOnly || false,
        multiline: true,
        checked: false
      };
      const style = getComputedStyleCached(element);
      if (style && (style.cursor === "not-allowed" || style.cursor === "no-drop")) data.disabled = true;
    } else if (role) {
      const multiline = element.getAttribute("aria-multiline") === "true";
      const ariaChecked = element.getAttribute("aria-checked");
      data = {
        type: role,
        value: element.getAttribute("aria-valuenow") || element.textContent || "",
        placeholder: element.getAttribute("aria-placeholder") || "",
        required: element.getAttribute("aria-required") === "true",
        disabled: element.getAttribute("aria-disabled") === "true",
        readonly: element.getAttribute("aria-readonly") === "true",
        multiline,
        checked: ariaChecked === "true" || ariaChecked === "mixed"
      };
      const style = getComputedStyleCached(element);
      if (style && (style.cursor === "not-allowed" || style.cursor === "no-drop")) data.disabled = true;
    }
    return data;
  }

  function maybeHighlightNode(node, element, parentIframe, inheritedHighlight) {
    let shouldConsider = false;
    if (node.isInteractive)
      if (inheritedHighlight) {
        if (hasInteractiveSignals(element)) shouldConsider = true;
        else shouldConsider = false;
      } else shouldConsider = true;
    else shouldConsider = false;
    if (shouldConsider && ((node.isInViewport = isInViewport(element, -1)), node.isInViewport)) {
      const lacksText = !(node.comprehensiveText || "").trim().length;
      if (collectAllInteractive || lacksText) {
        highlightElement(element, alohaIdFor(node, element), parentIframe);
        return true;
      } else return true;
    }
    return false;
  }

  function getTextNodeBounds(textNode) {
    try {
      const range = document.createRange();
      range.selectNodeContents(textNode);
      const rect = range.getBoundingClientRect();
      return (
        range.detach(),
        rect.width === 0 && rect.height === 0
          ? null
          : {
              x: rect.x,
              y: rect.y,
              width: rect.width,
              height: rect.height,
              top: rect.top,
              right: rect.right,
              bottom: rect.bottom,
              left: rect.left
            }
      );
    } catch {
      return null;
    }
  }

  function walkNode(node, parentIframe = null, inheritedHighlight = false, contextPath = [], parentXPath = null) {
    if (!node || node.id === HIGHLIGHT_CONTAINER_ID) return null;

    if (node === document.body) {
      const body = node;
      const descriptor = {
        tagName: "body",
        attributes: {},
        xpath: "/body",
        contextPath: [...contextPath],
        children: [],
        textContent: "",
        isHighlighted: false,
        childText: Array.from(body.childNodes)
          .filter((child) => child.nodeType === Node.TEXT_NODE)
          .map((child) => child.textContent?.trim() || "")
          .join(" ")
          .trim()
      };
      for (const child of body.childNodes) {
        const childId = walkNode(child, parentIframe, false, contextPath, "/body");
        if (childId) descriptor.children.push(childId);
      }
      const id = alohaIdFor(descriptor, body);
      nodeMap[id] = descriptor;
      try {
        body.setAttribute("aloha-id", id);
        descriptor.attributes["aloha-id"] = id;
      } catch {}
      return id;
    }

    if (node.nodeType !== Node.ELEMENT_NODE && node.nodeType !== Node.TEXT_NODE) return null;

    if (node.nodeType === Node.TEXT_NODE) {
      const textNode = node;
      const text = (textNode.textContent || "").trim();
      if (!text || text.length <= 1) return null;
      const parent = textNode.parentElement;
      if (!parent || parent.tagName.toLowerCase() === "script") return null;

      try {
        const modals = getVisibleModalContainers();
        if (modals.length > 0) {
          let insideModal = false;
          for (const modal of modals)
            if (modal.contains(parent)) {
              insideModal = true;
              break;
            }
          if (!insideModal) return null;
        }
      } catch {}

      if (!hasVisibleTextRect(textNode)) return null;

      try {
        const parentTag = parent.tagName ? parent.tagName.toLowerCase() : "";
        if (TEXT_CONTAINER_TAGS.has(parentTag) || isInteractive(parent)) {
          const directText = Array.from(parent.childNodes)
            .filter((child) => child.nodeType === Node.TEXT_NODE)
            .map((child) => (child.textContent || "").trim())
            .filter((child) => !!child)
            .join(" ")
            .replace(/\s+/g, " ")
            .trim();
          const fullText = (parent.textContent || "").trim().replace(/\s+/g, " ");
          const hasFewChildren = parent.children.length <= 1;
          if (directText === text || (fullText === text && hasFewChildren)) return null;
        }

        let ancestor = parent;
        let depth = 0;
        for (; ancestor && depth < 2; ) {
          if ((ancestor.tagName ? ancestor.tagName.toLowerCase() : "") === "a") {
            const directText = Array.from(ancestor.childNodes)
              .filter((child) => child.nodeType === Node.TEXT_NODE)
              .map((child) => (child.textContent || "").trim())
              .filter((child) => !!child)
              .join(" ")
              .replace(/\s+/g, " ")
              .trim();
            const fullText = (ancestor.textContent || "").trim().replace(/\s+/g, " ");
            if (directText === text || fullText === text) return null;
          }
          ancestor = ancestor.parentElement;
          depth++;
        }
      } catch {}

      const parentPath = parentXPath || "";
      const parentEl = textNode.parentElement;
      let textXPathSegment = "text()";
      if (parentEl) {
        const textIndex =
          Array.from(parentEl.childNodes)
            .filter((child) => child.nodeType === Node.TEXT_NODE && (child.textContent || "").trim().length > 1)
            .indexOf(textNode) + 1;
        textXPathSegment = textIndex > 1 ? `text()[${textIndex}]` : "text()";
      }
      const xpath = `${parentPath || ""}/${textXPathSegment}`;
      const bounds = getTextNodeBounds(textNode);
      const descriptor = {
        type: "TEXT_NODE",
        text,
        xpath,
        contextPath: [...contextPath],
        bounds,
        isVisible: true,
        isInViewport: bounds ? isInViewport(textNode, -1) : false,
        isInteractive: false,
        isTopElement: false,
        isHighlighted: false,
        children: [],
        attributes: {}
      };
      const id = alohaIdFor(descriptor, null);
      nodeMap[id] = descriptor;
      return id;
    }

    const element = node;
    const tag = element.tagName ? element.tagName.toLowerCase() : "";
    const isSemanticTag = SEMANTIC_STRUCTURE_TAGS.has(tag);

    if (!isElementAccepted(element)) {
      if (DEBUG && isSemanticTag) console.log("[DOM Debug] Semantic tag REJECTED by isElementAccepted:", tag);
      return null;
    }
    if (element.getAttribute("aria-hidden") === "true") {
      if (DEBUG && isSemanticTag) console.log("[DOM Debug] Semantic tag REJECTED by aria-hidden:", tag);
      return null;
    }
    if (element.tagName.toLowerCase() === "code") {
      const style = getComputedStyleCached(element);
      if (style && style.display === "none") return null;
    }
    if (DEBUG && isSemanticTag) console.log("[DOM Debug] Processing semantic tag:", tag);

    let textContent = ("" + (element.textContent || "")).trim();
    try {
      const ariaLabel = element.getAttribute && element.getAttribute("aria-label");
      const ariaLabelledby = getAriaLabelledByText(element);
      const dataTooltip = element.getAttribute && element.getAttribute("data-tooltip");
      const nestedLabels = getNestedAriaLabels(element);
      textContent = [textContent, ariaLabel || "", ariaLabelledby || "", dataTooltip || "", nestedLabels || ""]
        .map((piece) => (piece || "").trim())
        .join(" ");
    } catch {}

    const tagName = element.tagName ? element.tagName.toLowerCase() : "";
    const siblingIndex = getSiblingIndex(element);
    const indexSuffix = siblingIndex > 0 ? `[${siblingIndex}]` : "";
    const xpath = (parentXPath ? `${parentXPath}` : "") + `/${tagName}${indexSuffix}`;
    const descriptor = {
      tagName: element.tagName ? element.tagName.toLowerCase() : null,
      attributes: {},
      xpath,
      contextPath: [...contextPath],
      children: [],
      isInput: false,
      isTextarea: false,
      isSelect: false,
      isOption: false,
      isFileInput: false,
      inputData: null,
      optionData: null,
      isHighlighted: false,
      textContent,
      childText: Array.from(element.childNodes)
        .filter((child) => child.nodeType === Node.TEXT_NODE)
        .map((child) => child.textContent?.trim() || "")
        .join(" ")
        .trim()
    };
    if (isLikelyInteractive(element) || element.tagName.toLowerCase() === "iframe" || element.tagName.toLowerCase() === "body") {
      const attributeNames = element.getAttributeNames?.();
      if (attributeNames)
        for (let i = 0; i < attributeNames.length; i++) {
          const name = attributeNames[i];
          const value = element.getAttribute(name);
          if (value !== null) descriptor.attributes[name] = value;
        }
      try {
        if (!descriptor.attributes["aria-label"] && !element.textContent) {
          const inferred = findDescendantAriaLabel(element);
          if (inferred) descriptor.attributes["aria-label"] = inferred;
        }
      } catch {}
    }

    const lowerTag = element.tagName.toLowerCase();
    if (isTextInput(element)) {
      descriptor.isInput = true;
      descriptor.inputData = extractInputData(element);
    }
    if (isMultilineInput(element)) {
      descriptor.isTextarea = true;
      descriptor.inputData = extractInputData(element);
    }
    if (isSelectElement(element)) {
      descriptor.isSelect = true;
      if (lowerTag === "select") {
        const select = element;
        descriptor.optionData = {
          options: Array.from(select.options || []).map((option) => ({
            value: option.value,
            text: option.textContent || "",
            selected: option.selected
          })),
          multiple: select.multiple || false
        };
      } else
        descriptor.optionData = {
          options: [],
          multiple: element.getAttribute("aria-multiselectable") === "true"
        };
    }
    if (lowerTag === "option") {
      descriptor.isOption = true;
      const option = element;
      descriptor.optionData = {
        value: option.value,
        text: truncateText(element.textContent || ""),
        selected: option.selected
      };
    }
    if (isFileInputLike(element)) descriptor.isFileInput = true;

    let highlighted = false;
    descriptor.isVisible = isElementVisible(element);
    if (descriptor.isVisible) {
      descriptor.isTopElement = isTopElement(element);
      const isFormElement = descriptor.isInput || descriptor.isTextarea || descriptor.isSelect || descriptor.isFileInput;
      const role = element.getAttribute("role");
      const isMenuContainer = role === "menu" || role === "menubar" || role === "listbox";
      const isMenuItem = role === "option" || role === "menuitem" || role === "menuitemcheckbox" || role === "menuitemradio";
      const isToggleRole = role === "switch" || role === "checkbox" || role === "radio";
      const hasCheckedState = element.hasAttribute("aria-checked") || element.hasAttribute("aria-pressed");
      descriptor.isInteractive = isFormElement ? true : isInteractive(element);
      // The genuine actionable signal, captured BEFORE the text-content promotion below. Only
      // truly actionable elements are probed for occlusion: a covered paragraph promoted to
      // "interactive" purely for emission is not something to annotate as "dismiss to interact".
      const genuinelyActionable = descriptor.isInteractive;
      if (descriptor.isInteractive)
        try {
          descriptor.textOfFirstDescendant = getFirstDescendantText(element);
        } catch {}
      attachComprehensiveText(descriptor, element);
      descriptor.textContent = descriptor.comprehensiveText || descriptor.textContent;

      if (!descriptor.isInteractive && (descriptor.comprehensiveText || "").length > 15) {
        const t = element.tagName.toLowerCase();
        if (["span", "li", "h1", "h2", "h3", "h4", "h5", "h6", "button"].includes(t)) descriptor.isInteractive = true;
      }
      if (!descriptor.bounds) {
        const rect = getBoundingRect(element);
        if (rect)
          descriptor.bounds = {
            x: rect.x,
            y: rect.y,
            width: rect.width,
            height: rect.height,
            top: rect.top,
            right: rect.right,
            bottom: rect.bottom,
            left: rect.left
          };
      }
      if (descriptor.isInViewport === void 0) descriptor.isInViewport = isInViewport(element, -1);
      // Independently of the (lenient) isTopElement heuristic, hit-test whether an actionable
      // element is fully covered by something else — a real modal/overlay is typically a sibling
      // of the content, which isTopElement's same-parent leniency would wave through. The probe
      // reports an occluder only when every sampled point (the same geometry the click path uses)
      // is covered, so it never flags an element the click could still reach; the covering element
      // is resolved to a compact reference after the walk (aloha-ids are assigned then).
      // probeOccluder discards points outside the viewport, so no separate in-viewport gate.
      if (genuinelyActionable) {
        const cover = probeOccluder(element);
        if (cover) descriptor.__occluderEl = cover;
      }
      // Capture scroll geometry for any visible element. Unlike occlusion this is NOT gated on
      // actionability: a scroll container is usually a non-interactive div, which is exactly the
      // node that needs the annotation so the agent can target it and read its position.
      const scroll = getScrollDescriptor(element);
      if (scroll) descriptor.scroll = scroll;
      const lacksText = !(descriptor.comprehensiveText || "").trim().length;
      const isInteractiveWithoutText = !!descriptor.isInteractive && lacksText;
      if (descriptor.isTopElement || isFormElement || isMenuContainer || isMenuItem || isToggleRole || hasCheckedState || isInteractiveWithoutText)
        highlighted = maybeHighlightNode(descriptor, element, parentIframe, inheritedHighlight);
      descriptor.isHighlighted = highlighted;
    } else {
      descriptor.isInteractive = false;
      descriptor.isHighlighted = false;
    }

    if (element.tagName) {
      const recurseTag = element.tagName.toLowerCase();
      if (recurseTag === "iframe")
        try {
          const iframe = element;
          const iframeDoc = iframe.contentDocument || iframe.contentWindow?.document;
          if (iframeDoc && iframeDoc.body) {
            let selector = "iframe";
            if (iframe.id) selector = `iframe#${iframe.id}`;
            else if (iframe.src) selector = `iframe[src="${iframe.src.replace(/[^\w-]/g, "\\$&")}"]`;
            else if (iframe.name) selector = `iframe[name="${iframe.name}"]`;
            const childContextPath = [...contextPath, { type: "iframe", selector }];
            for (const child of iframeDoc.body.childNodes) {
              const childId = walkNode(child, iframe, false, childContextPath, "/body");
              if (childId) descriptor.children.push(childId);
            }
          }
        } catch {}
      else if (
        element.isContentEditable ||
        element.getAttribute("contenteditable") === "true" ||
        element.id === "tinymce" ||
        element.classList.contains("mce-content-body") ||
        (recurseTag === "body" && element.getAttribute("data-id")?.startsWith("mce_"))
      )
        for (const child of element.childNodes) {
          const childId = walkNode(child, parentIframe, highlighted, contextPath, xpath);
          if (childId) descriptor.children.push(childId);
        }
      else {
        const el = element;
        if (el.shadowRoot) {
          descriptor.shadowRoot = true;
          const childContextPath = [...contextPath, { type: "shadowRoot", index: 0 }];
          for (const child of el.shadowRoot.childNodes) {
            const childId = walkNode(child, parentIframe, highlighted || inheritedHighlight, childContextPath, xpath);
            if (childId) descriptor.children.push(childId);
          }
        }
        for (const child of element.childNodes) {
          const childId = walkNode(child, parentIframe, highlighted || inheritedHighlight, contextPath, xpath);
          if (childId && !descriptor.children.includes(childId)) descriptor.children.push(childId);
        }
      }
    }

    if (descriptor.tagName === "a" && descriptor.children.length === 0 && !descriptor.attributes.href) {
      const rect = getBoundingRect(element);
      const el = element;
      if (!((rect && rect.width > 0 && rect.height > 0) || el.offsetWidth > 0 || el.offsetHeight > 0)) return null;
    }

    const id = alohaIdFor(descriptor, element);
    nodeMap[id] = descriptor;
    try {
      element.setAttribute("aloha-id", id);
      descriptor.attributes["aloha-id"] = id;
    } catch {}
    if (DEBUG && SEMANTIC_STRUCTURE_TAGS.has(descriptor.tagName || ""))
      console.log("[DOM Debug] Semantic tag ADDED to map:", descriptor.tagName, "id=" + id, "children=" + descriptor.children.length);
    return id;
  }

  // Everywhere the walk can reach, because that is everywhere resolveElement can: it searches the
  // top document, THEN shadow roots, THEN same-origin iframes. An element dropped from a later walk
  // keeps its attribute, and an id the model carries over from an earlier read finds that corpse
  // instead of nothing — a hidden zero-rect node clicked at (0,0) with a success receipt, which is
  // bcb8b75 reached by a second route. Derived ids make it likelier, not rarer: the same markup on
  // two pages of one site hashes to one id.
  clearStaleAlohaIds(document);
  caches.clearCache();
  const rootId = walkNode(document.body);
  // Resolve each occluded node's covering element to a compact reference now that every node
  // has its aloha-id assigned (so the occluder can be named, and made actionable when tracked).
  for (const occId in nodeMap) {
    const occNode = nodeMap[occId];
    if (!occNode || !occNode.__occluderEl) continue;
    const cover = occNode.__occluderEl;
    delete occNode.__occluderEl;
    try {
      const isPageRoot = (el) =>
        !el || el === document.body || el === document.documentElement ||
        ["body", "html", "head", "main"].includes((el.tagName || "").toLowerCase());
      let named = cover;
      for (let hops = 0; named && !isPageRoot(named) && hops < 4; hops++) {
        const identity = named.getAttribute && (named.getAttribute("aloha-id") || named.id || named.getAttribute("aria-label") || named.getAttribute("role"));
        if (identity || (named.textContent || "").trim().length > 0) break;
        named = named.parentElement;
      }
      if (isPageRoot(named)) {
        // Covered by a bare/anonymous overlay that resolves up to the page root — name it
        // generically rather than quoting the entire page's text back to the model.
        occNode.occludedBy = { alohaId: null, tag: "overlay", role: null, text: null };
      } else {
        occNode.occludedBy = {
          alohaId: (named.getAttribute && named.getAttribute("aloha-id")) || null,
          tag: (named.tagName || "").toLowerCase() || "overlay",
          role: (named.getAttribute && named.getAttribute("role")) || null,
          text: ((named.getAttribute && named.getAttribute("aria-label")) || named.textContent || "").trim().slice(0, 60) || null
        };
      }
    } catch {}
  }
  if (DEBUG) {
    const semanticCounts = {};
    for (const id in nodeMap) {
      const descriptor = nodeMap[id];
      if (descriptor && SEMANTIC_STRUCTURE_TAGS.has(descriptor.tagName || ""))
        semanticCounts[descriptor.tagName || "unknown"] = (semanticCounts[descriptor.tagName || "unknown"] || 0) + 1;
    }
    console.log("[DOM Debug] Semantic tags in final map:", semanticCounts);
  }
  return { rootId, map: nodeMap };
};
    const { map } = buildDomTree(\#(collectAllInteractive), \#(debug));

    const debugStats = {
      totalNodes: 0,
      interactiveNodes: 0,
      highlightedNodes: 0,
      excludedNodes: 0,
      visibleNodes: 0,
      inViewportNodes: 0,
      topElementNodes: 0,
      nodesWithText: 0,
      byTagName: {},
      excludedByTag: {},
      interactiveByTag: {}
    };

    const parentOf = new Map();
    for (const id in map) {
      const node = map[id];
      if (!node || !Array.isArray(node.children)) continue;
      for (const childId of node.children) parentOf.set(childId, id);
    }
    const hasHighlightedAncestor = (id) => {
      let p = parentOf.get(id);
      while (p) {
        const n = map[p];
        if (n && n.isHighlighted) return true;
        p = parentOf.get(p);
      }
      return false;
    };

    const SEMANTIC_STRUCTURE_TAGS = new Set([
      'header', 'footer', 'aside', 'main', 'article', 'section', 'nav', 'fieldset'
    ]);

    const excludedNodes = new Set();
    for (const id in map) {
      const nodeData = map[id];
      if (!nodeData) continue;

      const tag = nodeData.tagName || (nodeData.type === 'TEXT_NODE' ? 'text' : 'unknown');

      if (DEBUG) {
        debugStats.totalNodes++;
        debugStats.byTagName[tag] = (debugStats.byTagName[tag] || 0) + 1;
        if (nodeData.isInteractive) {
          debugStats.interactiveNodes++;
          debugStats.interactiveByTag[tag] = (debugStats.interactiveByTag[tag] || 0) + 1;
        }
        if (nodeData.isHighlighted) debugStats.highlightedNodes++;
        if (nodeData.isVisible) debugStats.visibleNodes++;
        if (nodeData.isInViewport) debugStats.inViewportNodes++;
        if (nodeData.isTopElement) debugStats.topElementNodes++;
        if ((nodeData.comprehensiveText || '').trim().length > 0) debugStats.nodesWithText++;
      }

      if (SEMANTIC_STRUCTURE_TAGS.has(tag)) {
        if (DEBUG) {
          console.log('[DOM Debug] Preserving semantic tag:', tag, 'id=' + id);
        }
        continue;
      }

      if (hasHighlightedAncestor(id) && !nodeData.isInteractive) {
        excludedNodes.add(id);
        if (DEBUG) {
          debugStats.excludedNodes++;
          debugStats.excludedByTag[tag] = (debugStats.excludedByTag[tag] || 0) + 1;
        }
      }
    }

    if (DEBUG) {
      console.log('[DOM Debug] Stats:', JSON.stringify(debugStats, null, 2));
      console.log('[DOM Debug] Interactive elements by tag:', debugStats.interactiveByTag);
      console.log('[DOM Debug] Excluded elements by tag:', debugStats.excludedByTag);
    }

    const resolvedChildrenCache = new Map();
    function getResolvedChildren(nodeId) {
      if (resolvedChildrenCache.has(nodeId)) return resolvedChildrenCache.get(nodeId);

      const nodeData = map[nodeId];
      if (!nodeData || !Array.isArray(nodeData.children)) {
        resolvedChildrenCache.set(nodeId, []);
        return [];
      }

      const resolved = [];
      for (const childId of nodeData.children) {
        if (excludedNodes.has(childId)) {

          resolved.push(...getResolvedChildren(childId));
        } else {
          resolved.push(childId);
        }
      }
      resolvedChildrenCache.set(nodeId, resolved);
      return resolved;
    }

    const RESOLVE_CACHE = new Map();
    function calculateDistanceToViewport(bounds) {
      if (!bounds) return Infinity;
      const viewportHeight = window.innerHeight || document.documentElement.clientHeight || 1080;
      if (bounds.top >= 0 && bounds.bottom <= viewportHeight) return 0;
      if (bounds.bottom < 0) return bounds.bottom;
      if (bounds.top > viewportHeight) return bounds.top - viewportHeight;
      return 0;
    }

    function determineViewportBorder(bounds) {
      if (!bounds) return 'none';
      const viewportHeight = window.innerHeight || document.documentElement.clientHeight || 1080;
      if (bounds.bottom < 0) return 'top';
      if (bounds.top > viewportHeight) return 'bottom';
      return 'none';
    }

    const metadata = [];
    for (const id in map) {
      const nodeData = map[id];
      if (!nodeData) continue;

      if (excludedNodes.has(id)) continue;

      const bounds = nodeData.bounds || null;
      const textContent =
        typeof nodeData.textContent === 'string'
          ? nodeData.textContent
          : typeof nodeData.text === 'string'
          ? nodeData.text
          : '';
      const comprehensiveText = nodeData.comprehensiveText
      const hasText = (comprehensiveText || '').trim().length > 0;

      const isFormElement = !!(nodeData.isInput || nodeData.isTextarea || nodeData.isSelect || nodeData.isFileInput);
      const isClickable = !!nodeData.isInteractive;

      const distanceToViewportBorder = calculateDistanceToViewport(bounds);
      const viewportBorder = determineViewportBorder(bounds);

      const children = getResolvedChildren(id);

      const tagName = nodeData.tagName || (nodeData.type === 'TEXT_NODE' ? 'text' : 'unknown');
      const href = (nodeData.attributes && nodeData.attributes.href) || '';
      metadata.push({
        nodeType: nodeData.type || 'ELEMENT_NODE',
        id: id,
        children,
        element: {
          tagName,
          xpath: nodeData.xpath || '',
          attributes: nodeData.attributes || {},
          href,
          textContent,
          childText: nodeData.childText || ''
        },
        positioning: {
          bounds,
          distanceToViewportBorder,
          viewportBorder,
          isInViewport: !!nodeData.isInViewport,
          isVisible: !!nodeData.isVisible,
          scroll: nodeData.scroll || null
        },
        interactivity: {
          isClickable,
          isInput: !!nodeData.isInput,
          isFormElement,
          isTextarea: !!nodeData.isTextarea,
          isSelect: !!nodeData.isSelect,
          isFileInput: !!nodeData.isFileInput,
          isTopElement: !!nodeData.isTopElement,
          isInteractive: !!nodeData.isInteractive,
          isHighlighted: !!nodeData.isHighlighted,
          occludedBy: nodeData.occludedBy || null
        },
        content: {
          hasText,
          textOfFirstDescendant: nodeData.textOfFirstDescendant || '',
          inputData: nodeData.inputData || null,
          optionData: nodeData.optionData || null,
          comprehensiveText: comprehensiveText || ''
        }
      });
    }

    if (DEBUG) {
      const interactiveElements = metadata.filter(m => m.interactivity.isInteractive);
      const highlightedElements = metadata.filter(m => m.interactivity.isHighlighted);
      const visibleElements = metadata.filter(m => m.positioning.isVisible);

      console.log('[DOM Debug] Final metadata summary:');
      console.log('  - Total metadata entries:', metadata.length);
      console.log('  - Interactive elements:', interactiveElements.length);
      console.log('  - Highlighted elements:', highlightedElements.length);
      console.log('  - Visible elements:', visibleElements.length);

      console.log('[DOM Debug] Sample interactive elements:');
      interactiveElements.slice(0, 10).forEach(el => {
        console.log('  -', el.element.tagName, 'id=' + el.id, 'text="' + (el.content.comprehensiveText || '').slice(0, 50) + '"',
          'visible=' + el.positioning.isVisible, 'inViewport=' + el.positioning.isInViewport,
          'isTop=' + el.interactivity.isTopElement, 'highlighted=' + el.interactivity.isHighlighted);
      });

      const buttons = metadata.filter(m => m.element.tagName === 'button');
      console.log('[DOM Debug] Buttons found:', buttons.length);
      buttons.slice(0, 5).forEach(el => {
        console.log('  - Button id=' + el.id, 'interactive=' + el.interactivity.isInteractive,
          'text="' + (el.content.comprehensiveText || '').slice(0, 30) + '"',
          'visible=' + el.positioning.isVisible, 'highlighted=' + el.interactivity.isHighlighted);
      });

      const links = metadata.filter(m => m.element.tagName === 'a');
      console.log('[DOM Debug] Links found:', links.length);
      links.slice(0, 5).forEach(el => {
        console.log('  - Link id=' + el.id, 'interactive=' + el.interactivity.isInteractive,
          'href="' + (el.element.href || '').slice(0, 30) + '"',
          'text="' + (el.content.comprehensiveText || '').slice(0, 30) + '"');
      });
    }

    return metadata;
  })()
"""#
}
