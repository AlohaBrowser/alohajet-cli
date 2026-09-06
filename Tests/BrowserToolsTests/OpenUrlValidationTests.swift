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
        #expect(validateOpenUrl(url) == .rejected(reason: URL_FILE_PROTOCOL_REASON))
    }

    @Test("no other scheme reaches the browser", arguments: [
        "javascript:alert(1)",
        "data:text/html,<script>fetch('http://evil')</script>",
        "chrome://settings",
        "devtools://devtools/bundled/inspector.html",
        "view-source:https://example.com",
        "ftp://example.com/x",
        "blob:https://example.com/1234",
        "about:blank",
        "ws://127.0.0.1:9222/devtools/browser/x",
        "vbscript:msgbox(1)",
        "intent://scan/#Intent;scheme=zxing;end",
        "myapp://settings",
    ])
    func otherSchemesAreRejected(_ url: String) {
        guard case let .rejected(reason) = validateOpenUrl(url) else {
            Issue.record("\(url) was accepted")
            return
        }
        // Either the bad-protocol message or the malformed one — never `.ok`.
        #expect(reason != URL_FILE_PROTOCOL_REASON)
    }

    @Test("http and https pass", arguments: [
        "http://example.com/",
        "https://example.com/",
        "HTTPS://Example.COM/path?q=1#frag",
        "http://127.0.0.1:8731/",
        "https://example.com:8443/a/b",
    ])
    func webSchemesPass(_ url: String) {
        guard case .ok = validateOpenUrl(url) else {
            Issue.record("\(url) was rejected")
            return
        }
    }

    /// The scheme is normalized to lower case before the comparison, so an upper-case
    /// `HTTP:` cannot slip past a case-sensitive equality check.
    @Test func schemeComparisonIsCaseInsensitive() {
        #expect(validateOpenUrl("HtTpS://example.com/") != .rejected(reason: URL_MALFORMED_REASON))
    }

    // MARK: - Shape

    @Test("empty, oversized, control-bearing and schemeless input is malformed", arguments: [
        "", "   ", "example.com", "//example.com/x", "http:example.com",
        "https://exa\u{0}mple.com/", "https://example.com/\u{1}", "https://example.com/\u{7f}",
    ])
    func malformedIsRejected(_ url: String) {
        #expect(validateOpenUrl(url) == .rejected(reason: URL_MALFORMED_REASON))
    }

    /// Surrounding whitespace is trimmed BEFORE the control-character scan, so a URL
    /// pasted with a trailing newline is accepted rather than reported as malformed.
    @Test func surroundingWhitespaceIsTrimmedNotRejected() {
        guard case let .ok(normalized) = validateOpenUrl("  https://example.com/\n") else {
            Issue.record("a trailing newline made a valid URL malformed")
            return
        }
        #expect(!normalized.contains("\n"))
    }

    @Test func nilIsMalformedNotACrash() {
        #expect(validateOpenUrl(nil) == .rejected(reason: URL_MALFORMED_REASON))
    }

    @Test func oversizedIsRejectedAtTheBoundary() {
        let padding = String(repeating: "a", count: MAX_URL_LENGTH)
        #expect(validateOpenUrl("https://example.com/" + padding) == .rejected(reason: URL_MALFORMED_REASON))
        // One character under the cap still passes, so the cap is a cap and not an
        // accidental rejection of every long URL.
        let head = "https://example.com/"
        let justUnder = head + String(repeating: "a", count: MAX_URL_LENGTH - head.count - 1)
        guard case .ok = validateOpenUrl(justUnder) else {
            Issue.record("a URL one byte under the cap was rejected")
            return
        }
    }

    @Test("credentials in the authority are rejected", arguments: [
        "https://user:password@example.com/",
        "http://admin:hunter2@127.0.0.1:8080/",
    ])
    func credentialsAreRejected(_ url: String) {
        #expect(validateOpenUrl(url) == .rejected(reason: URL_CREDENTIALS_REASON))
    }

    // MARK: - The tab wrapper

    @Test func tabValidationIsTheSameFunction() {
        #expect(validateTabUrl(TabUrlInput(url: "file:///etc/hosts"))
                == .rejected(reason: URL_FILE_PROTOCOL_REASON))
        #expect(validateTabUrl(TabUrlInput(url: nil)) == .rejected(reason: URL_MALFORMED_REASON))
        guard case .ok = validateTabUrl(TabUrlInput(url: "https://example.com/")) else {
            Issue.record("a https tab was rejected")
            return
        }
    }

    // MARK: - Every entry point calls it

    /// The defect this pins: `page_navigate` was the ONE navigation entry point that
    /// never called the validator, so `goto file:///…` followed by `get_text` was a
    /// working local-file read. A source-level assertion, because the alternative is a
    /// live browser and a real secret file in a unit test.
    ///
    /// Skipped rather than failed when the sources are not on disk (a test bundle run
    /// from elsewhere): a false failure on cwd teaches people to ignore the test.
    @Test("no navigation entry point skips the validator", arguments: [
        // file, the symbol it must contain
        ("Sources/BrowserTools/Tools/PageNavigate.swift", "validateOpenUrl"),
        ("Sources/BrowserTools/Tools/ManageTabs.swift", "validateOpenUrl"),
        ("Sources/BrowserTools/Tools/PageToolsSupport.swift", "validateTabUrl"),
        ("Sources/BrowserTools/Tabs/CDPTabsService.swift", "validateOpenUrl"),
    ])
    func everyEntryPointValidates(_ path: String, _ symbol: String) {
        guard let source = try? String(contentsOfFile: path, encoding: .utf8), !source.isEmpty else { return }
        #expect(source.contains("\(symbol)("), "\(path) reaches navigation without \(symbol)")
    }

    /// `page_navigate` must navigate to the NORMALIZED href the validator returns, not to
    /// the raw argument it was handed — otherwise the check and the navigation are
    /// looking at two different strings.
    @Test func pageNavigateUsesTheNormalizedHref() {
        let path = "Sources/BrowserTools/Tools/PageNavigate.swift"
        guard let source = try? String(contentsOfFile: path, encoding: .utf8), !source.isEmpty else { return }
        #expect(source.contains("bridge.goto(normalized)"),
                "page_navigate navigates to something other than the validated href")
    }
}
