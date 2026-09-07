import Foundation
import ToolABI

// MARK: - Browser tab abstraction

/// A rectangle on the page, in viewport coordinates.
public nonisolated struct ElementBounds: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var top: Double
    public var right: Double
    public var bottom: Double
    public var left: Double

    public init(x: Double, y: Double, width: Double, height: Double, top: Double, right: Double, bottom: Double, left: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.top = top
        self.right = right
        self.bottom = bottom
        self.left = left
    }

    /// `nil` unless all eight numeric fields are present.
    public init?(json: JSValue) {
        guard let x = json.number("x"), let y = json.number("y"),
              let width = json.number("width"), let height = json.number("height"),
              let top = json.number("top"), let right = json.number("right"),
              let bottom = json.number("bottom"), let left = json.number("left") else {
            return nil
        }
        self.init(x: x, y: y, width: width, height: height, top: top, right: right, bottom: bottom, left: left)
    }
}

/// A CDP-style debugger the service drives to dispatch synthetic input and DOM
/// commands. Implemented by the native shell.
public protocol TabDebugger: Sendable {
    nonisolated func simulateMouseClick(_ x: Int, _ y: Int, _ button: String, _ count: Int, _ signal: AbortSignal?) async throws
    /// Sends a raw CDP command in `domain.method` form with JSON `params`.
    @discardableResult
    nonisolated func sendCommand(_ domain: String, _ method: String, _ params: JSValue) async throws -> JSValue
}

/// The renderable layer backing a tab. Implemented by the native shell.
public protocol TabLayer: Sendable {
    nonisolated func executeJavaScript(_ script: String) async throws -> JSValue
    nonisolated func isDestroyed() -> Bool
}

/// The current agent cursor position, when known.
public nonisolated struct AgentMousePosition: Equatable, Sendable {
    public var x: Double?
    public var y: Double?
    public init(x: Double?, y: Double?) {
        self.x = x
        self.y = y
    }
}

public nonisolated struct ViewportCaptureMetadata: Sendable {
    public var base64: String
    public var imageWidth: Int
    public var imageHeight: Int
    public init(base64: String, imageWidth: Int, imageHeight: Int) {
        self.base64 = base64
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
    }
}

/// The browser tab the service operates on. Implemented by the native shell;
/// this boundary keeps all DOM/interaction logic platform-independent.
public protocol BrowserTab: AnyObject, Sendable {
    nonisolated var id: String { get }
    nonisolated var layer: TabLayer { get }
    nonisolated func getLayer() -> TabLayer
    nonisolated func getAgentMousePosition() -> AgentMousePosition?
    nonisolated func waitForNextAnimationFrames(_ count: Int) async throws
    nonisolated func getViewportBase64() async throws -> String?
    nonisolated func getViewportBase64WithMetadata(_ format: String?, _ scale: Double) async throws -> ViewportCaptureMetadata?
}

/// Animates the agent cursor toward `bounds` and performs a click flourish.
/// Supplied by the native shell.
public protocol AgentCursorAnimator: Sendable {
    nonisolated func animateAgentCursorClick(_ tab: BrowserTab, _ bounds: ElementBounds, _ label: String, scaleOnClick: Bool, cursorLabelKind: String?) async
}

/// Factory for a tab's debugger. Supplied by the native shell.
public protocol TabDebuggerFactory: Sendable {
    nonisolated func makeDebugger(_ tab: BrowserTab) -> TabDebugger
}

/// Builds the page-side DOM-extraction script. Supplied by the native shell.
public protocol DomTreeScriptProvider: Sendable {
    nonisolated func buildDomTreeScript(highlight: Bool, focusInteractive: Bool) -> String
}

// MARK: - Options & result types

public nonisolated struct ClickElementOptions: Sendable {
    public var doubleClick: Bool?
    public var rightClick: Bool?
    public var tripleClick: Bool?
    public var signal: AbortSignal?
    public var cursorLabelKind: String?

    public init(doubleClick: Bool? = nil, rightClick: Bool? = nil, tripleClick: Bool? = nil, signal: AbortSignal? = nil, cursorLabelKind: String? = nil) {
        self.doubleClick = doubleClick
        self.rightClick = rightClick
        self.tripleClick = tripleClick
        self.signal = signal
        self.cursorLabelKind = cursorLabelKind
    }
}

public nonisolated struct ClickResult: Sendable {
    public var isOnTop: Bool
    public var message: String
    public var element: DomNode?
    public init(isOnTop: Bool, message: String, element: DomNode?) {
        self.isOnTop = isOnTop
        self.message = message
        self.element = element
    }
}

/// The result of an absolute-coordinate click.
public nonisolated struct ClickAtResult: Equatable, Sendable {
    public var success: Bool
    public var message: String
    public init(success: Bool, message: String) {
        self.success = success
        self.message = message
    }
}

public nonisolated struct ClickablePoint: Sendable {
    public var isClickable: Bool
    public var x: Double?
    public var y: Double?
    public var location: String?
    public var coveringElement: String?
    public init(isClickable: Bool, x: Double? = nil, y: Double? = nil, location: String? = nil, coveringElement: String? = nil) {
        self.isClickable = isClickable
        self.x = x
        self.y = y
        self.location = location
        self.coveringElement = coveringElement
    }
}

public nonisolated struct FocusResult: Equatable, Sendable {
    public var success: Bool
    public var message: String
    public init(success: Bool, message: String) {
        self.success = success
        self.message = message
    }
}

public nonisolated struct ScrollToElementOptions: Sendable {
    public var returnBounds: Bool
    public var force: Bool
    public var signal: AbortSignal?
    public init(returnBounds: Bool = false, force: Bool = false, signal: AbortSignal? = nil) {
        self.returnBounds = returnBounds
        self.force = force
        self.signal = signal
    }
}

public nonisolated struct ScrollToElementResult: Sendable {
    public var message: String
    public var scrollDistance: Double
    public var bounds: ElementBounds??
    public init(message: String, scrollDistance: Double, bounds: ElementBounds?? = nil) {
        self.message = message
        self.scrollDistance = scrollDistance
        self.bounds = bounds
    }
}

public nonisolated struct ClickableXYDecision: Sendable {
    public var shouldFallback: Bool
    public init(shouldFallback: Bool) { self.shouldFallback = shouldFallback }
}

public nonisolated struct KeyStroke: Sendable {
    public var key: String
    public var modifiers: [String]
    public init(key: String, modifiers: [String] = []) {
        self.key = key
        self.modifiers = modifiers
    }
}

public nonisolated struct InteractMarkdownDiagnostics: Sendable {
    public var domElementCount: Int
    public var markdownLength: Int
    public var tokenCount: Int
    public var totalTimeMs: Double
    public var domExtractionTimeMs: Double
    public var serializationTimeMs: Double
    public var screenshotTimeMs: Double
    public var domError: String?
    public var serializeError: String?
    public var screenshotError: String?
}

public nonisolated struct InteractMarkdownResult: Sendable {
    public var markdown: String
    public var screenshot: String?
    public var diagnostics: InteractMarkdownDiagnostics
}

// MARK: - AgentDOMService

/// Drives DOM inspection and synthetic interaction on a single browser tab.
///
/// The service caches an extracted DOM tree, resolves elements by id (with a
/// short-prefix fallback), computes clickable points, performs click/focus/
/// upload/keystroke actions with CDP and DOM fallbacks, and renders the tab to
/// markdown. Cancellation flows through an ``AbortSignal`` honored at every
/// suspension point.
public final class AgentDOMService {
    /// How long the read id-box overlay is held on screen after a snapshot is
    /// serialized, so a read is visible rather than an imperceptible flash.
    static let readHighlightLingerNanos: UInt64 = 900_000_000

    public let tab: BrowserTab
    private let debuggerInstance: TabDebugger
    private let cursorAnimator: AgentCursorAnimator
    private let domScriptProvider: DomTreeScriptProvider

    public private(set) var dom: [DomNode] = []
    /// The raw JSON form of the most recent DOM, used for bounds fallbacks.
    private var domRaw: [JSValue] = []

    // MARK: Sealed regions
    //
    // The walker runs as injected page JavaScript and so inherits page JavaScript's
    // limits exactly: a cross-origin frame's document reads back null, and a closed
    // shadow root reads back null, both silently. Whole subtrees therefore vanish from
    // the element list, indistinguishable from empty space. Only the browser protocol
    // can see past either boundary, and only the agent runtime speaks it — hence this
    // one injected folding seam rather than more code in here.

    /// Given the nodes the walker produced, returns the list with regions the walker
    /// was forbidden to read folded in — marked in place where the walker at least saw
    /// the frame, appended where it could not know one existed.
    public var sealedRegionProvider: (([DomNode]) async -> [DomNode])?

    private let isDevEnvironment: Bool

    public init(
        tab: BrowserTab,
        debuggerFactory: TabDebuggerFactory,
        cursorAnimator: AgentCursorAnimator,
        domScriptProvider: DomTreeScriptProvider,
        isDevEnvironment: Bool = false
    ) {
        self.tab = tab
        self.debuggerInstance = debuggerFactory.makeDebugger(tab)
        self.cursorAnimator = cursorAnimator
        self.domScriptProvider = domScriptProvider
        self.isDevEnvironment = isDevEnvironment
    }

    // MARK: Abort helpers

    public func throwIfAborted(_ signal: AbortSignal?) throws {
        if signal?.aborted == true { throw AbortSignalError("Operation aborted") }
    }

    public func isAbortError(_ error: Error) -> Bool {
        if error is AbortSignalError { return true }
        if let named = error as? NamedError, named.name == "AbortError" { return true }
        return false
    }

    /// Waits `ms` milliseconds, resolving early (by throwing) if `signal` aborts.
    public func abortableDelay(_ ms: Int, _ signal: AbortSignal?) async throws {
        try throwIfAborted(signal)
        guard let signal else {
            try await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
            return
        }
        try await raceAbort(signal) {
            try await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
        }
    }

    /// Runs `operation`, racing it against an abort. Throws if `signal` is
    /// already aborted, or once it aborts before `operation` completes.
    public func raceAbort<T: Sendable>(_ signal: AbortSignal?, _ operation: @Sendable @escaping () async throws -> T) async throws -> T {
        try throwIfAborted(signal)
        guard let signal else { return try await operation() }
        let waiter = AbortWaiter<T>(signal: signal)
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask { try await waiter.wait() }
            defer {
                waiter.cancel()
                group.cancelAll()
            }
            guard let result = try await group.next() else {
                throw AbortSignalError("Operation aborted")
            }
            return result
        }
    }

    private func executeJavaScript(_ script: String, _ signal: AbortSignal?) async throws -> JSValue {
        let layer = tab.layer
        return try await raceAbort(signal) { try await layer.executeJavaScript(script) }
    }

    public func getDebugger() -> TabDebugger { debuggerInstance }

    // MARK: Script builders

    public func buildFindElementGlobalScript(_ selectorExpression: String) -> String {
        return """

              const selector = \(selectorExpression);

              function findInShadow(root, selector) {
                const el = root.querySelector(selector);
                if (el) return el;
                for (const child of root.querySelectorAll('*')) {
                  if (child.shadowRoot) {
                    const found = findInShadow(child.shadowRoot, selector);
                    if (found) return found;
                  }
                }
                return null;
              }

              function findElementGlobal(selector, root = document, parentIframe = null) {
                const el = findInShadow(root, selector);
                if (el) return { element: el, parentIframe };

                const iframes = root.querySelectorAll('iframe');
                for (const frame of iframes) {
                  try {
                    if (frame.contentDocument) {
                      const found = findElementGlobal(selector, frame.contentDocument, frame);
                      if (found.element) return found;
                    }
                  } catch (_) {
                  }
                }

                return { element: null, parentIframe: null };
              }
        """
    }

    // MARK: DOM extraction

    /// Caches both the typed and raw forms. Nothing is written to disk: an earlier build
    /// dumped the raw DOM to `dom.json`, which put page content somewhere nobody asked for it.
    @discardableResult
    public func getDOM(highlight: Bool = true, focusInteractive: Bool = false, signal: AbortSignal? = nil) async throws -> [DomNode] {
        try throwIfAborted(signal)
        let script = domScriptProvider.buildDomTreeScript(highlight: highlight, focusInteractive: focusInteractive)
        let layer = tab.layer
        let result = try await raceAbort(signal) { try await layer.executeJavaScript(script) }
        try throwIfAborted(signal)
        domRaw = result.arrayValue ?? []
        dom = domRaw.compactMap { parseDomNode($0) }
        // Fold in the regions page JavaScript was forbidden to read, so an unreadable
        // part of the page is LEGIBLE rather than absent. `domRaw` is deliberately left
        // alone: it exists only as a bounds fallback keyed by id, and a sealed region
        // has no raw entry to fall back to by construction.
        if let sealedRegionProvider {
            try throwIfAborted(signal)
            dom = await sealedRegionProvider(dom)
        }
        return dom
    }

    /// Returns the cached DOM, extracting it (without highlighting) when empty.
    public func ensureDomCache(_ signal: AbortSignal?) async throws -> [DomNode] {
        if !dom.isEmpty { return dom }
        return try await getDOM(highlight: false, focusInteractive: false, signal: signal)
    }

    // MARK: Bounds

    /// Scrolls the element with `alohaId` into view (when offscreen), optionally
    /// adds a debug glow, and returns its bounds.
    public func evalFindElementBounds(alohaId: String?, addDebugGlow: Bool = true, signal: AbortSignal?) async throws -> ElementBounds? {
        let selector = (alohaId?.isEmpty == false) ? "[aloha-id=\"\(alohaId!)\"]" : ""
        let elementExpression = selector.isEmpty ? "null" : "document.querySelector('\(selector)')"
        let glowBlock = addDebugGlow ? """

              try {
                el.style.outline = '2px solid rgba(255,0,255,0.8)';
                el.style.outlineOffset = '2px';
                setTimeout(() => { try { el.style.outline = ''; el.style.outlineOffset=''; } catch{} }, 1200);
              } catch {}

        """ : ""
        let script = """
        (() => {
              function boundsFor(el) {
                if (!el) return null;
                const r = el.getBoundingClientRect();
                return { x: r.x, y: r.y, width: r.width, height: r.height, top: r.top, right: r.right, bottom: r.bottom, left: r.left };
              }
              const el = \(elementExpression);
              if (!el) return null;
              try {
                const r = el.getBoundingClientRect();
                const vh = window.innerHeight || document.documentElement.clientHeight || 0;
                const vw = window.innerWidth || document.documentElement.clientWidth || 0;
                const isInViewport = r.top >= 0 && r.left >= 0 && r.bottom <= vh && r.right <= vw && r.height > 0 && r.width > 0;
                if (!isInViewport) {
                  el.scrollIntoView({ behavior: 'smooth', block: 'center' });
                }
              } catch {}
              \(glowBlock)
              return boundsFor(el);
            })()
        """
        let layer = tab.layer
        let result = try await raceAbort(signal) { try await layer.executeJavaScript(script) }
        if case .object = result { return ElementBounds(json: result) }
        return nil
    }

    public func scrollIntoViewAndGetBounds(_ id: String, _ signal: AbortSignal?) async throws -> ElementBounds? {
        guard let node = try await findElementById(id, signal) else { return nil }
        let alohaId = node.element.attributes["aloha-id"]
        return try await evalFindElementBounds(alohaId: alohaId, signal: signal)
    }

    public func getCurrentElementBounds(_ id: String, _ signal: AbortSignal?) async throws -> ElementBounds? {
        try await scrollIntoViewAndGetBounds(id, signal)
    }

    // MARK: Clickability self-check

    /// Asks the page whether a DOM-level click fallback should be preferred for
    /// the element with `alohaId`.
    public func checkElementClickableXY(_ alohaId: String) async throws -> ClickableXYDecision {
        let script = """

              (async () => {
                async function shouldFallbackToDOMClick(element) {
                  const checks = {
                      boundingBoxAccuracy: false,
                      cssTransformIssues: false,
                      zoomIssues: false,
                      viewportIssues: false,
                      overlayDetection: false
                  };

                  const rect = element.getBoundingClientRect();
                  const centerX = rect.left + rect.width / 2;
                  const centerY = rect.top + rect.height / 2;

                  const shouldFallback = Object.values(checks).some(check => check);

                  return {
                      shouldFallback,
                      reasons: checks,
                      coordinates: { x: centerX, y: centerY }
                  };
                }

                const element = document.querySelector('[aloha-id="\(alohaId)"]')
                if (element) {
                  return await shouldFallbackToDOMClick(element)
                }
                return { shouldFallback: false, reasons: {}, coordinates: { x: 0, y: 0 } }
              })()

        """
        let result = try await tab.layer.executeJavaScript(script)
        if case .object = result {
            return ClickableXYDecision(shouldFallback: result.bool("shouldFallback") ?? false)
        }
        return ClickableXYDecision(shouldFallback: false)
    }

    // MARK: Clicking

    /// Clicks the element with `id`, animating the cursor and choosing between a
    /// CDP coordinate click and a shadow-aware DOM click depending on
    /// clickability and editor heuristics.
    public func clickElement(_ id: String, _ label: String?, _ options: ClickElementOptions = ClickElementOptions()) async throws -> ClickResult {
        let prefix = "[ClickElement]"
        let signal = options.signal
        try throwIfAborted(signal)
        guard let node = try await findElementById(id, signal) else {
            return ClickResult(isOnTop: false, message: "Element \(id) not found", element: nil)
        }
        let scroll = try await scrollToElement(id, label ?? "Agent", ScrollToElementOptions(returnBounds: true, signal: signal))
        try throwIfAborted(signal)
        guard let bounds = scroll.bounds ?? nil else {
            return ClickResult(isOnTop: false, message: "Element \(id) not found", element: node)
        }
        let point = try await findClickablePoint(id, signal)
        try throwIfAborted(signal)
        rootLogger.info("\(prefix) findClickablePoint: isClickable=\(point.isClickable), location=\(point.location ?? "nil"), coords=(\(point.x.map { String($0) } ?? "nil"), \(point.y.map { String($0) } ?? "nil")), coveringElement=\(point.coveringElement ?? "none")")

        let escapedId = id.replacingOccurrences(of: "\"", with: "\\\"")
        let domClickScript = """

                (() => {
                  const selector = '[aloha-id="\(escapedId)"]';

                  function findInShadow(root, selector) {
                    const direct = root.querySelector(selector);
                    if (direct) return { element: direct, rootType: 'document' };
                    for (const child of root.querySelectorAll('*')) {
                      if (child.shadowRoot) {
                        const found = findInShadow(child.shadowRoot, selector);
                        if (found.element) return { element: found.element, rootType: 'shadow' };
                      }
                    }
                    return { element: null, rootType: 'none' };
                  }

                  const found = findInShadow(document, selector);
                  if (!found.element) {
                    return { clicked: false, found: false, rootType: 'none' };
                  }

                  found.element.click();
                  if (found.element.getAttribute('contenteditable') === 'true' || found.element.isContentEditable) {
                    found.element.focus();
                  }
                  return { clicked: true, found: true, rootType: found.rootType };
                })()

        """

        func performDomClick() async throws -> JSValue {
            try await executeJavaScript(domClickScript, signal)
        }

        if !point.isClickable {
            rootLogger.info("\(prefix) PATH: dom_fallback_fully_covered → element covered by \"\(point.coveringElement ?? "unknown")\", trying DOM click (shadow-aware) first")
            await cursorAnimator.animateAgentCursorClick(tab, bounds, "\(label ?? "")", scaleOnClick: true, cursorLabelKind: options.cursorLabelKind)
            try await abortableDelay(50, signal)
            let domResult = try await performDomClick()
            try throwIfAborted(signal)
            let clicked = domResult.bool("clicked") ?? false
            rootLogger.info("\(prefix) dom fallback result: clicked=\(clicked), found=\(domResult.bool("found") ?? false), rootType=\(domResult.string("rootType") ?? "")")
            if !clicked {
                return try await cdpFallbackClick(prefix, id, bounds, node, options, signal, pathTag: "dom_fallback_missing_target")
            }
            return ClickResult(isOnTop: true, message: "Clicked element \(id) (DOM fallback via \(domResult.string("rootType") ?? "") root)", element: node)
        }

        let decision = try await checkElementClickableXY(id)
        let isContentEditable = node.element.attributes["contenteditable"] == "true"
        if decision.shouldFallback || isContentEditable {
            let devLabel = isDevEnvironment ? "\(label ?? "") (fallback - this text is only in dev)" : "\(label ?? "")"
            await cursorAnimator.animateAgentCursorClick(tab, bounds, devLabel, scaleOnClick: true, cursorLabelKind: options.cursorLabelKind)
            try await abortableDelay(50, signal)
            let domResult = try await performDomClick()
            try throwIfAborted(signal)
            if !(domResult.bool("clicked") ?? false) {
                return try await cdpFallbackClick(prefix, id, bounds, node, options, signal, pathTag: "recommended_dom_fallback_missing_target")
            }
            return ClickResult(isOnTop: true, message: "Clicked element \(id)", element: node)
        }

        let clickX = Int(point.x!.rounded())
        let clickY = Int(point.y!.rounded())
        await cursorAnimator.animateAgentCursorClick(tab, bounds, label ?? "", scaleOnClick: true, cursorLabelKind: options.cursorLabelKind)
        try await abortableDelay(50, signal)
        do {
            let button = options.rightClick == true ? "right" : "left"
            var count = 1
            if options.doubleClick == true { count = 2 }
            if options.tripleClick == true { count = 3 }
            try await debuggerInstance.simulateMouseClick(clickX, clickY, button, count, signal)
            try throwIfAborted(signal)
            if node.element.attributes["contenteditable"] == "true" {
                let focusScript = """

                      (() => {
                        const el = document.querySelector('[aloha-id="\(escapedId)"]');
                        if (el && (el.getAttribute('contenteditable') === 'true' || el.isContentEditable)) {
                          const isFocused = document.activeElement === el || el.contains(document.activeElement);
                          if (!isFocused) {
                            el.focus();
                          }
                        }
                      })()

                """
                _ = try await executeJavaScript(focusScript, signal)
            }
            return ClickResult(isOnTop: true, message: "Clicked element \(id)", element: node)
        } catch {
            if isAbortError(error) { throw error }
            rootLogger.info("\(prefix) PATH: xy_debugger_click_failed → id=\"\(id)\", error=\(describeError(error))")
            return ClickResult(isOnTop: false, message: "Failed to click element \(id)", element: node)
        }
    }

    private func cdpFallbackClick(
        _ prefix: String,
        _ id: String,
        _ bounds: ElementBounds,
        _ node: DomNode,
        _ options: ClickElementOptions,
        _ signal: AbortSignal?,
        pathTag: String
    ) async throws -> ClickResult {
        let x = Int((bounds.left + bounds.width / 2).rounded())
        let y = Int((bounds.top + bounds.height / 2).rounded())
        let button = options.rightClick == true ? "right" : "left"
        var count = 1
        if options.doubleClick == true { count = 2 }
        if options.tripleClick == true { count = 3 }
        rootLogger.info("\(prefix) PATH: \(pathTag) → trying CDP fallback at (\(x), \(y))")
        do {
            try await debuggerInstance.simulateMouseClick(x, y, button, count, signal)
            return ClickResult(isOnTop: true, message: "Clicked element \(id) (CDP fallback at \(x),\(y) after DOM fallback target missing)", element: node)
        } catch {
            if isAbortError(error) { throw error }
            return ClickResult(isOnTop: false, message: "Failed to click element \(id): DOM fallback could not find element and CDP fallback failed", element: node)
        }
    }

    /// Clicks at absolute viewport coordinates, animating the cursor first. An
    /// abort propagates; any other failure is captured in the result.
    public func clickAtAbsolute(_ x: Double, _ y: Double, _ label: String, _ options: ClickElementOptions = ClickElementOptions()) async throws -> ClickAtResult {
        let signal = options.signal
        do {
            try throwIfAborted(signal)
            let bounds = ElementBounds(
                x: Double(max(0, Int((x - 1).rounded()))),
                y: Double(max(0, Int((y - 1).rounded()))),
                width: 2,
                height: 2,
                top: Double(max(0, Int((y - 1).rounded()))),
                right: Double(max(0, Int((x + 1).rounded()))),
                bottom: Double(max(0, Int((y + 1).rounded()))),
                left: Double(max(0, Int((x - 1).rounded())))
            )
            await cursorAnimator.animateAgentCursorClick(tab, bounds, label, scaleOnClick: true, cursorLabelKind: options.cursorLabelKind)
            try await abortableDelay(50, signal)
            let button = options.rightClick == true ? "right" : "left"
            var count = 1
            if options.doubleClick == true { count = 2 }
            if options.tripleClick == true { count = 3 }
            try await debuggerInstance.simulateMouseClick(Int(x.rounded()), Int(y.rounded()), button, count, signal)
            return ClickAtResult(success: true, message: "Clicked at absolute coordinates")
        } catch {
            if isAbortError(error) { throw error }
            return ClickAtResult(success: false, message: "Failed to click at absolute coordinates: \(describeError(error))")
        }
    }

    /// Clicks at the agent's current cursor position, failing when none is set.
    public func clickAtCurrentCursorPosition(_ label: String, _ options: ClickElementOptions = ClickElementOptions()) async throws -> ClickAtResult {
        guard let position = tab.getAgentMousePosition(), let x = position.x, let y = position.y else {
            return ClickAtResult(success: false, message: "No cursor position available. The agent must hover over an element first before clicking at the cursor position.")
        }
        return try await clickAtAbsolute(x, y, label, options)
    }

    // MARK: Select

    /// Selects (or toggles, for multi-selects) the option at `index` on the
    /// select element with `id`.
    public func selectOption(_ id: String, _ index: Int, _ signal: AbortSignal?) async throws -> Bool {
        do {
            try throwIfAborted(signal)
            let selectBounds = try await scrollIntoViewAndGetBounds(id, signal)
            await animateCursorToBounds(selectBounds, "Select")
            try throwIfAborted(signal)
            guard let node = try await findElementById(id, signal) else {
                throw SimpleError("Could not find element with id: \(id)")
            }
            guard let optionData = node.content.optionData, !optionData.options.isEmpty else {
                throw SimpleError("Element is not a select element or has no options")
            }
            if index < 0 || index >= optionData.options.count {
                throw SimpleError("Option index \(index) is out of range (0-\(optionData.options.count - 1))")
            }
            guard let alohaId = node.element.attributes["aloha-id"] else {
                throw SimpleError("Element missing internal id to select in the page")
            }
            let alohaIdJson = JSValue.string(alohaId).stringify()
            let isMulti = optionData.multiple ? "true" : "false"
            let finder = buildFindElementGlobalScript("'[aloha-id=\"' + \(alohaIdJson).replace(/\"/g, '\\\"') + '\"]'")
            let script = """

                    (function() {
                      try {
                        \(finder)

                        const { element: selectElement } = findElementGlobal(selector, document);
                        if (!selectElement) return { success: false, error: 'Select element not found' };
                        const idx = \(index);
                        const isMulti = \(isMulti);
                        const options = selectElement && selectElement.options ? Array.from(selectElement.options) : [];
                        const opt = options[idx];
                        if (!opt) return { success: false, error: 'Option not found at index' };
                        if (isMulti) {
                          opt.selected = !opt.selected;
                        } else {
                          selectElement.value = opt.value;
                        }
                        const view = selectElement.ownerDocument && selectElement.ownerDocument.defaultView
                          ? selectElement.ownerDocument.defaultView
                          : window;
                        selectElement.dispatchEvent(new view.Event('input', { bubbles: true }));
                        selectElement.dispatchEvent(new view.Event('change', { bubbles: true }));
                        return { success: true };
                      } catch (e) {
                        return { success: false, error: String(e && e.message ? e.message : e) };
                      }
                    })();

            """
            let layer = tab.getLayer()
            let result = try await raceAbort(signal) { try await layer.executeJavaScript(script) }
            if result.bool("success") == true { return true }
            throw SimpleError(result.string("error") ?? "Selection failed")
        } catch {
            if isAbortError(error) { throw error }
            return false
        }
    }

    // MARK: Focus

    /// Focuses the element with `id`, falling back to pointer activation for
    /// rich-text editors when programmatic focus fails.
    public func focusElement(_ id: String, _ signal: AbortSignal?) async throws -> FocusResult {
        do {
            try throwIfAborted(signal)
            _ = try await scrollIntoViewAndGetBounds(id, signal)
            try throwIfAborted(signal)
            guard let node = try await findElementById(id, signal) else {
                return FocusResult(success: false, message: "Element \(id) not found")
            }
            guard let alohaId = node.element.attributes["aloha-id"] else {
                return FocusResult(success: false, message: "Element \(id) is missing aloha-id")
            }
            let alohaIdJson = JSValue.string(alohaId).stringify()
            let finder = buildFindElementGlobalScript("'[aloha-id=\"' + \(alohaIdJson).replace(/\"/g, '\\\"') + '\"]'")
            let script = """

                    (function() {
                      \(finder)

                      const { element: el } = findElementGlobal(selector, document);
                      if (!el) return { success: false, error: 'Element not found with aloha-id' };
                      el.scrollIntoView({ block: 'center', behavior: 'instant' });
                      const hadTabIndex = el.hasAttribute('tabindex');
                      const oldTabIndex = el.getAttribute('tabindex');
                      function isFocused() {
                        return document.activeElement === el || el.contains(document.activeElement);
                      }
                      el.focus();
                      if (!isFocused()) {
                        el.setAttribute('tabindex', '-1');
                        el.focus();
                      }
                      const focused = isFocused();
                      if (!hadTabIndex) el.removeAttribute('tabindex');
                      else el.setAttribute('tabindex', oldTabIndex);
                      if (!focused) return { success: false, error: 'Failed to focus element' };
                      return { success: true };
                    })();

            """
            let layer = tab.getLayer()
            let result = try await raceAbort(signal) { try await layer.executeJavaScript(script) }
            if result.bool("success") == true {
                return FocusResult(success: true, message: "Focused element \(id)")
            }
            if shouldUsePointerActivationForFocus(node) {
                let activation = try await activateElementWithPointer(id, node, signal)
                if activation.success {
                    return FocusResult(success: true, message: "Focused element \(id) with pointer activation")
                }
                let primary = result.string("error") ?? "Failed to focus element \(id)"
                return FocusResult(success: false, message: "\(primary); \(activation.message)")
            }
            return FocusResult(success: false, message: result.string("error") ?? "Failed to focus element \(id)")
        } catch {
            if isAbortError(error) { throw error }
            return FocusResult(success: false, message: "Failed to focus element \(id): \(describeError(error))")
        }
    }

    /// Whether an element should be focused via a pointer click rather than
    /// `.focus()` (rich-text editors and contenteditable surfaces).
    public func shouldUsePointerActivationForFocus(_ node: DomNode) -> Bool {
        let attributes = node.element.attributes
        let className = (attributes["class"] ?? "").lowercased()
        let role = (attributes["role"] ?? "").lowercased()
        let contentEditable = (attributes["contenteditable"] ?? "").lowercased()
        let ariaMultiline = (attributes["aria-multiline"] ?? "").lowercased()
        if contentEditable == "true"
            || attributes["data-slate-editor"] == "true"
            || (role == "textbox" && ariaMultiline == "true") {
            return true
        }
        return className.contains("ql-editor")
            || className.contains("prosemirror")
            || className.contains("cm-editor")
            || className.contains("codemirror")
    }

    /// Activates an element by computing a click point and dispatching a CDP
    /// click, falling back to the element's bounds center when no clickable
    /// point exists.
    public func activateElementWithPointer(_ id: String, _ node: DomNode, _ signal: AbortSignal?) async throws -> FocusResult {
        try throwIfAborted(signal)
        let point = try await findClickablePoint(id, signal)
        try throwIfAborted(signal)
        var x = point.x
        var y = point.y
        var bounds = try await getCurrentElementBounds(id, signal)
        if !point.isClickable || x == nil || y == nil {
            bounds = bounds ?? positioningBounds(for: id)
            guard let resolved = bounds else {
                return FocusResult(success: false, message: "Pointer activation failed: element has no bounds")
            }
            x = resolved.left + resolved.width / 2
            y = resolved.top + resolved.height / 2
        }
        let animateBounds = bounds ?? boundsAroundPoint(x!, y!)
        await cursorAnimator.animateAgentCursorClick(tab, animateBounds, "Focus", scaleOnClick: true, cursorLabelKind: nil)
        try await abortableDelay(50, signal)
        do {
            try await debuggerInstance.simulateMouseClick(Int(x!.rounded()), Int(y!.rounded()), "left", 1, signal)
            try await abortableDelay(80, signal)
            return FocusResult(success: true, message: "Pointer activation succeeded")
        } catch {
            if isAbortError(error) { throw error }
            return FocusResult(success: false, message: "Pointer activation failed: \(describeError(error))")
        }
    }

    public func boundsAroundPoint(_ x: Double, _ y: Double) -> ElementBounds {
        let left = Double(max(0, Int((x - 1).rounded())))
        let top = Double(max(0, Int((y - 1).rounded())))
        return ElementBounds(
            x: left,
            y: top,
            width: 2,
            height: 2,
            top: top,
            right: Double(Int((x + 1).rounded())),
            bottom: Double(Int((y + 1).rounded())),
            left: left
        )
    }

    private func positioningBounds(for id: String) -> ElementBounds? {
        for raw in domRaw where raw.string("id") == id {
            if let positioning = raw["positioning"], let boundsValue = positioning["bounds"] {
                return ElementBounds(json: boundsValue)
            }
        }
        return nil
    }

    // MARK: Scroll

    /// Scrolls the element with `id` into view, returning its bounds adjusted
    /// for any enclosing iframe offset when requested.
    public func scrollToElement(_ id: String, _ label: String?, _ options: ScrollToElementOptions = ScrollToElementOptions()) async throws -> ScrollToElementResult {
        do {
            try throwIfAborted(options.signal)
            let nodes = try await ensureDomCache(options.signal)
            try throwIfAborted(options.signal)
            let alohaId = nodes.first { $0.id == id }?.element.attributes["aloha-id"]
            guard let alohaId else {
                return ScrollToElementResult(message: "Element not found with this ID, make sure you found a real ID.", scrollDistance: 0)
            }
            let escapedAlohaId = alohaId.replacingOccurrences(of: "\"", with: "\\\"")
            let finder = buildFindElementGlobalScript("'[aloha-id=\"\(escapedAlohaId)\"]'")
            let includeBounds = options.returnBounds ? "true" : "false"
            let forceFlag = options.force ? "true" : "false"
            let script = """

                  (async function() {
                    try {
                      \(finder)
                      const includeBounds = \(includeBounds);

                      const { element, parentIframe } = findElementGlobal(selector, document);
                      if (!element) {
                        return { success: false, error: 'Element not found with aloha-id' };
                      }

                      const rect = element.getBoundingClientRect();

                      const iframeOffset = { x: 0, y: 0 };
                      if (parentIframe) {
                        const iframeRect = parentIframe.getBoundingClientRect();
                        iframeOffset.x = iframeRect.left;
                        iframeOffset.y = iframeRect.top;
                      }

                      const adjustedRect = {
                        x: rect.x + iframeOffset.x,
                        y: rect.y + iframeOffset.y,
                        width: rect.width,
                        height: rect.height,
                        top: rect.top + iframeOffset.y,
                        right: rect.right + iframeOffset.x,
                        bottom: rect.bottom + iframeOffset.y,
                        left: rect.left + iframeOffset.x
                      };

                      const vh = window.innerHeight || document.documentElement.clientHeight || 0;
                      const vw = window.innerWidth || document.documentElement.clientWidth || 0;
                      const isInViewport = adjustedRect.top >= 0 && adjustedRect.left >= 0 && adjustedRect.bottom <= vh && adjustedRect.right <= vw && adjustedRect.height > 0 && adjustedRect.width > 0;

                      if (isInViewport && !\(forceFlag)) {
                        const bounds = adjustedRect;
                        return { success: true, scrollDistance: 0, bounds };
                      }

                      const initialScrollY = window.scrollY || window.pageYOffset || 0;
                      element.scrollIntoView({ block: 'center', behavior: 'smooth' });
                      await new Promise(resolve => setTimeout(resolve, 1000));
                      const finalScrollY = window.scrollY || window.pageYOffset || 0;

                      const r2 = element.getBoundingClientRect();
                      const adjustedR2 = {
                        x: r2.x + iframeOffset.x,
                        y: r2.y + iframeOffset.y,
                        width: r2.width,
                        height: r2.height,
                        top: r2.top + iframeOffset.y,
                        right: r2.right + iframeOffset.x,
                        bottom: r2.bottom + iframeOffset.y,
                        left: r2.left + iframeOffset.x
                      };

                      const bounds = adjustedR2;

                      return {
                        success: true,
                        scrollDistance: Math.abs(finalScrollY - initialScrollY),
                        bounds
                      };
                    } catch (error) {
                      return { success: false, error: String(error && error.message ? error.message : error) };
                    }
                  })();

            """
            let layer = tab.layer
            let result = try await raceAbort(options.signal) { try await layer.executeJavaScript(script) }
            try throwIfAborted(options.signal)
            if result.bool("success") == true {
                // Show the agent cursor for the explicit hover / scroll verbs (the
                // internal pre-click scroll passes a different label, so it does not
                // double-animate on top of the click's own cursor move).
                if label == "Hover" || label == "Scroll",
                   let boundsValue = result["bounds"], case .object = boundsValue {
                    await animateCursorToBounds(ElementBounds(json: boundsValue), label ?? "")
                }
                let distance = result.number("scrollDistance") ?? 0
                let bounds: ElementBounds??
                if options.returnBounds {
                    if let boundsValue = result["bounds"], case .object = boundsValue {
                        bounds = .some(ElementBounds(json: boundsValue))
                    } else {
                        bounds = .some(nil)
                    }
                } else {
                    bounds = nil
                }
                return ScrollToElementResult(
                    message: "Scrolled to element\(label.map { ": \($0)" } ?? "").",
                    scrollDistance: distance,
                    bounds: bounds
                )
            }
            throw SimpleError("Scroll failed: \(result.string("error") ?? "unknown error")")
        } catch {
            if isAbortError(error) { throw error }
            throw SimpleError("Failed to execute scroll script: \(describeError(error))")
        }
    }

    /// Animates the visible agent cursor to the centre of `bounds` as a plain
    /// move (no click scale), so the non-click verbs (hover / scroll / select)
    /// show the mouse marker the way click and focus already do.
    private func animateCursorToBounds(_ bounds: ElementBounds?, _ label: String) async {
        guard let bounds else { return }
        await cursorAnimator.animateAgentCursorClick(tab, bounds, label, scaleOnClick: false, cursorLabelKind: nil)
    }

    public func removeHighlights() async {
        do {
            _ = try await tab.getLayer().executeJavaScript("""

                    (() => {
                      const container = document.getElementById('alohajet-highlight-container');
                      if (container) {
                        container.remove();
                      }
                    })()

            """)
        } catch {}
    }

    // MARK: Element lookup

    /// Finds a DOM node by exact id, then by exact `aloha-id`. A partial or
    /// misremembered id is a miss, deliberately: over hashed ids a prefix match
    /// returns a confidently wrong element, and a wrong-element click reports success.
    public func findElementById(_ id: String, _ signal: AbortSignal?) async throws -> DomNode? {
        let nodes = try await ensureDomCache(signal)
        return matchNode(nodes, id)
    }

    private func matchNode(_ nodes: [DomNode], _ id: String) -> DomNode? {
        if let exact = nodes.first(where: { $0.id == id }) { return exact }
        if let byAlohaId = nodes.first(where: { $0.element.attributes["aloha-id"] == id }) { return byAlohaId }
        return nil
    }

    // MARK: Site JSON

    /// Gathers the page's own embedded structured data — JSON-LD, the `__NEXT_DATA__` hydration
    /// payload, and (best-effort) the Shopify `/products.json` feed — and parses it off the page
    /// thread. `nil` when the page exposes no usable product data or the snippet fails, so the
    /// caller prepends nothing.
    private func collectSiteJsonBlock(_ signal: AbortSignal?) async -> String? {
        let script = """
        (async () => {
              const out = { jsonLd: [], nextData: null, shopify: null };
              try {
                const scripts = document.querySelectorAll('script[type="application/ld+json"]');
                for (const s of scripts) {
                  const text = (s.textContent || '').trim();
                  if (text) out.jsonLd.push(text);
                }
              } catch (e) {}
              try {
                const nd = document.getElementById('__NEXT_DATA__');
                if (nd) {
                  const text = (nd.textContent || '').trim();
                  if (text) out.nextData = text;
                }
              } catch (e) {}
              try {
                const base = location.origin;
                if (base && /^https?:/.test(base)) {
                  const res = await fetch(base + '/products.json?limit=50', { credentials: 'omit' });
                  if (res && res.ok) {
                    const ct = (res.headers.get('content-type') || '').toLowerCase();
                    if (ct.includes('json')) {
                      const text = await res.text();
                      if (text && text.trim().startsWith('{')) out.shopify = text;
                    }
                  }
                }
              } catch (e) {}
              return out;
            })()
        """
        let result: JSValue
        do {
            result = try await executeJavaScript(script, signal)
        } catch {
            if isAbortError(error) { return nil }
            return nil
        }
        let jsonLd = (result["jsonLd"]?.arrayValue ?? []).compactMap { $0.stringValue }
        let nextData = result["nextData"]?.stringValue
        let shopify = result["shopify"]?.stringValue
        return siteJsonStructuredBlock(jsonLdScripts: jsonLd, nextData: nextData, shopifyProductsJson: shopify)
    }

    // MARK: Markdown

    public func getFullMarkdown() async throws -> String {
        let nodes = try await getDOM(highlight: false)
        return serializeFullMarkdown(nodes)
    }

    /// The per-observation token cap from `ALOHAJET_MAX_OBS_TOKENS` (unset/0 = off).
    /// Bounds a SINGLE page observation so one huge DOM can't blow a small model's
    /// context window on its own — compaction handles cross-turn accumulation, this
    /// handles a single oversized message.
    static func maxObservationTokens() -> Int? {
        if let raw = getenv("ALOHAJET_MAX_OBS_TOKENS"),
           let value = Int(String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines)),
           value > 0 {
            return value
        }
        // Cheap-model flag (ALOHAJET_COMPACT_TOOLS): when no explicit cap is set, default the
        // page observation to a SMALL budget. The compact path already narrows the tools and
        // system prompt; the `<active_tab>` page snapshot is then the last big per-turn cost
        // (measured ~5k tok/turn vs a lean agent's ~200). The head-biased markdown is needed
        // mainly for interaction targets (aloha-ids) — which a smaller snapshot still carries.
        if let raw = getenv("ALOHAJET_COMPACT_TOOLS") {
            let v = String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["1", "true", "yes", "on"].contains(v) { return 2500 }
        }
        return nil
    }

    /// Caps an observation's markdown to `cap` tokens (nil/≤0 → returned unchanged).
    /// Uses the real `tokenCount` when the BPE encoder produced one, else a char/4
    /// estimate, so the cap fires even when the encoder can't load in this build. Keeps
    /// a head-biased head+tail slice around a middle marker — top-of-page context plus
    /// the page's trailing interactive elements. Returns the (possibly truncated)
    /// markdown and the token count to report for it.
    static func cappedObservation(markdown: String, tokenCount: Int, cap: Int?) -> (markdown: String, tokenCount: Int) {
        guard let cap = cap, cap > 0 else { return (markdown, tokenCount) }
        let estTokens = tokenCount > 0 ? tokenCount : (markdown.count + 3) / 4
        guard estTokens > cap else { return (markdown, tokenCount) }
        let charBudget = max(400, Int(Double(markdown.count) * Double(cap) / Double(max(1, estTokens))))
        let headChars = min(markdown.count, (charBudget * 4) / 5)
        let tailChars = max(0, min(markdown.count - headChars, charBudget - headChars))
        let head = String(markdown.prefix(headChars))
        let tail = tailChars > 0 ? String(markdown.suffix(tailChars)) : ""
        let hiddenChars = markdown.count - head.count - tail.count
        guard hiddenChars > 0 else { return (markdown, tokenCount) }
        let capped = head
            + "\n\n… [observation truncated: ~\(estTokens - cap) tokens / \(hiddenChars) chars hidden to fit the context budget; scroll or read a specific section for detail] …\n\n"
            + tail
        return (capped, cap)
    }

    /// Extracts the DOM and serializes it to markdown, optionally capturing a
    /// screenshot, returning timing diagnostics and any per-stage errors.
    public func getInteractMarkdown(
        includeScreenshot: Bool = false,
        highlight: Bool = false,
        serializeOptions: DomSerializeOptions = DomSerializeOptions(),
        signal: AbortSignal? = nil
    ) async throws -> InteractMarkdownResult {
        try throwIfAborted(signal)
        let startTime = monotonicMs()
        do {
            let domStart = monotonicMs()
            var nodes: [DomNode] = []
            var domError: String?
            do {
                nodes = try await getDOM(highlight: highlight, focusInteractive: false, signal: signal)
            } catch {
                if isAbortError(error) { throw error }
                domError = describeError(error, includeName: true)
                nodes = []
            }
            try throwIfAborted(signal)
            let domExtractionTimeMs = monotonicMs() - domStart

            let serializeStart = monotonicMs()
            var markdown = ""
            var serializeError: String?
            do {
                try throwIfAborted(signal)
                let serializeNodes = serializeOptions.cleanDom ? cleanDomTree(nodes) : nodes
                markdown = serializeFullMarkdown(serializeNodes, serializeOptions)
                try throwIfAborted(signal)
            } catch {
                if isAbortError(error) { throw error }
                serializeError = describeError(error, includeName: true)
            }
            let serializationTimeMs = monotonicMs() - serializeStart

            // Site-JSON extraction (OFF by default): when enabled, read the page's own
            // structured data and prepend a compact product summary so facts the visual
            // serialization misses (component-painted name/price) still reach the model.
            if serializeOptions.extractSiteJson {
                if let block = await collectSiteJsonBlock(signal), !block.isEmpty {
                    markdown = block + "\n\n" + markdown
                }
                try throwIfAborted(signal)
            }

            // Reading fix: collapse junk whitespace WITHOUT destroying the renderer's leading
            // structural indent (list items / nested interactive elements indent by ~2 spaces
            // per nesting level; headings, table rows and paragraphs are flush-left). Per line:
            // keep the leading-space indent, collapse internal whitespace runs, drop trailing;
            // then squeeze 3+ blank lines to one.
            markdown = markdown
                .components(separatedBy: "\n")
                .map { line -> String in
                    let lead = line.prefix { $0 == " " }
                    let rest = line.dropFirst(lead.count)
                        .replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression)
                        .trimmingCharacters(in: .whitespaces)
                    return rest.isEmpty ? "" : String(lead) + rest
                }
                .joined(separator: "\n")
                .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)

            // Occlusion legend: name each covering overlay ONCE at the top (the per-node
            // [occ:id] markers reference it), so the model sees "one banner covers the
            // page → dismiss it" instead of a repeated verbose suffix.
            let occLegend = occlusionLegend(nodes)
            if !occLegend.isEmpty {
                markdown = occLegend.joined(separator: "\n") + "\n" + markdown
            }

            try throwIfAborted(signal)
            var tokenCount = estimateTokenCount(markdown)

            // P0: cap this single observation to ALOHAJET_MAX_OBS_TOKENS so one huge
            // page can't blow a small model's context window (e.g. Qwen3-32B = 40_960)
            // on its own. Off when unset/0. See `cappedObservation` for the policy.
            let cappedObs = Self.cappedObservation(
                markdown: markdown, tokenCount: tokenCount, cap: Self.maxObservationTokens())
            markdown = cappedObs.markdown
            tokenCount = cappedObs.tokenCount

            var screenshot: String?
            var screenshotError: String?
            let screenshotStart = monotonicMs()
            if includeScreenshot {
                do {
                    try await raceAbort(signal) { try await self.tab.waitForNextAnimationFrames(1) }
                    screenshot = try await raceAbort(signal) { try await self.tab.getViewportBase64() }
                } catch {
                    if isAbortError(error) { throw error }
                    screenshotError = describeError(error, includeName: true)
                }
            }
            let screenshotTimeMs = includeScreenshot ? monotonicMs() - screenshotStart : 0
            let totalTimeMs = monotonicMs() - startTime

            let diagnostics = InteractMarkdownDiagnostics(
                domElementCount: nodes.count,
                markdownLength: markdown.count,
                tokenCount: tokenCount,
                totalTimeMs: totalTimeMs,
                domExtractionTimeMs: domExtractionTimeMs,
                serializationTimeMs: serializationTimeMs,
                screenshotTimeMs: screenshotTimeMs,
                domError: domError,
                serializeError: serializeError,
                screenshotError: screenshotError
            )
            let vizPreview = markdown.prefix(300).replacingOccurrences(of: "\n", with: " ⏎ ")
            rootLogger.info("[viz] read: highlighted \(nodes.count) interactive elements; markdown \(markdown.count) chars; preview: \(vizPreview)")
            // Snapshot is already serialized; this delay only keeps the id boxes
            // visible on screen so a read isn't just an imperceptible flash. // @allow
            try? await Task.sleep(nanoseconds: Self.readHighlightLingerNanos)
            await removeHighlights()
            return InteractMarkdownResult(markdown: markdown, screenshot: screenshot, diagnostics: diagnostics)
        } catch {
            await removeHighlights()
            throw error
        }
    }

    // MARK: Keystrokes

    private static let keyModifierBit: [String: Int] = [
        "alt": 1, "control": 2, "meta": 4, "shift": 8
    ]

    private struct KeyDescriptor {
        var key: String
        var code: String
        var keyCode: Int
        var text: String?
        var unmodifiedText: String?
    }

    private static let modifierKeyDescriptors: [String: KeyDescriptor] = [
        "control": KeyDescriptor(key: "Control", code: "ControlLeft", keyCode: 17),
        "shift": KeyDescriptor(key: "Shift", code: "ShiftLeft", keyCode: 16),
        "alt": KeyDescriptor(key: "Alt", code: "AltLeft", keyCode: 18),
        "meta": KeyDescriptor(key: "Meta", code: "MetaLeft", keyCode: 91)
    ]

    private static let specialKeyDescriptors: [String: KeyDescriptor] = [
        "Enter": KeyDescriptor(key: "Enter", code: "Enter", keyCode: 13, text: "\r", unmodifiedText: "\r"),
        "Tab": KeyDescriptor(key: "Tab", code: "Tab", keyCode: 9, text: "\t", unmodifiedText: "\t"),
        " ": KeyDescriptor(key: " ", code: "Space", keyCode: 32, text: " ", unmodifiedText: " "),
        ".": KeyDescriptor(key: ".", code: "Period", keyCode: 190, text: ".", unmodifiedText: "."),
        "@": KeyDescriptor(key: "@", code: "Digit2", keyCode: 50, text: "@", unmodifiedText: "@"),
        "Backspace": KeyDescriptor(key: "Backspace", code: "Backspace", keyCode: 8),
        "Delete": KeyDescriptor(key: "Delete", code: "Delete", keyCode: 46),
        "Escape": KeyDescriptor(key: "Escape", code: "Escape", keyCode: 27),
        "ArrowLeft": KeyDescriptor(key: "ArrowLeft", code: "ArrowLeft", keyCode: 37),
        "ArrowUp": KeyDescriptor(key: "ArrowUp", code: "ArrowUp", keyCode: 38),
        "ArrowRight": KeyDescriptor(key: "ArrowRight", code: "ArrowRight", keyCode: 39),
        "ArrowDown": KeyDescriptor(key: "ArrowDown", code: "ArrowDown", keyCode: 40),
        "PageUp": KeyDescriptor(key: "PageUp", code: "PageUp", keyCode: 33),
        "PageDown": KeyDescriptor(key: "PageDown", code: "PageDown", keyCode: 34),
        "Home": KeyDescriptor(key: "Home", code: "Home", keyCode: 36),
        "End": KeyDescriptor(key: "End", code: "End", keyCode: 35)
    ]

    private func modifierBit(_ name: String) -> Int {
        Self.keyModifierBit[name.lowercased()] ?? 0
    }

    /// Emulates a single keystroke (with optional modifiers) through CDP,
    /// pressing/releasing modifiers around the key and choosing the appropriate
    /// key-event sequence. Failures are swallowed.
    public func emulateKeyStroke(_ label: String?, _ stroke: KeyStroke, _ signal: AbortSignal?, dispatchViaCdp: Bool = true) async throws {
        if signal?.aborted == true { throw AbortSignalError("Operation aborted before keystroke") }
        guard dispatchViaCdp else { return }
        do {
            let combinedModifiers = stroke.modifiers.reduce(0) { $0 | modifierBit($1) }
            let modifierWithoutShift = (combinedModifiers & ~8) != 0

            let isSpecial = Self.specialKeyDescriptors[stroke.key] != nil
            let isSingleChar = !isSpecial && stroke.key.count == 1
            let descriptor: KeyDescriptor
            if let special = Self.specialKeyDescriptors[stroke.key] {
                descriptor = special
            } else {
                let upper = stroke.key.uppercased()
                let keyCode = Int(upper.unicodeScalars.first?.value ?? 0)
                descriptor = KeyDescriptor(key: stroke.key, code: "Key\(upper)", keyCode: keyCode, text: stroke.key, unmodifiedText: stroke.key)
            }

            if !stroke.modifiers.isEmpty {
                var running = 0
                for modifier in stroke.modifiers {
                    guard let descr = Self.modifierKeyDescriptors[modifier] else { continue }
                    running |= modifierBit(modifier)
                    try await sendKeyEvent("rawKeyDown", windowsVirtualKeyCode: descr.keyCode, code: descr.code, key: descr.key, modifiers: running)
                    try await Task.sleep(nanoseconds: 3_000_000)
                }
            }

            let isDotOrAt = stroke.key == "." || stroke.key == "@"
            if isSpecial && (stroke.key == "Enter" || stroke.key == "Tab" || stroke.key == " " || isDotOrAt) {
                try await sendKeyEvent(
                    modifierWithoutShift || !isDotOrAt ? "rawKeyDown" : "keyDown",
                    windowsVirtualKeyCode: descriptor.keyCode,
                    code: descriptor.code,
                    key: descriptor.key,
                    modifiers: combinedModifiers
                )
                if !modifierWithoutShift {
                    try await Task.sleep(nanoseconds: 4_000_000)
                    try await sendCharEvent(windowsVirtualKeyCode: descriptor.keyCode, text: descriptor.text ?? "", unmodifiedText: descriptor.unmodifiedText ?? "", modifiers: combinedModifiers)
                }
                try await Task.sleep(nanoseconds: 3_000_000)
                try await sendKeyEvent("keyUp", windowsVirtualKeyCode: descriptor.keyCode, code: descriptor.code, key: descriptor.key, modifiers: combinedModifiers)
            } else if isSingleChar {
                if modifierWithoutShift {
                    try await sendKeyEvent("rawKeyDown", windowsVirtualKeyCode: descriptor.keyCode, code: descriptor.code, key: descriptor.key, modifiers: combinedModifiers)
                    try await Task.sleep(nanoseconds: 3_000_000)
                    try await sendKeyEvent("keyUp", windowsVirtualKeyCode: descriptor.keyCode, code: descriptor.code, key: descriptor.key, modifiers: combinedModifiers)
                } else {
                    try await sendKeyEvent("keyDown", windowsVirtualKeyCode: descriptor.keyCode, code: descriptor.code, key: descriptor.key, modifiers: combinedModifiers)
                    try await Task.sleep(nanoseconds: 3_000_000)
                    try await sendCharEvent(text: descriptor.text ?? "", unmodifiedText: descriptor.unmodifiedText ?? "", modifiers: combinedModifiers)
                    try await Task.sleep(nanoseconds: 3_000_000)
                    try await sendKeyEvent("keyUp", windowsVirtualKeyCode: descriptor.keyCode, code: descriptor.code, key: descriptor.key, modifiers: combinedModifiers)
                }
            } else {
                try await sendKeyEvent("rawKeyDown", windowsVirtualKeyCode: descriptor.keyCode, code: descriptor.code, key: descriptor.key, modifiers: combinedModifiers)
                try await Task.sleep(nanoseconds: 3_000_000)
                try await sendKeyEvent("keyUp", windowsVirtualKeyCode: descriptor.keyCode, code: descriptor.code, key: descriptor.key, modifiers: combinedModifiers)
            }

            if !stroke.modifiers.isEmpty {
                var running = combinedModifiers
                for modifier in stroke.modifiers.reversed() {
                    guard let descr = Self.modifierKeyDescriptors[modifier] else { continue }
                    running &= ~modifierBit(modifier)
                    try await sendKeyEvent("keyUp", windowsVirtualKeyCode: descr.keyCode, code: descr.code, key: descr.key, modifiers: running)
                    try await Task.sleep(nanoseconds: 3_000_000)
                }
            }

            if signal?.aborted == true {
                throw AbortSignalError("Operation aborted during keystroke delay")
            }
            try await Task.sleep(nanoseconds: 3_000_000)
            if signal?.aborted == true {
                throw AbortSignalError("Operation aborted during keystroke delay")
            }
        } catch {}
    }

    private func sendKeyEvent(_ type: String, windowsVirtualKeyCode: Int, code: String, key: String, modifiers: Int) async throws {
        try await debuggerInstance.sendCommand("Input", "dispatchKeyEvent", .object([
            ("type", .string(type)),
            ("windowsVirtualKeyCode", .number(windowsVirtualKeyCode)),
            ("code", .string(code)),
            ("key", .string(key)),
            ("modifiers", .number(modifiers))
        ]))
    }

    private func sendCharEvent(windowsVirtualKeyCode: Int? = nil, text: String, unmodifiedText: String, modifiers: Int) async throws {
        var members: [(String, JSValue)] = [("type", .string("char"))]
        if let windowsVirtualKeyCode {
            members.append(("windowsVirtualKeyCode", .number(windowsVirtualKeyCode)))
        }
        members.append(("text", .string(text)))
        members.append(("unmodifiedText", .string(unmodifiedText)))
        members.append(("modifiers", .number(modifiers)))
        try await debuggerInstance.sendCommand("Input", "dispatchKeyEvent", .object(members))
    }

    /// Dispatches a browser edit command (e.g. `selectAll`), falling back to a
    /// Cmd-A keystroke when the CDP command path fails.
    public func performBrowserCommand(_ label: String?, _ command: String, _ signal: AbortSignal?) async throws {
        if signal?.aborted == true { throw AbortSignalError("Operation aborted before browser command") }
        do {
            try await debuggerInstance.sendCommand("Input", "dispatchKeyEvent", .object([
                ("type", .string("keyDown")),
                ("commands", .array([.string(command)]))
            ]))
            if signal?.aborted == true { throw AbortSignalError("Operation aborted during command delay") }
            try await Task.sleep(nanoseconds: 50_000_000)
            if signal?.aborted == true { throw AbortSignalError("Operation aborted during command delay") }
            try await debuggerInstance.sendCommand("Input", "dispatchKeyEvent", .object([
                ("type", .string("keyUp"))
            ]))
        } catch {
            if command == "selectAll" {
                try await emulateKeyStroke(label, KeyStroke(key: "a", modifiers: ["meta"]), signal)
            }
        }
    }

    // MARK: Clickable point

    /// Computes the best clickable point for the element with `id`, probing a
    /// priority list of points and handling zero-size checkbox/radio inputs via
    /// their labels.
    public func findClickablePoint(_ id: String, _ signal: AbortSignal?) async throws -> ClickablePoint {
        guard let node = try await findElementById(id, signal) else {
            return ClickablePoint(isClickable: false)
        }
        guard let alohaId = node.element.attributes["aloha-id"] else {
            return ClickablePoint(isClickable: false)
        }
        let escapedAlohaId = alohaId.replacingOccurrences(of: "\"", with: "\\\"")
        let script = clickablePointScript(escapedAlohaId)
        let layer = tab.layer
        let result = try await raceAbort(signal) { try await layer.executeJavaScript(script) }
        if case .object = result {
            return ClickablePoint(
                isClickable: result.bool("isClickable") ?? false,
                x: result.number("x"),
                y: result.number("y"),
                location: result.string("location"),
                coveringElement: result.string("coveringElement")
            )
        }
        return ClickablePoint(isClickable: false, coveringElement: "unknown")
    }

    private func clickablePointScript(_ escapedAlohaId: String) -> String {
        return """

              (() => {
                function findInShadow(root, selector) {
                  const direct = root.querySelector(selector)
                  if (direct) return direct
                  for (const child of root.querySelectorAll('*')) {
                    if (child.shadowRoot) {
                      const found = findInShadow(child.shadowRoot, selector)
                      if (found) return found
                    }
                  }
                  return null
                }

                function findElementGlobal(selector, root = document, offsetX = 0, offsetY = 0) {
                  const local = findInShadow(root, selector)
                  if (local) {
                    return { element: local, offsetX, offsetY }
                  }
                  const iframes = root.querySelectorAll('iframe')
                  for (const frame of iframes) {
                    try {
                      if (frame.contentDocument) {
                        const frameRect = frame.getBoundingClientRect()
                        const found = findElementGlobal(
                          selector,
                          frame.contentDocument,
                          offsetX + frameRect.left,
                          offsetY + frameRect.top
                        )
                        if (found) return found
                      }
                    } catch {}
                  }
                  return null
                }

                const found = findElementGlobal('[aloha-id="\(escapedAlohaId)"]')
                if (!found) return { isClickable: false, x: null, y: null, location: null }
                const el = found.element

                const rect = el.getBoundingClientRect()
                const pointOffsetX = found.offsetX
                const pointOffsetY = found.offsetY
                const ownerWindow = el.ownerDocument.defaultView || window

                if (rect.width <= 0 || rect.height <= 0) {
                  if (el.tagName === 'INPUT') {
                    const input = el;
                    const inputType = (input.type || '').toLowerCase();
                    if (inputType === 'checkbox' || inputType === 'radio') {
                      const forId = input.id;
                      const label = (input.labels && input.labels[0]) ||
                        (forId ? document.querySelector('label[for="' + (CSS?.escape ? CSS.escape(forId) : forId.replace(/"/g, '\\"')) + '"]') : null) ||
                        input.closest('label');
                      if (label) {
                        const labelRect = label.getBoundingClientRect();
                        if (labelRect.width > 0 && labelRect.height > 0) {
                          return {
                            isClickable: true,
                            x: labelRect.left + labelRect.width / 2 + pointOffsetX,
                            y: labelRect.top + labelRect.height / 2 + pointOffsetY,
                            location: 'label-center'
                          }
                        }
                      }
                    }
                  }
                  return { isClickable: false, x: null, y: null, location: null, coveringElement: 'zero-size' }
                }

                const vw = ownerWindow.innerWidth
                const vh = ownerWindow.innerHeight
                const padding = 5

                // Keep this geometry in sync with probeOccluder in DomTreeScript.swift: the
                // read's occlusion probe samples the same points so its "fully covered" verdict
                // matches this path's "no free point" verdict.
                const points = [
                  { x: rect.left + rect.width / 2, y: rect.top + rect.height / 2, name: 'center' },
                  { x: rect.left + rect.width * 0.25, y: rect.top + rect.height * 0.25, name: 'top-left' },
                  { x: rect.left + rect.width * 0.75, y: rect.top + rect.height * 0.25, name: 'top-right' },
                  { x: rect.left + rect.width * 0.25, y: rect.top + rect.height * 0.75, name: 'bottom-left' },
                  { x: rect.left + rect.width * 0.75, y: rect.top + rect.height * 0.75, name: 'bottom-right' },
                  { x: rect.left + padding, y: rect.top + rect.height / 2, name: 'left-edge' },
                  { x: rect.right - padding, y: rect.top + rect.height / 2, name: 'right-edge' },
                  { x: rect.left + rect.width / 2, y: rect.top + padding, name: 'top-edge' },
                  { x: rect.left + rect.width / 2, y: rect.bottom - padding, name: 'bottom-edge' },
                ];

                let firstBlocker = null

                const isCheckboxOrRadio = el.tagName === 'INPUT' &&
                  (el.type === 'checkbox' || el.type === 'radio')

                for (const point of points) {
                  const outOfViewport = point.x < 0 || point.y < 0 || point.x > vw || point.y > vh
                  if (outOfViewport) continue

                  const topEl = el.ownerDocument.elementFromPoint(point.x, point.y)
                  if (!topEl) continue

                  const isSelf = topEl === el
                  const isChild = el.contains(topEl)
                  const isParentMatch = !!topEl.closest('[aloha-id="\(escapedAlohaId)"]')

                  if (isSelf || isChild || isParentMatch) {
                    return {
                      isClickable: true,
                      x: point.x + pointOffsetX,
                      y: point.y + pointOffsetY,
                      location: point.name
                    }
                  }

                  if (isCheckboxOrRadio) {
                    const labelOnTop = topEl.tagName === 'LABEL' ? topEl : topEl.closest('label')
                    if (labelOnTop) {
                      const labelControlsInput =
                        labelOnTop.control === el ||
                        (el.id && labelOnTop.htmlFor === el.id) ||
                        labelOnTop.contains(el)
                      if (labelControlsInput) {
                        return {
                          isClickable: true,
                          x: point.x + pointOffsetX,
                          y: point.y + pointOffsetY,
                          location: 'label-on-top'
                        }
                      }
                    }
                  }

                  if (!firstBlocker) {
                    firstBlocker = topEl.getAttribute('aloha-id') || topEl.tagName.toLowerCase()
                  }
                }

                return {
                  isClickable: false,
                  x: null,
                  y: null,
                  location: null,
                  coveringElement: firstBlocker
                }
              })()

        """
    }

    // MARK: Helpers

    private func describeError(_ error: Error, includeName: Bool = false) -> String {
        if let abort = error as? AbortSignalError {
            return includeName ? "\(abort.name): \(abort.message)" : abort.message
        }
        return "\(error)"
    }
}

// MARK: - DOM node parsing

func parseDomNode(_ value: JSValue) -> DomNode? {
    guard let id = value.string("id") else { return nil }
    let elementValue = value["element"]
    var tagName = ""
    var attributes: [String: String] = [:]
    var textContent: String?
    var childText: String?
    if let elementValue {
        tagName = elementValue.string("tagName") ?? ""
        if case let .object(attrMembers)? = elementValue["attributes"] {
            for (key, attr) in attrMembers {
                if case let .string(stringValue) = attr {
                    attributes[key] = stringValue
                }
            }
        }
        textContent = elementValue.string("textContent")
        childText = elementValue.string("childText")
    }
    let element = DomElement(tagName: tagName, attributes: attributes, textContent: textContent, childText: childText)

    var content = DomContent()
    if let contentValue = value["content"] {
        content.comprehensiveText = contentValue.string("comprehensiveText")
        if let optionValue = contentValue["optionData"], case .object = optionValue {
            var options: [DomSelectOption] = []
            if let optionArray = optionValue.array("options") {
                for option in optionArray {
                    options.append(DomSelectOption(
                        text: option.string("text"),
                        value: option.string("value"),
                        selected: option.bool("selected") ?? false
                    ))
                }
            }
            content.optionData = DomOptionData(options: options, multiple: optionValue.bool("multiple") ?? false)
        }
    }

    var interactivity = DomInteractivity()
    if let interactivityValue = value["interactivity"] {
        interactivity.isInteractive = interactivityValue.bool("isInteractive") ?? false
        interactivity.isInput = interactivityValue.bool("isInput") ?? false
        interactivity.isSelect = interactivityValue.bool("isSelect") ?? false
        interactivity.isHighlighted = interactivityValue.bool("isHighlighted") ?? false
        interactivity.isTopElement = interactivityValue.bool("isTopElement") ?? false
        interactivity.isFileInput = interactivityValue.bool("isFileInput") ?? false
        if let occluder = interactivityValue["occludedBy"], case .object = occluder {
            interactivity.occludedBy = OccluderRef(
                alohaId: occluder.string("alohaId"),
                tag: occluder.string("tag") ?? "",
                role: occluder.string("role"),
                text: occluder.string("text")
            )
        }
    }

    var positioning = DomPositioning()
    if let positioningValue = value["positioning"] {
        positioning.distanceToViewportBorder = positioningValue.number("distanceToViewportBorder").map { Int($0) } ?? 0
        positioning.isInViewport = positioningValue.bool("isInViewport") ?? true
        positioning.isVisible = positioningValue.bool("isVisible") ?? true
        if let scrollValue = positioningValue["scroll"], case .object = scrollValue {
            func axis(_ axisValue: JSValue?, _ offsetKey: String, _ sizeKey: String, _ clientKey: String) -> ScrollAxis? {
                guard let axisValue, case .object = axisValue else { return nil }
                return ScrollAxis(
                    offset: axisValue.number(offsetKey).map { Int($0) } ?? 0,
                    scrollSize: axisValue.number(sizeKey).map { Int($0) } ?? 0,
                    clientSize: axisValue.number(clientKey).map { Int($0) } ?? 0)
            }
            positioning.scroll = ScrollDescriptor(
                vertical: axis(scrollValue["vertical"], "scrollTop", "scrollHeight", "clientHeight"),
                horizontal: axis(scrollValue["horizontal"], "scrollLeft", "scrollWidth", "clientWidth"),
                centeredChild: scrollValue.string("centeredChild"))
        }
    }

    var children: [String] = []
    if let childArray = value.array("children") {
        for child in childArray {
            if case let .string(childId) = child { children.append(childId) }
        }
    }

    return DomNode(
        id: id,
        nodeType: value.string("nodeType"),
        element: element,
        content: content,
        interactivity: interactivity,
        positioning: positioning,
        children: children
    )
}

// MARK: - Shared small types

nonisolated struct SimpleError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

/// Suspends until its signal aborts (throwing) or it is cancelled. Resuming
/// happens exactly once so the continuation never leaks when the racing
/// operation finishes first.
final class AbortWaiter<T: Sendable> {
    private let signal: AbortSignal
    private var continuation: CheckedContinuation<T, Error>?
    private var resolved = false
    private var disposeToken: Int?
    private var cancelledBeforeStart = false

    init(signal: AbortSignal) {
        self.signal = signal
    }

    func wait() async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            if cancelledBeforeStart {
                continuation.resume(throwing: CancellationError())
                return
            }
            self.continuation = continuation
            disposeToken = signal.onAbort { [weak self] in
                self?.resume(throwing: AbortSignalError("Operation aborted"))
            }
        }
    }

    func cancel() {
        resume(throwing: CancellationError())
    }

    private func resume(throwing error: Error) {
        if resolved {
            return
        }
        resolved = true
        let pending = continuation
        continuation = nil
        let token = disposeToken
        disposeToken = nil
        if pending == nil {
            cancelledBeforeStart = true
        }
        if let token { signal.removeAbortListener(token) }
        pending?.resume(throwing: error)
    }
}

nonisolated private func monotonicMs() -> Double {
    Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000
}
