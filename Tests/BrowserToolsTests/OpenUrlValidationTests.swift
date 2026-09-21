import Foundation
import Testing
import ToolABI
@testable import BrowserTools

// `validateOpenUrl` is the package's only defence against a model that just read a
// hostile page asking a browser tool to fetch `file:///Users/you/.ssh/id_rsa`. Two
// halves have to hold, and only one of them is a pure function:
//
//   1. the validator rejects everything that is not http(s), and
//   2. every entry point that can reach `Page.navigate` actually calls it.
//
// The second half is what failed in the shipped version — `page_navigate` was the one
// navigation path that skipped the check — so it is asserted here explicitly, per file,
// rather than left to the reader to notice.

@Suite("open-url validation")
struct OpenUrlValidationTests {

    // MARK: - Schemes

    /// Every scheme a browser will actually act on, and one made-up one. `file:` gets its
    /// own message because it is the exfiltration case and the caller deserves to know
    /// why it was refused rather than being told its URL was "malformed".
    @Test("file:// is rejected with the file-specific reason", arguments: [
        "file:///etc/hosts",
        "file:///Users/someone/.ssh/id_rsa",
        "FILE:///etc/hosts",
        "file://localhost/etc/passwd",
    ])
    func fileIsRejected(_ url: String) {
        #expect(validateOpenUrl(url) == .rejected(reason: urlFileProtocolReason))
    }

    /// Each carries the reason the caller is actually handed: a scheme the parser can read an
    /// authority out of is named in the bad-protocol message, while an opaque `scheme:payload`
    /// never parses as an absolute browser URL and is refused as malformed before the scheme
    /// is ever considered. The `data:` payload below falls in the first group because the
    /// `http://evil` inside it is enough `://` for the parse — still refused, differently worded.
    @Test("no other scheme reaches the browser", arguments: [
        ("javascript:alert(1)", urlMalformedReason),
        ("data:text/html,<script>fetch('http://evil')</script>", urlBadProtocolReason("data:")),
        ("chrome://settings", urlBadProtocolReason("chrome:")),
        ("devtools://devtools/bundled/inspector.html", urlBadProtocolReason("devtools:")),
        ("view-source:https://example.com", urlBadProtocolReason("view-source:")),
        ("ftp://example.com/x", urlBadProtocolReason("ftp:")),
        ("blob:https://example.com/1234", urlBadProtocolReason("blob:")),
        ("about:blank", urlMalformedReason),
        ("ws://127.0.0.1:9222/devtools/browser/x", urlBadProtocolReason("ws:")),
        ("vbscript:msgbox(1)", urlMalformedReason),
        ("intent://scan/#Intent;scheme=zxing;end", urlBadProtocolReason("intent:")),
        ("myapp://settings", urlBadProtocolReason("myapp:")),
    ])
    func otherSchemesAreRejected(_ url: String, _ reason: String) {
        #expect(validateOpenUrl(url) == .rejected(reason: reason))
    }

    /// The normalized href a passing URL yields is the input itself — validation must not
    /// quietly rewrite the address the caller asked for.
    @Test("http and https pass", arguments: [
        "http://example.com/",
        "https://example.com/",
        "HTTPS://Example.COM/path?q=1#frag",
        "http://127.0.0.1:8731/",
        "https://example.com:8443/a/b",
    ])
    func webSchemesPass(_ url: String) {
        #expect(validateOpenUrl(url) == .ok(normalized: url))
    }

    /// The scheme is normalized to lower case before the comparison, so an upper-case
    /// `HTTP:` cannot slip past a case-sensitive equality check.
    @Test func schemeComparisonIsCaseInsensitive() {
        #expect(validateOpenUrl("HtTpS://example.com/") == .ok(normalized: "HtTpS://example.com/"))
    }

    // MARK: - Shape

    @Test("empty, oversized, control-bearing and schemeless input is malformed", arguments: [
        "", "   ", "example.com", "//example.com/x", "http:example.com",
        "https://exa\u{0}mple.com/", "https://example.com/\u{1}", "https://example.com/\u{7f}",
    ])
    func malformedIsRejected(_ url: String) {
        #expect(validateOpenUrl(url) == .rejected(reason: urlMalformedReason))
    }

    /// Surrounding whitespace is trimmed BEFORE the control-character scan, so a URL
    /// pasted with a trailing newline is accepted rather than reported as malformed.
    @Test func surroundingWhitespaceIsTrimmedNotRejected() {
        #expect(validateOpenUrl("  https://example.com/\n") == .ok(normalized: "https://example.com/"))
    }

    @Test func nilIsMalformedNotACrash() {
        #expect(validateOpenUrl(nil) == .rejected(reason: urlMalformedReason))
    }

    @Test func oversizedIsRejectedAtTheBoundary() {
        let padding = String(repeating: "a", count: maxUrlLength)
        #expect(validateOpenUrl("https://example.com/" + padding) == .rejected(reason: urlMalformedReason))
        // One character under the cap still passes, so the cap is a cap and not an
        // accidental rejection of every long URL.
        let head = "https://example.com/"
        let justUnder = head + String(repeating: "a", count: maxUrlLength - head.count - 1)
        #expect(validateOpenUrl(justUnder) == .ok(normalized: justUnder))
    }

    @Test("credentials in the authority are rejected", arguments: [
        "https://user:password@example.com/",
        "http://admin:hunter2@127.0.0.1:8080/",
    ])
    func credentialsAreRejected(_ url: String) {
        #expect(validateOpenUrl(url) == .rejected(reason: urlCredentialsReason))
    }

    // MARK: - The tab wrapper

    @Test func tabValidationIsTheSameFunction() {
        #expect(validateTabUrl(TabUrlInput(url: "file:///etc/hosts"))
                == .rejected(reason: urlFileProtocolReason))
        #expect(validateTabUrl(TabUrlInput(url: nil)) == .rejected(reason: urlMalformedReason))
        #expect(validateTabUrl(TabUrlInput(url: "https://example.com/"))
                == .ok(normalized: "https://example.com/"))
    }

    // MARK: - Every entry point calls it

    /// The defect this pins: `page_navigate` was the ONE navigation entry point that
    /// never called the validator, so `goto file:///…` followed by `get_text` was a
    /// working local-file read. A source-level assertion, because the alternative is a
    /// live browser and a real secret file in a unit test.
    @Test("no navigation entry point skips the validator", arguments: [
        // file, the symbol it must contain
        ("Sources/BrowserTools/Tools/PageNavigate.swift", "validateOpenUrl"),
        ("Sources/BrowserTools/Tools/ManageTabs.swift", "validateOpenUrl"),
        ("Sources/BrowserTools/Tools/PageToolsSupport.swift", "validateTabUrl"),
        ("Sources/BrowserTools/Tabs/CDPTabsService.swift", "validateOpenUrl"),
    ])
    func everyEntryPointValidates(_ path: String, _ symbol: String) throws {
        let source = try packageSource(path)
        #expect(source.contains("\(symbol)("), "\(path) reaches navigation without \(symbol)")
    }

    /// `page_navigate` must navigate to the NORMALIZED href the validator returns, not to
    /// the raw argument it was handed — otherwise the check and the navigation are
    /// looking at two different strings.
    @Test func pageNavigateUsesTheNormalizedHref() throws {
        let source = try packageSource("Sources/BrowserTools/Tools/PageNavigate.swift")
        #expect(source.contains("bridge.goto(normalized)"),
                "page_navigate navigates to something other than the validated href")
    }
}

/// A package-relative source file, located from `#filePath` rather than from the working
/// directory: read relatively, a source-level assertion reads nothing and silently passes
/// whenever the suite is run from anywhere but the package root.
func packageSource(_ path: String) throws -> String {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // BrowserToolsTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // package root
        .appendingPathComponent(path)
    let source = try String(contentsOf: url, encoding: .utf8)
    try #require(!source.isEmpty, "\(path) is empty")
    return source
}
