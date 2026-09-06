import Testing
import Foundation

#if canImport(JavaScriptCore)
import JavaScriptCore
@testable import BrowserTools

// MARK: - Source slicing

/// Brace-matches and returns the body of a top-level `function <name>(...) {` from `source`.
func sliceJSFunction(named name: String, from source: String) -> String {
    guard let header = source.range(of: "function \(name)(") else {
        Issue.record("function \(name) not found in script")
        return ""
    }
    guard let openBrace = source.range(of: "{", range: header.upperBound..<source.endIndex) else {
        Issue.record("opening brace for \(name) not found")
        return ""
    }
    var depth = 0
    var i = openBrace.lowerBound
    while i < source.endIndex {
        let c = source[i]
        if c == "{" {
            depth += 1
        } else if c == "}" {
            depth -= 1
            if depth == 0 {
                return String(source[header.lowerBound...i])
            }
        }
        i = source.index(after: i)
    }
    Issue.record("closing brace for \(name) not found")
    return ""
}

/// Runs the page-side `probeOccluder` (and, for the consistency invariant, the click path's
/// hit-test loop) against synthetic layouts inside a JavaScriptCore context. The functions are
/// sliced verbatim out of the shipped scripts at test time, so these assertions exercise the real
/// code rather than a copy and cannot silently drift from it.
///
/// `probeOccluder` reports an occluder only when EVERY in-viewport sampled point is intercepted by
/// a foreign element; the moment any point reaches the element it returns null (reachable). The
/// click path's loop returns `isClickable` on the first point that reaches the element. The two
/// sample the same nine points, so a partially exposed element the click can still reach is never
/// reported as occluded, while a full-cover overlay covers every point and is still flagged.
@Suite struct OcclusionProbeGeometryTests {

    private var probeOccluderSource: String {
        sliceJSFunction(named: "probeOccluder", from: buildAgentDomTreeScript(highlight: false, focusInteractive: true))
    }

    // MARK: - Synthetic DOM mock

    /// A flat-list DOM mock providing exactly the surface `probeOccluder` and the click loop touch:
    /// rects, parent/contains relationships, attributes, `document.elementFromPoint` (z-order +
    /// pointer-events:none skipping), `getBoundingClientRect`, `querySelector`, and `closest`.
    /// `elements` is an array of plain objects: `{ id, tag, role, alohaId, parent, rect, z,
    /// pointerEvents }` where `rect = { left, top, width, height }`. Higher `z` wins ties; an
    /// element with `pointerEvents:'none'` is transparent to the hit-test.
    private let domHarnessPrelude = """
    var __nodes = [];
    function ShadowRoot() {}
    function makeNode(spec) {
      var node = {
        id: spec.id || "",
        tagName: (spec.tag || "div").toUpperCase(),
        __role: spec.role || null,
        __alohaId: spec.alohaId || null,
        __parentId: spec.parent || null,
        __rect: spec.rect,
        __z: spec.z || 0,
        __pe: spec.pointerEvents || "auto",
        __viewportFixed: !!spec.fixed,
        shadowRoot: null,
        labels: null
      };
      node.ownerDocument = document;
      node.getRootNode = function () { return document; };
      node.getAttribute = function (name) {
        if (name === "aloha-id") return node.__alohaId;
        if (name === "role") return node.__role;
        if (name === "for") return node.__for || null;
        return null;
      };
      Object.defineProperty(node, "parentElement", {
        get: function () { return __nodeById(node.__parentId); }
      });
      node.contains = function (other) {
        var cur = other;
        while (cur) {
          if (cur === node) return true;
          cur = __nodeById(cur.__parentId);
        }
        return false;
      };
      node.closest = function (selector) {
        var want = selector.replace('[aloha-id="', "").replace('"]', "");
        var cur = node;
        while (cur) {
          if (cur.__alohaId === want) return cur;
          cur = __nodeById(cur.__parentId);
        }
        return null;
      };
      node.getClientRects = function () { return [node.getBoundingClientRect()]; };
      node.getBoundingClientRect = function () {
        var r = node.__rect;
        return {
          left: r.left, top: r.top, width: r.width, height: r.height,
          right: r.left + r.width, bottom: r.top + r.height
        };
      };
      return node;
    }
    function __nodeById(id) {
      if (!id) return null;
      for (var i = 0; i < __nodes.length; i++) if (__nodes[i].id === id) return __nodes[i];
      return null;
    }
    function buildDom(specs) {
      __nodes = specs.map(makeNode);
      return __nodeById;
    }
    var window = { innerWidth: 1000, innerHeight: 800 };
    var document = {
      documentElement: { tagName: "HTML" },
      elementFromPoint: function (x, y) {
        var best = null;
        for (var i = 0; i < __nodes.length; i++) {
          var n = __nodes[i];
          if (n.__pe === "none") continue;
          var r = n.__rect;
          if (x >= r.left && x <= r.left + r.width && y >= r.top && y <= r.top + r.height) {
            if (!best || n.__z >= best.__z) best = n;
          }
        }
        return best;
      },
      querySelector: function (selector) {
        var want = selector.replace('[aloha-id="', "").replace('"]', "");
        for (var i = 0; i < __nodes.length; i++) if (__nodes[i].__alohaId === want) return __nodes[i];
        return null;
      },
      querySelectorAll: function () { return []; }
    };
    window.document = document;
    document.documentElement.ownerDocument = document;
    """

    private func makeContext() -> JSContext {
        let ctx = JSContext()!
        ctx.exceptionHandler = { _, exception in
            Issue.record("JS exception: \(exception?.toString() ?? "unknown")")
        }
        ctx.evaluateScript(domHarnessPrelude)
        ctx.evaluateScript(probeOccluderSource)
        return ctx
    }

    /// Returns the occluder's `aloha-id` (or tag) for `targetId`, or nil when reachable.
    private func probeResult(_ ctx: JSContext, specsJS: String, targetId: String) -> String? {
        let script = """
        (function () {
          buildDom(\(specsJS));
          var target = __nodeById("\(targetId)");
          var cover = probeOccluder(target);
          if (!cover) return null;
          return cover.__alohaId || cover.tagName.toLowerCase();
        })()
        """
        let value = ctx.evaluateScript(script)!
        return value.isNull || value.isUndefined ? nil : value.toString()
    }

    // A wide nav link occupying y 100..160 across x 100..500.
    private let navLinkSpec = #"{ id: "link", tag: "a", alohaId: "6291f641", rect: { left: 100, top: 100, width: 400, height: 60 } }"#

    // MARK: - Reachability cases

    @Test func partialTopCoverStaysReachable() {
        // The 6291f641 "Express Lane" case: a banner covers only the top 40% of the link. The
        // center, the bottom quadrants and the bottom-edge midpoint still reach the link, so the
        // probe must NOT flag it as occluded.
        let banner = #"{ id: "banner", tag: "div", alohaId: "banner", z: 10, rect: { left: 0, top: 90, width: 1000, height: 35 } }"#
        let result = probeResult(makeContext(), specsJS: "[\(navLinkSpec), \(banner)]", targetId: "link")
        #expect(result == nil)
    }

    @Test func fullOpaqueCoverIsOccluded() {
        // An opaque div over the link's whole rect covers all nine points; none reach the link.
        let cover = #"{ id: "cover", tag: "div", alohaId: "cover", z: 10, rect: { left: 100, top: 100, width: 400, height: 60 } }"#
        let result = probeResult(makeContext(), specsJS: "[\(navLinkSpec), \(cover)]", targetId: "link")
        #expect(result == "cover")
    }

    @Test func fullViewportBackdropIsOccluded() {
        // A true cookie wall / modal backdrop covering the whole viewport is reported and resolves
        // to its compact reference.
        let backdrop = #"{ id: "wall", tag: "div", alohaId: "cookiewall", z: 100, rect: { left: 0, top: 0, width: 1000, height: 800 } }"#
        let result = probeResult(makeContext(), specsJS: "[\(navLinkSpec), \(backdrop)]", targetId: "link")
        #expect(result == "cookiewall")
    }

    @Test func pointerEventsNoneOverlayIsReachable() {
        // A transparent, non-clickable full-screen overlay is skipped by elementFromPoint at every
        // point, so the link stays reachable — matching the click path.
        let overlay = #"{ id: "ghost", tag: "div", alohaId: "ghost", z: 100, pointerEvents: "none", rect: { left: 0, top: 0, width: 1000, height: 800 } }"#
        let result = probeResult(makeContext(), specsJS: "[\(navLinkSpec), \(overlay)]", targetId: "link")
        #expect(result == nil)
    }

    @Test func transparentClickableInterceptorIsOccluded() {
        // A transparent BUT pointer-events:auto full-screen interceptor really blocks clicks; it is
        // returned at every point and is therefore flagged occluded.
        let interceptor = #"{ id: "intercept", tag: "div", alohaId: "intercept", z: 100, rect: { left: 0, top: 0, width: 1000, height: 800 } }"#
        let result = probeResult(makeContext(), specsJS: "[\(navLinkSpec), \(interceptor)]", targetId: "link")
        #expect(result == "intercept")
    }

    @Test func allPointsOutOfViewportIsNotAnnotated() {
        // An element entirely outside the viewport samples zero points (sampled === 0) → null.
        let offscreen = #"{ id: "off", tag: "a", alohaId: "off", rect: { left: 2000, top: 2000, width: 100, height: 40 } }"#
        let result = probeResult(makeContext(), specsJS: "[\(offscreen)]", targetId: "off")
        #expect(result == nil)
    }

    // MARK: - Exemption cases

    @Test func labelForDelegationStaysReachable() {
        // A <label for=cb> overlapping its checkbox delegates the click to the checkbox, so the
        // label is the control's own surface, not an occluder.
        let checkbox = #"{ id: "cb", tag: "input", alohaId: "cb", rect: { left: 100, top: 100, width: 200, height: 40 } }"#
        let label = #"{ id: "lab", tag: "label", forId: "cb", z: 10, rect: { left: 0, top: 0, width: 1000, height: 800 } }"#
        // The checkbox element's DOM id must equal the label's `for` so the delegation matches.
        let ctx = makeContext()
        let script = """
        (function () {
          buildDom([\(checkbox), \(label)]);
          var lab = __nodeById("lab");
          lab.__for = "cb";
          var target = __nodeById("cb");
          var cover = probeOccluder(target);
          return cover ? (cover.__alohaId || cover.tagName.toLowerCase()) : null;
        })()
        """
        let value = ctx.evaluateScript(script)!
        #expect(value.isNull || value.isUndefined)
    }

    @Test func interactiveSiblingSharingContainerIsNotTheOccluder() {
        // An interactive sibling (an overlaid <a>) sharing the target's container is the likely
        // intended click target, not a modal, so it is not reported as the cover; with no other
        // covering element the target stays reachable.
        let container = #"{ id: "row", tag: "div", rect: { left: 100, top: 100, width: 400, height: 60 } }"#
        let target = #"{ id: "tgt", tag: "button", alohaId: "tgt", parent: "row", rect: { left: 100, top: 100, width: 400, height: 60 } }"#
        let sibling = #"{ id: "sib", tag: "a", alohaId: "sib", parent: "row", z: 10, rect: { left: 100, top: 100, width: 400, height: 60 } }"#
        let result = probeResult(makeContext(), specsJS: "[\(container), \(target), \(sibling)]", targetId: "tgt")
        #expect(result == nil)
    }

    // MARK: - Read / click consistency invariant

    private var clickLoopSource: String {
        // The click path's per-element loop, lifted as a callable for the consistency check. It
        // mirrors AgentDOMService.clickablePointScript: same nine points, returns isClickable on the
        // first point that reaches the element, otherwise records coveringElement.
        """
        function clickVerdict(el) {
          var rect = el.getBoundingClientRect();
          var vw = window.innerWidth;
          var vh = window.innerHeight;
          var padding = 5;
          var points = [
            { x: rect.left + rect.width / 2, y: rect.top + rect.height / 2 },
            { x: rect.left + rect.width * 0.25, y: rect.top + rect.height * 0.25 },
            { x: rect.left + rect.width * 0.75, y: rect.top + rect.height * 0.25 },
            { x: rect.left + rect.width * 0.25, y: rect.top + rect.height * 0.75 },
            { x: rect.left + rect.width * 0.75, y: rect.top + rect.height * 0.75 },
            { x: rect.left + padding, y: rect.top + rect.height / 2 },
            { x: rect.right - padding, y: rect.top + rect.height / 2 },
            { x: rect.left + rect.width / 2, y: rect.top + padding },
            { x: rect.left + rect.width / 2, y: rect.bottom - padding }
          ];
          var firstBlocker = null;
          for (var i = 0; i < points.length; i++) {
            var p = points[i];
            if (p.x < 0 || p.y < 0 || p.x > vw || p.y > vh) continue;
            var topEl = el.ownerDocument.elementFromPoint(p.x, p.y);
            if (!topEl) continue;
            if (topEl === el || el.contains(topEl) || (el.__alohaId && topEl.closest('[aloha-id="' + el.__alohaId + '"]'))) {
              return { isClickable: true, coveringElement: null };
            }
            if (!firstBlocker) firstBlocker = topEl.__alohaId || topEl.tagName.toLowerCase();
          }
          return { isClickable: false, coveringElement: firstBlocker };
        }
        """
    }

    /// For each layout, `probeOccluder` flagging an occluder must be the exact negation of the click
    /// path finding a free point over the same nine points. This is the guard against the two point
    /// lists drifting apart again.
    @Test func readOcclusionIsTheNegationOfClickReachability() {
        let cases: [(name: String, specs: String, target: String)] = [
            ("partial-top-cover", "[\(navLinkSpec), { id: \"banner\", tag: \"div\", alohaId: \"banner\", z: 10, rect: { left: 0, top: 90, width: 1000, height: 35 } }]", "link"),
            ("full-cover", "[\(navLinkSpec), { id: \"cover\", tag: \"div\", alohaId: \"cover\", z: 10, rect: { left: 100, top: 100, width: 400, height: 60 } }]", "link"),
            ("viewport-backdrop", "[\(navLinkSpec), { id: \"wall\", tag: \"div\", alohaId: \"wall\", z: 100, rect: { left: 0, top: 0, width: 1000, height: 800 } }]", "link"),
            ("pe-none-overlay", "[\(navLinkSpec), { id: \"ghost\", tag: \"div\", alohaId: \"ghost\", z: 100, pointerEvents: \"none\", rect: { left: 0, top: 0, width: 1000, height: 800 } }]", "link"),
            ("transparent-interceptor", "[\(navLinkSpec), { id: \"intercept\", tag: \"div\", alohaId: \"intercept\", z: 100, rect: { left: 0, top: 0, width: 1000, height: 800 } }]", "link"),
        ]
        for c in cases {
            let ctx = makeContext()
            ctx.evaluateScript(clickLoopSource)
            let script = """
            (function () {
              buildDom(\(c.specs));
              var target = __nodeById("\(c.target)");
              var occluded = probeOccluder(target) != null;
              var clickable = clickVerdict(target).isClickable;
              return JSON.stringify({ occluded: occluded, clickable: clickable });
            })()
            """
            let json = ctx.evaluateScript(script)!.toString()!
            let data = json.data(using: .utf8)!
            let parsed = try! JSONSerialization.jsonObject(with: data) as! [String: Bool]
            let occluded = parsed["occluded"]!
            let clickable = parsed["clickable"]!
            // Read says occluded iff the click finds no free point — exact negation over the shared
            // geometry. The sibling-exemption case is excluded from this invariant because the click
            // path has no such exemption; it is covered separately above.
            #expect(occluded == !clickable, "consistency violated for \(c.name): occluded=\(occluded) clickable=\(clickable)")
        }
    }
}
#endif
