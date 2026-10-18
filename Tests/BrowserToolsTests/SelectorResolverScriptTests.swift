import Testing
import Foundation
@testable import BrowserTools

/// The resolver's Swift surface, checked without a JavaScript engine: these run on Linux too.
@Suite struct SelectorResolverScriptSurfaceTests {

    /// The namespace name is a contract with the agent's scenarios and the receipt probes: both
    /// address `window.__snips.resolveAll`, and a rename here would break every minted scenario.
    @Test func theSourceInstallsTheSnipsNamespace() {
        let source = SelectorResolverScript.source
        #expect(source.contains("window.__snips = NS"))
        #expect(source.contains("NS.resolveAll = function"))
        #expect(source.contains("NS.resolveFirst = function"))
        #expect(source.contains("NS.relHrefOf = function"))
        #expect(source.contains("// BEGIN selector-resolver js"))
        #expect(source.contains("// END selector-resolver js"))
        // Statements, then the sentinel on its own line: a trailing `//` comment must never
        // swallow the expression that follows (see the overlay hider's history).
        #expect(SelectorResolverScript.installIfNeeded.hasSuffix("\n;'installed'"))
        #expect(SelectorResolverScript.isInstalledProbe.contains("window.__snips.resolveAll"))
    }

    /// `pseudoClasses` mirrors the JS `PROC` list; this is what keeps the two from drifting.
    @Test func theSwiftPseudoListMatchesTheScriptsPROC() throws {
        let source = SelectorResolverScript.source
        let start = try #require(source.range(of: "const PROC = ["))
        let end = try #require(source[start.upperBound...].range(of: "]"))
        let listed = source[start.upperBound..<end.lowerBound]
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
        #expect(listed == SelectorResolverScript.pseudoClasses)
    }
}

#if canImport(JavaScriptCore)
import JavaScriptCore

/// Runs the shipped resolver inside a JavaScriptCore context against a flat fake document: the
/// bytes that reach the page compile, install under `window.__snips`, and resolve the shapes a
/// receipt anchor carries. `URL` is a DOM API, so the link pseudos (`:rel-href`, `:sub-path`) are
/// covered by `selector_resolver.js` under Node, not here.
@Suite struct SelectorResolverScriptTests {

    /// A window, a flat fake `document`, and elements with the few members the resolver reads.
    private static let fakeDOM = """
    var window = this;
    function el(tag, cls, text, attrs) {
      attrs = attrs || {};
      return { tagName: tag.toUpperCase(), className: cls || '', textContent: text || '',
               parentElement: null,
               hasAttribute: function (k) { return k in attrs; },
               getAttribute: function (k) { return (k in attrs) ? attrs[k] : null; } };
    }
    function matches(e, q) {
      q = q.trim(); if (q === '*') return true;
      var m = /^([a-z]*)((?:\\.[\\w-]+)*)$/.exec(q); if (!m) throw new Error('fake engine cannot parse ' + q);
      if (m[1] && e.tagName.toLowerCase() !== m[1]) return false;
      return m[2].split('.').filter(Boolean).every(function (c) { return e.className.split(/\\s+/).indexOf(c) !== -1; });
    }
    function makeDoc(els) { return { querySelectorAll: function (q) { return els.filter(function (e) { return matches(e, q); }); } }; }
    var document = makeDoc([]);
    var location = { href: 'https://site.example/' };
    var sOut = el('button', 'size', 'SComing soon');
    var mIn = el('button', 'size', 'M');
    var lIn = el('button', 'size', 'L', { 'data-qa-action': 'size-in-stock' });
    var icon = el('a', 'nav', '', { 'aria-label': 'More target languages' });
    var doc = makeDoc([sOut, mIn, lIn, icon]);
    var texts = function (ns) { return ns.map(function (e) { return e.textContent; }).join('|'); };
    """

    private func context() throws -> JSContext {
        let context = try #require(JSContext())
        context.exceptionHandler = { _, exception in
            Issue.record("JS exception: \(exception?.toString() ?? "unknown")")
        }
        context.evaluateScript(Self.fakeDOM)
        return context
    }

    private func evaluate(_ expression: String, in context: JSContext) throws -> String {
        try #require(context.evaluateScript(expression)?.toString())
    }

    @Test func theSourceCompilesAndInstallsOnce() throws {
        let context = try context()
        #expect(try evaluate(SelectorResolverScript.isInstalledProbe, in: context) == "n")
        #expect(try evaluate(SelectorResolverScript.installIfNeeded, in: context) == "installed")
        #expect(try evaluate(SelectorResolverScript.isInstalledProbe, in: context) == "y")
        // A second install leaves the same object in place.
        context.evaluateScript("var first = window.__snips;")
        #expect(try evaluate(SelectorResolverScript.installIfNeeded, in: context) == "installed")
        #expect(try evaluate("String(window.__snips === first)", in: context) == "true")
    }

    @Test func aQuotedTextAnchorPrefersTheWholeTextMatch() throws {
        let context = try context()
        _ = try evaluate(SelectorResolverScript.installIfNeeded, in: context)
        // "SComing soon" contains an m; the quoted anchor picks the button whose whole text is M.
        #expect(try evaluate(#"texts(window.__snips.resolveAll('button.size:has-text("M")', doc))"#, in: context) == "M")
        // The bare form keeps uBlock's substring semantics.
        #expect(try evaluate(#"String(window.__snips.resolveAll('button.size:has-text(M)', doc).length)"#, in: context) == "2")
        // An empty quoted anchor matches nothing rather than everything.
        #expect(try evaluate(#"String(window.__snips.resolveAll('button.size:has-text("")', doc).length)"#, in: context) == "0")
    }

    @Test func attributesOrdinalsAndFirstResolve() throws {
        let context = try context()
        _ = try evaluate(SelectorResolverScript.installIfNeeded, in: context)
        #expect(try evaluate(#"texts(window.__snips.resolveAll('button.size:matches-attr(data-qa-action="size-in-stock")', doc))"#, in: context) == "L")
        #expect(try evaluate(#"texts(window.__snips.resolveAll('button.size:nth-match(2)', doc))"#, in: context) == "M")
        #expect(try evaluate(#"String(window.__snips.resolveAll('button.size:nth-match(4)', doc).length)"#, in: context) == "0")
        // A textless icon resolves by its aria-label; resolveFirst hands back that element.
        #expect(try evaluate(#"String(window.__snips.resolveFirst('a.nav:has-text("More target languages")', doc) === icon)"#, in: context) == "true")
        #expect(try evaluate(#"String(window.__snips.resolveFirst('a.nav:has-text("Nothing here")', doc))"#, in: context) == "null")
        // A CSS part the engine refuses is an empty answer, never an exception.
        #expect(try evaluate(#"String(window.__snips.resolveAll('button[', doc).length)"#, in: context) == "0")
    }
}
#endif
