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
