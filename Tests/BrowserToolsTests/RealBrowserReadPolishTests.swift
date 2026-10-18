import Foundation
import Testing
import CDP
import ToolABI
@testable import BrowserTools

// THE READ AND THE CLICK RECEIPT ON THE PAGE SHAPES THE 2026-10-18 e2e RUN AND ITS REVIEW TRIPPED ON,
// in a real headless Chromium: checkbox state (the-internet /checkboxes), a count inside its
// sentence (TodoMVC), an editor and a clickable row holding many controls, preformatted text, a page
// that changes on its own (a clock), and a read with no tab_id. Unit half: `ReadPolishTests`.
//
// Skipped without a browser, like `RealBrowserE2ETests`; `ALOHAJET_REQUIRE_BROWSER=1` makes a
// missing browser a failure.

private nonisolated let polishBrowserIsAvailable = ChromeLauncher().isAvailable
private nonisolated let polishBrowserIsRequired = ProcessInfo.processInfo.environment["ALOHAJET_REQUIRE_BROWSER"] == "1"

private let formsHTML = """
<!doctype html><html><head><title>Checkboxes</title></head><body>
<h3>Checkboxes</h3>
<form id="checkboxes"><input type="checkbox" id="box1"> checkbox 1<br><input type="checkbox" checked> checkbox 2</form>
<fieldset><legend>Size</legend><label><input type="radio" name="s" value="small"> Small</label><label><input type="radio" name="s" value="large" checked> Large</label></fieldset>
<div role="checkbox" aria-checked="true" tabindex="0">Remember me</div>
<section class="todoapp"><ul class="todo-list"><li>Walk the dog</li></ul>
<footer class="footer"><span class="todo-count"><strong>1</strong> item left</span></footer></section>
<div class="pager">Page <b>2</b> of <b>9</b></div>
<a href="#cart" id="cart">Cart</a><span class="badge">3</span>
<pre id="code">line one
line two
line three</pre>
</body></html>
"""

private let editorHTML = """
<!doctype html><html><head><title>Editor</title></head><body>
<div id="editor" contenteditable="true" aria-label="Message body">Hello <a href="/a">one</a> <a href="/b">two</a> <a href="/c">three</a> <a href="/d">four</a></div>
<table><tr id="row" onclick="location.hash='row'"><td>Row one long text</td><td><button>A</button><button>B</button><button>C</button><button>D</button></td></tr></table>
</body></html>
"""

/// A clock and a ticker rewrite themselves ten times a second; one button does nothing, one saves.
private let livePageHTML = """
<!doctype html><html><head><title>Live page</title></head><body>
<div id="clock"></div><div id="ticker"><span>tick 0</span></div>
<button id="inert">Does nothing</button>
<button id="save" onclick="var p=document.createElement('p');p.textContent='Saved your settings';document.body.appendChild(p)">Save</button>
<script>var n=0;setInterval(function(){document.getElementById('clock').textContent=new Date().toISOString();n++;document.getElementById('ticker').innerHTML='<span>tick '+n+'</span>';},100);</script>
</body></html>
"""

@MainActor
private func elementId(forLabel label: String, kind: String, in markdown: String) -> String? {
    for line in markdown.split(separator: "\n") where line.contains(label) && line.contains(" \(kind)}") {
        guard let marker = line.range(of: "{aloha-id=\"") else { continue }
        let rest = line[marker.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { continue }
        return String(rest[..<end])
    }
    return nil
}

@MainActor
private func lines(_ page: String) -> [String] {
    page.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
}

@Suite("end to end, real browser: the read's polish", .serialized, .enabled(if: polishBrowserIsAvailable || polishBrowserIsRequired))
struct RealBrowserReadPolishTests {

    /// Checkbox / radio / aria-checked state, a count inside its sentence, a badge, `<pre>` lines;
    /// a click on a checkbox shows in the next read; `read` with no tab_id reads the tab in use.
    @Test func theReadSaysWhatIsCheckedAndKeepsShortValues() async throws {
        try #require(polishBrowserIsAvailable)
        let server = LocalPageServer(html: formsHTML)
        try server.start()
        defer { server.stop() }

        try await withHeadlessBrowser { session in
            let opened = await session.run("manage_tabs", arguments: ["action": "open", "url": server.url])
            #expect(opened.isError != true, "open failed: \(opened.output)")
            let page = opened.output
            let all = lines(page)
            #expect(all.contains { $0.hasPrefix("input(checkbox, unchecked) {aloha-id=") }, "\(page)")
            #expect(all.contains { $0.hasPrefix("input(checkbox, checked) {aloha-id=") }, "\(page)")
            #expect(all.contains { $0.hasPrefix(#"input(radio, checked, "Large")"#) }, "\(page)")
            #expect(all.contains { $0.hasPrefix(#"input(radio, unchecked, "Small")"#) }, "\(page)")
            #expect(page.contains("[Remember me] [aria: CHECKED]"), "\(page)")
            #expect(!page.contains("value=\"on\""), "\(page)")
            #expect(all.contains("1 item left"), "\(page)")
            #expect(all.contains("Page 2 of 9"), "\(page)")
            #expect(all.contains("3"), "the cart badge's count is a line:\n\(page)")
            #expect(page.contains("line one\nline two\nline three"), "\(page)")

            // Tick the first box; a read WITHOUT a tab_id reads the tab in use and shows it ticked.
            let box = try #require(all.first { $0.hasPrefix("input(checkbox, unchecked)") })
            let boxId = try #require(elementId(forLabel: "input(checkbox, unchecked)", kind: "input", in: box))
            let clicked = await session.run("page_click", arguments: ["aloha_id": boxId])
            #expect(clicked.isError != true, "\(clicked.output)")
            let reread = await session.run("manage_tabs", arguments: ["action": "read"])
            #expect(reread.isError != true, "\(reread.output)")
            #expect(reread.output.contains("Checkboxes ["), "a read with no tab_id names the tab in use:\n\(reread.output)")
            #expect(!lines(reread.output).contains { $0.hasPrefix("input(checkbox, unchecked)") }, "\(reread.output)")
        }
    }

    /// An editor holding four links keeps its own line and id (page_type types into it), and a
    /// clickable row holding four buttons keeps its id (W5 client review, finding 1).
    @Test func anEditorAndAClickableRowKeepTheirIds() async throws {
        try #require(polishBrowserIsAvailable)
        let server = LocalPageServer(html: editorHTML)
        try server.start()
        defer { server.stop() }

        try await withHeadlessBrowser { session in
            let opened = await session.run("manage_tabs", arguments: ["action": "open", "url": server.url])
            #expect(opened.isError != true, "open failed: \(opened.output)")
            let editor = try #require(elementId(forLabel: "[Message body]", kind: "div", in: opened.output), "\(opened.output)")
            #expect(elementId(forLabel: "[Row one long text]", kind: "tr", in: opened.output) != nil, "\(opened.output)")
            for label in ["[one]", "[four]", "[A]", "[D]"] {
                #expect(opened.output.contains(label), "\(label) lost:\n\(opened.output)")
            }
            let typed = await session.run("page_type", arguments: ["aloha_id": editor, "text": "Typed into the editor"])
            #expect(typed.isError != true, "\(typed.output)")
            let tabId = try #require(tabIdentifier(opened))
            let tab = try #require(session.tabs?.tab(tabId) as? CDPTabHandle)
            let backend = CDPAgentBridgeBackend(tab: tab, signal: AbortSignal())
            let body = try await backend.evaluateViaCdp("document.getElementById('editor').textContent")?.stringValue ?? ""
            #expect(body.contains("Typed into the editor"), "\(body)")
        }
    }

    /// A page that changes on its own: an inert button is still a no-op, and a real one quotes only
    /// what IT made appear, not the clock (W5 client review, finding 2).
    @Test func aPageThatChangesOnItsOwnIsNotAClickEffect() async throws {
        try #require(polishBrowserIsAvailable)
        let server = LocalPageServer(html: livePageHTML)
        try server.start()
        defer { server.stop() }

        try await withHeadlessBrowser { session in
            let opened = await session.run("manage_tabs", arguments: ["action": "open", "url": server.url])
            #expect(opened.isError != true, "open failed: \(opened.output)")
            let inert = try #require(elementId(forLabel: "[Does nothing]", kind: "button", in: opened.output), "\(opened.output)")
            let save = try #require(elementId(forLabel: "[Save]", kind: "button", in: opened.output), "\(opened.output)")
            // The model's round between the read and the click.
            try await Task.sleep(nanoseconds: 1_000_000_000)

            let idle = await session.run("page_click", arguments: ["aloha_id": inert])
            #expect(idle.output.contains("That click did NOTHING observable"), "\(idle.output)")
            #expect(!idle.output.contains("new text is showing"), "\(idle.output)")

            let saved = await session.run("page_click", arguments: ["aloha_id": save])
            #expect(!saved.output.contains("NOTHING observable"), "\(saved.output)")
            #expect(saved.output.contains(#"new text is showing -- "Saved your settings"."#), "\(saved.output)")
        }
    }
}
