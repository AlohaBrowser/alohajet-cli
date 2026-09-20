import Foundation
import Testing
import CDP
import ToolABI
@testable import BrowserTools

// The only test in this package that proves the product works.
//
// Everything else pins a pure function, a serializer shape, or a mocked CDP exchange.
// This one launches a real headless Chromium, points it at a page served over a real
// socket, and runs the loop the tool exists for: open the page, read it as markdown, find
// the element ref the read printed, click THAT ref, read again, and see the page change.
// `not clicked` -> `CLICKED-OK` is the assertion; nothing short of a working browser, a
// working DOM walk, a working ref derivation and a working click can produce it.
//
// SKIPPING: the suite is disabled when no Chromium is installed, so a contributor with no
// browser still gets a green `swift test`. CI sets `ALOHAJET_REQUIRE_BROWSER=1`, which
// forces the suite to run and to FAIL if the browser is missing — a silent skip in CI is
// how a real-browser path goes untested for a month while the badge stays green.

// `nonisolated`: the suite trait is evaluated outside the main actor, and this target
// builds with `defaultIsolation(MainActor.self)`.
private nonisolated let browserIsAvailable = ChromeLauncher().isAvailable
private nonisolated let browserIsRequired = ProcessInfo.processInfo.environment["ALOHAJET_REQUIRE_BROWSER"] == "1"

private let fixtureHTML = """
<!doctype html>
<html><head><title>Click Fixture</title></head>
<body>
  <h1>Click Fixture</h1>
  <p id="status">not clicked</p>
  <button id="b1" onclick="document.getElementById('status').textContent = 'CLICKED-OK'">Press me</button>
</body></html>
"""


private let uploadFixtureHTML = """
<!doctype html>
<html><head><title>Upload Fixture</title></head>
<body>
  <h1>Upload Fixture</h1>
  <p id="log">no-change-yet</p>
  <input type="file" id="file1" aria-label="alpha upload">
  <div id="zone" class="dropzone">Drop files here to upload</div>
  <input type="file" id="file2" aria-label="beta upload">
  <div id="wrap" class="dropzone">Choose a file to upload<input type="file" id="file3" style="display:none"></div>
  <script>
    window.__ev = [];
    for (const el of document.querySelectorAll('input[type=file]')) {
      el.addEventListener('change', () => {
        window.__ev.push(el.id + '!' + Array.from(el.files).map(f => f.name + ':' + f.size).join('+'));
        document.getElementById('log').textContent = window.__ev.join(' | ');
      });
    }
  </script>
</body></html>
"""

private let editableFixtureHTML = """
<!doctype html>
<html><head><title>Editable Fixture</title></head>
<body>
  <h1>Editable Fixture</h1>
  <div contenteditable="true">plain editable</div>
  <div contenteditable>bare editable <b>nested bolded</b></div>
</body></html>
"""

@Suite("end to end, real browser", .serialized, .enabled(if: browserIsAvailable || browserIsRequired))
struct RealBrowserE2ETests {

    @Test func openReadClickVerify() async throws {
        try #require(browserIsAvailable,
                     "no browser at \(ChromeLauncher().executablePath) — install one; ALOHAJET_REQUIRE_BROWSER is set, so this is a failure, not a skip")

        let server = LocalPageServer(html: fixtureHTML)
        try server.start()
        defer { server.stop() }

        let session = try await BrowserToolSession.launch(headless: true, port: nil)
        // The browser must not outlive the test even when an assertion throws.
        defer { Task { await session.shutdown() } }

        // 1. OPEN — the page comes back as markdown, with the element refs the other
        //    tools address.
        let opened = await session.run("manage_tabs", arguments: ["action": "open", "url": server.url])
        #expect(opened.isError != true, "open failed: \(opened.output)")
        #expect(opened.output.contains("not clicked"), "the page body is missing:\n\(opened.output)")
        let tabId = try #require(tabIdentifier(opened), "open printed no tab id:\n\(opened.output)")

        // 2. READ — the same page through the read action, addressed by the id `open`
        //    printed. This is the two-command sequence the tool's own receipt tells the
        //    model to run, and it must work.
        let read = await session.run("manage_tabs", arguments: ["action": "read", "tab_id": tabId])
        #expect(read.isError != true, "read failed: \(read.output)")
        #expect(read.output.contains("not clicked"))

        // 3. CLICK — by the ref the read printed, not by a selector we invented. The ref
        //    derivation is the seam between what the model sees and what gets clicked; a
        //    test that clicks `#b1` directly would not exercise it.
        let ref = try #require(alohaId(forLabel: "Press me", in: read.output),
                               "the button carried no aloha-id:\n\(read.output)")

        // THE REF IS STABLE ACROSS WALKS. `open` and `read` each ran the walker over the
        // same DOM; if the two walks derived different ids for the same button, every ref
        // the model was shown by the previous read would be dead by the time it acted —
        // which is the failure the whole content-derived id scheme exists to avoid.
        #expect(alohaId(forLabel: "Press me", in: opened.output) == ref,
                "two walks over one unchanged page derived different refs")
        let clicked = await session.run("page_click", arguments: ["aloha_id": ref])
        #expect(clicked.isError != true, "click failed: \(clicked.output)")
        #expect(clicked.output.contains(ref))

        // 4. VERIFY — read the page again and see the DOM the click changed.
        let after = await session.run("manage_tabs", arguments: ["action": "read", "tab_id": tabId])
        #expect(after.isError != true, "the re-read failed: \(after.output)")
        #expect(after.output.contains("CLICKED-OK"), "the click did not take:\n\(after.output)")
        #expect(!after.output.contains("not clicked"))

        // And stable across a RE-RENDER: the click mutated the DOM (the status paragraph's
        // text changed), the walker ran again over the changed tree, and the button — which
        // did not change — must still carry the same ref. A ref that moved here would
        // invalidate every id in the model's context on every page update.
        #expect(alohaId(forLabel: "Press me", in: after.output) == ref,
                "the button's ref changed when an unrelated node re-rendered")
    }

    /// The other half of the security posture, proven against a live browser rather than
    /// asserted about a string: `page_navigate` from a REAL loaded page (not the fresh
    /// `about:blank`, which Chrome refuses on its own) to `file://` must be refused by us.
    @Test func gotoFileURLIsRefusedFromALoadedPage() async throws {
        try #require(browserIsAvailable)

        let secret = FileManager.default.temporaryDirectory
            .appendingPathComponent("alohajet-e2e-secret-\(UUID().uuidString).txt")
        try Data("SECRET-CANARY-12345".utf8).write(to: secret)
        defer { try? FileManager.default.removeItem(at: secret) }

        let server = LocalPageServer(html: fixtureHTML)
        try server.start()
        defer { server.stop() }

        let session = try await BrowserToolSession.launch(headless: true, port: nil)
        defer { Task { await session.shutdown() } }

        let opened = await session.run("manage_tabs", arguments: ["action": "open", "url": server.url])
        #expect(opened.isError != true, "open failed: \(opened.output)")

        let navigated = await session.run(
            "page_navigate",
            arguments: ["action": "goto", "url": "file://\(secret.path)"])
        #expect(navigated.isError == true, "page_navigate accepted a file:// URL")
        #expect(navigated.output.contains("file://"))
        #expect(!navigated.output.contains("SECRET-CANARY"))

        // And the tab is still on the page it was on, not on the file.
        let after = await session.run("manage_tabs", arguments: ["action": "list"])
        #expect(!after.output.contains(secret.path))
        #expect(!after.output.contains("SECRET-CANARY"))
    }


    @Test func uploadRefusesAStaleIdAndAnElementThatHoldsNoFileInput() async throws {
        try #require(browserIsAvailable)

        let server = LocalPageServer(html: uploadFixtureHTML)
        try server.start()
        defer { server.stop() }
        let payload = FileManager.default.temporaryDirectory
            .appendingPathComponent("alohajet-e2e-upload-\(UUID().uuidString).txt")
        try Data("hello!".utf8).write(to: payload)
        defer { try? FileManager.default.removeItem(at: payload) }

        let session = try await BrowserToolSession.launch(headless: true, port: nil)
        defer { Task { await session.shutdown() } }

        let opened = await session.run("manage_tabs", arguments: ["action": "open", "url": server.url])
        #expect(opened.isError != true, "open failed: \(opened.output)")
        let tabId = try #require(tabIdentifier(opened))

        let stale = await session.run("page_upload", arguments: ["aloha_id": "zzzz999", "paths": [payload.path]])
        #expect(stale.isError == true, "a stale id was accepted: \(stale.output)")
        #expect(stale.output.contains("zzzz999"))
        #expect(stale.output.lowercased().contains("read"))

        let zoneId = try #require(alohaId(forLabel: "Drop files here", in: opened.output),
                                  "the dropzone carried no aloha-id:\n\(opened.output)")
        let onZone = await session.run("page_upload", arguments: ["aloha_id": zoneId, "paths": [payload.path]])
        #expect(onZone.isError == true, "an element holding no file input was accepted: \(onZone.output)")
        #expect(onZone.output.contains(zoneId))

        let after = await session.run("manage_tabs", arguments: ["action": "read", "tab_id": tabId])
        #expect(after.output.contains("no-change-yet"), "a refused upload still reached a file input:\n\(after.output)")
    }

    @Test func uploadAttachesToTheNamedInputAndFiresOneChange() async throws {
        try #require(browserIsAvailable)

        let server = LocalPageServer(html: uploadFixtureHTML)
        try server.start()
        defer { server.stop() }
        let payload = FileManager.default.temporaryDirectory
            .appendingPathComponent("alohajet-e2e-upload-\(UUID().uuidString).txt")
        try Data("hello!".utf8).write(to: payload)
        defer { try? FileManager.default.removeItem(at: payload) }

        let session = try await BrowserToolSession.launch(headless: true, port: nil)
        defer { Task { await session.shutdown() } }

        let opened = await session.run("manage_tabs", arguments: ["action": "open", "url": server.url])
        #expect(opened.isError != true, "open failed: \(opened.output)")
        let tabId = try #require(tabIdentifier(opened))
        let betaId = try #require(alohaId(forLabel: "beta upload", in: opened.output),
                                  "the second file input carried no aloha-id:\n\(opened.output)")

        let uploaded = await session.run("page_upload", arguments: ["aloha_id": betaId, "paths": [payload.path]])
        #expect(uploaded.isError != true, "upload failed: \(uploaded.output)")
        #expect(uploaded.output.contains(betaId))

        let after = await session.run("manage_tabs", arguments: ["action": "read", "tab_id": tabId])
        let log = try #require(after.output.split(separator: "\n").first { $0.contains("file1!") || $0.contains("file2!") }
            .map(String.init), "no change event reached the page:\n\(after.output)")
        #expect(log.contains("file2!\(payload.lastPathComponent):6"), "the file did not land on the named input: \(log)")
        #expect(!log.contains("|"), "one upload produced more than one change event: \(log)")
    }

    @Test func uploadOnAWrapperLandsOnItsFileInputAndSaysSo() async throws {
        try #require(browserIsAvailable)

        let server = LocalPageServer(html: uploadFixtureHTML)
        try server.start()
        defer { server.stop() }
        let payload = FileManager.default.temporaryDirectory
            .appendingPathComponent("alohajet-e2e-upload-\(UUID().uuidString).txt")
        try Data("hello!".utf8).write(to: payload)
        defer { try? FileManager.default.removeItem(at: payload) }

        let session = try await BrowserToolSession.launch(headless: true, port: nil)
        defer { Task { await session.shutdown() } }

        let opened = await session.run("manage_tabs", arguments: ["action": "open", "url": server.url])
        #expect(opened.isError != true, "open failed: \(opened.output)")
        let tabId = try #require(tabIdentifier(opened))
        let wrapId = try #require(alohaId(forLabel: "Choose a file", in: opened.output),
                                  "the wrapper carried no aloha-id:\n\(opened.output)")

        let uploaded = await session.run("page_upload", arguments: ["aloha_id": wrapId, "paths": [payload.path]])
        #expect(uploaded.isError != true, "upload failed: \(uploaded.output)")
        #expect(uploaded.output.contains("the file input") && uploaded.output.contains("inside element \"\(wrapId)\""),
                "the receipt did not name the input the file landed on: \(uploaded.output)")

        let after = await session.run("manage_tabs", arguments: ["action": "read", "tab_id": tabId])
        let log = try #require(after.output.split(separator: "\n").first { $0.contains("file3!") }.map(String.init),
                               "the file did not land on the wrapper's own input:\n\(after.output)")
        #expect(log.contains("file3!\(payload.lastPathComponent):6"), "the file did not land on the wrapper's input: \(log)")
        #expect(!log.contains("|"), "one upload produced more than one change event: \(log)")
    }

    @Test func aContentEditableHostCarriesARefAndCanBeTypedInto() async throws {
        try #require(browserIsAvailable)

        let server = LocalPageServer(html: editableFixtureHTML)
        try server.start()
        defer { server.stop() }

        let session = try await BrowserToolSession.launch(headless: true, port: nil)
        defer { Task { await session.shutdown() } }

        let opened = await session.run("manage_tabs", arguments: ["action": "open", "url": server.url])
        #expect(opened.isError != true, "open failed: \(opened.output)")
        let tabId = try #require(tabIdentifier(opened))

        #expect(alohaId(forLabel: "plain editable", in: opened.output) != nil,
                "a contenteditable=\"true\" host carried no aloha-id:\n\(opened.output)")
        let bareId = try #require(alohaId(forLabel: "bare editable", in: opened.output),
                                  "a bare contenteditable host carried no aloha-id:\n\(opened.output)")
        let nestedId = alohaId(forLabel: "nested bolded", in: opened.output)
        #expect(nestedId == nil || nestedId == bareId,
                "an element INSIDE an editable host was given its own aloha-id:\n\(opened.output)")

        let typed = await session.run("page_type", arguments: ["aloha_id": bareId, "text": "TYPED-OK"])
        #expect(typed.isError != true, "page_type into a contenteditable host failed: \(typed.output)")

        let after = await session.run("manage_tabs", arguments: ["action": "read", "tab_id": tabId])
        #expect(after.output.contains("TYPED-OK"), "the text did not land:\n\(after.output)")
    }

    // MARK: - Reading the tool's own output

    /// The tab id off the metadata channel the tool fills, falling back to the `Tab ID:`
    /// line it prints — the CLI reads it the same two ways.
    private func tabIdentifier(_ result: RawToolResult) -> String? {
        if case let .string(id)? = result.metadata?["tabId"], !id.isEmpty { return id }
        for line in result.output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Tab ID: ") { return String(trimmed.dropFirst("Tab ID: ".count)) }
            if trimmed.hasPrefix("ID: ") { return String(trimmed.dropFirst("ID: ".count)) }
        }
        return nil
    }

    /// Pulls the ref out of a rendered interactive line, e.g.
    /// `[Press me] {aloha-id="38ed76" button}`.
    private func alohaId(forLabel label: String, in markdown: String) -> String? {
        for line in markdown.split(separator: "\n") where line.contains(label) {
            guard let marker = line.range(of: "aloha-id=\"") else { continue }
            let rest = line[marker.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { continue }
            return String(rest[rest.startIndex..<end])
        }
        return nil
    }
}
