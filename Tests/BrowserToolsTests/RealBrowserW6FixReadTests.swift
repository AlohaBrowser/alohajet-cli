import Foundation
import Testing
import CDP
import ToolABI
@testable import BrowserTools

// THE W6 CLIENT REVIEW'S READ FINDINGS, in a real headless Chromium (the review's own fixtures):
// a key in a plain text field, a lone "0", a separator between two numbers, a sentence holding a
// link, a tri-state box, a box hidden behind a widget, an unlabelled box with a value, and a span
// whose label repeated its words. Unit half: `W6FixReadUnitTests`.
//
// Skipped without a browser, like `RealBrowserE2ETests`; `ALOHAJET_REQUIRE_BROWSER=1` makes a
// missing browser a failure.

private nonisolated let w6fixBrowserIsAvailable = ChromeLauncher().isAvailable
private nonisolated let w6fixBrowserIsRequired = ProcessInfo.processInfo.environment["ALOHAJET_REQUIRE_BROWSER"] == "1"

private let valuesHTML = """
<!doctype html><html><head><title>Values</title></head><body>
<h1>Account</h1>
<form onsubmit="return false">
<input id="user" name="username" aria-label="Username" value="tomsmith">
<input id="apikey" name="api_key" aria-label="API key" value="sk-live-abcdef123456">
<input id="tok" name="accessToken" aria-label="Access" value="opaque-0a1b2c3d4e5f">
<input id="shape" aria-label="Paste here" value="ghp_abcdefghijklmnopqrstuvwxyz0123">
<input id="rec" aria-label="Recovery code" value="ABCD-EFGH-IJKL">
<textarea id="seed" aria-label="Seed phrase">apple banana cherry delta echo foxtrot</textarea>
<input id="city" name="city" aria-label="City" value="Tokyo">
<input id="job" name="secretary_name" aria-label="Secretary" value="Jane Roe">
</form>
</body></html>
"""

private let shortHTML = """
<!doctype html><html><head><title>Short</title></head><body>
<h1>Short leaves</h1>
<span class="todo-count"><strong>0</strong> items left</span>
<p>Rating: <span>4</span>/<span>5</span></p>
<p>Opens at <span>10</span>:<span>30</span></p>
<div class="badge">1</div>
<div class="zero-badge">0</div>
<span class="grade">A</span>
<div class="pager">Step <b>3</b> of <b>4</b>: <a href="#edit">Edit</a></div>
<div class="nested"><span>You have <b>2</b> new <em>alerts</em></span></div>
</body></html>
"""

private let checksHTML = """
<!doctype html><html><head><title>Checks</title></head><body>
<h1>Settings</h1>
<form onsubmit="return false">
<p><input type="checkbox" id="c3" value="yes"></p>
<p><input type="checkbox" id="ind"><label for="ind">Select all</label></p>
<p><label class="rct"><input type="checkbox" id="home" style="display:none" checked><span class="rct-checkbox">[x]</span><span class="rct-title">Home folder</span></label></p>
<p><label class="rct"><input type="checkbox" id="desk" style="display:none"><span class="rct-checkbox">[ ]</span><span class="rct-title">Desktop</span></label></p>
<p><input type="radio" name="g" id="r1" value="yes" checked><label for="r1">Yes</label></p>
</form>
<script>document.getElementById('ind').indeterminate = true;</script>
</body></html>
"""

@MainActor
private func markdown(_ output: String) -> [String] {
    guard let start = output.range(of: "<interactive_page_markdown>"),
          let end = output.range(of: "</interactive_page_markdown>") else { return [] }
    return output[start.upperBound..<end.lowerBound].split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
}

@MainActor
private func alohaId(of line: String) -> String? {
    guard let marker = line.range(of: "{aloha-id=\"") else { return nil }
    let rest = line[marker.upperBound...]
    return rest.firstIndex(of: "\"").map { String(rest[..<$0]) }
}

@Suite("end to end, real browser: the W6 review's read findings", .serialized,
       .enabled(if: w6fixBrowserIsAvailable || w6fixBrowserIsRequired))
struct RealBrowserW6FixReadTests {

    /// A key, a token, a recovery code or a seed phrase in a plain text field reads
    /// `value=(hidden)`, by its name or label or by the shape of its value; `get_text` on it
    /// returns the mask. A field whose name merely contains such a word ("secretary") does not.
    @Test func aKeyInAPlainTextFieldIsHidden() async throws {
        try #require(w6fixBrowserIsAvailable)
        let server = LocalPageServer(html: valuesHTML)
        try server.start()
        defer { server.stop() }
        try await withHeadlessBrowser { session in
            let opened = await session.run("manage_tabs", arguments: ["action": "open", "url": server.url])
            #expect(opened.isError != true, "\(opened.output)")
            let page = opened.output
            for secret in ["sk-live-abcdef123456", "opaque-0a1b2c3d4e5f", "ghp_abcdefghijklmnopqrstuvwxyz0123", "ABCD-EFGH-IJKL", "apple banana"] {
                #expect(!page.contains(secret), "\(secret) leaked:\n\(page)")
            }
            let lines = markdown(page)
            #expect(lines.contains { $0.hasPrefix(#"input("API key", value=(hidden))"#) }, "\(page)")
            #expect(lines.contains { $0.hasPrefix(#"input("Recovery code", value=(hidden))"#) }, "\(page)")
            #expect(lines.contains { $0.hasPrefix(#"textarea("Seed phrase", value=(hidden))"#) }, "\(page)")
            #expect(lines.contains { $0.hasPrefix(#"input("Username", value="tomsmith")"#) }, "\(page)")
            #expect(lines.contains { $0.hasPrefix(#"input("City", value="Tokyo")"#) }, "\(page)")
            #expect(lines.contains { $0.hasPrefix(#"input("Secretary", value="Jane Roe")"#) }, "\(page)")
            let key = try #require(lines.first { $0.hasPrefix(#"input("API key""#) }.flatMap(alohaId))
            let text = await session.run("get_text", arguments: ["aloha_id": key])
            #expect(!text.output.contains("sk-live"), "\(text.output)")
        }
    }

    /// A lone "0" is chrome; "4/5" and "10:30" keep their separator; a sentence holding a link
    /// reads as one line with the link in place; a span's label says its words once.
    @Test func shortLeavesReadAsThePageShowsThem() async throws {
        try #require(w6fixBrowserIsAvailable)
        let server = LocalPageServer(html: shortHTML)
        try server.start()
        defer { server.stop() }
        try await withHeadlessBrowser { session in
            let opened = await session.run("manage_tabs", arguments: ["action": "open", "url": server.url])
            #expect(opened.isError != true, "\(opened.output)")
            let lines = markdown(opened.output)
            #expect(lines.contains("0 items left"), "\(opened.output)")
            #expect(lines.contains("Rating: 4/5"), "\(opened.output)")
            #expect(lines.contains("Opens at 10:30"), "\(opened.output)")
            #expect(lines.contains("1"), "the badge's count is a line:\n\(opened.output)")
            #expect(lines.contains("A"), "the grade is a line:\n\(opened.output)")
            #expect(!lines.contains("0"), "a lone zero is chrome:\n\(opened.output)")
            #expect(lines.contains { $0.hasPrefix("Step 3 of 4 [Edit] {aloha-id=") }, "\(opened.output)")
            #expect(!lines.contains("Step") && !lines.contains("of"), "\(opened.output)")
            #expect(lines.contains { $0.hasPrefix("[You have 2 new alerts]") }, "\(opened.output)")
            #expect(!opened.output.contains("You have new You have"), "\(opened.output)")
        }
    }

    /// A tri-state box reads "partly checked"; a box hidden behind a widget of the page's own
    /// lends its state to its label, which a click toggles; an unlabelled box does not print its
    /// value as a label.
    @Test func checkboxStatesThePageHidesOrLeavesUnlabelled() async throws {
        try #require(w6fixBrowserIsAvailable)
        let server = LocalPageServer(html: checksHTML)
        try server.start()
        defer { server.stop() }
        try await withHeadlessBrowser { session in
            let opened = await session.run("manage_tabs", arguments: ["action": "open", "url": server.url])
            #expect(opened.isError != true, "\(opened.output)")
            let lines = markdown(opened.output)
            #expect(lines.contains { $0.hasPrefix(#"input(checkbox, partly checked, "Select all")"#) }, "\(opened.output)")
            #expect(lines.contains { $0.hasPrefix("input(checkbox, unchecked) {aloha-id=") }, "\(opened.output)")
            #expect(!opened.output.contains(#""yes")"#), "\(opened.output)")
            #expect(lines.contains { $0.hasPrefix(#"input(radio, checked, "Yes")"#) }, "\(opened.output)")
            let home = try #require(lines.first { $0.contains("Home folder]") }, "\(opened.output)")
            #expect(home.contains("[checkbox: checked]") && home.hasSuffix(" label}"), "\(home)")
            let desk = try #require(lines.first { $0.contains("Desktop]") }, "\(opened.output)")
            #expect(desk.contains("[checkbox: unchecked]"), "\(desk)")

            let deskId = try #require(alohaId(of: desk))
            let clicked = await session.run("page_click", arguments: ["aloha_id": deskId])
            #expect(clicked.isError != true, "\(clicked.output)")
            let reread = await session.run("manage_tabs", arguments: ["action": "read"])
            let after = try #require(markdown(reread.output).first { $0.contains("Desktop]") }, "\(reread.output)")
            #expect(after.contains("[checkbox: checked]"), "the click on the label ticked the hidden box:\n\(after)")
        }
    }
}
