import Foundation
import Testing
import CDP
import ToolABI
@testable import BrowserTools

// THE CLAIM `--browser aloha` RESTS ON: it is not a second backend, it is a different CDP
// endpoint. Same discovery (`GET /json/version`), same `CDPClient`, same tools, same
// `RawToolResult` — the only difference is which listener answers.
//
// So the test drives ONE browser through BOTH lanes and demands the same bytes out:
//
//   chromium lane   BrowserToolSession.attach(port:)                    — what `--cdp` does
//   aloha lane      AlohaBrowser().endpoint(port:) -> attach(webSocketURL:)
//
// The aloha lane runs its REAL `liveProbe` here, not a stub: it reads `/json/version` off
// a live socket and parses `webSocketDebuggerUrl` out of it. That is the entire mechanism
// the lane consists of, and it is the same endpoint contract the Aloha browser publishes
// (the Aloha browser's own CDP server serves exactly those
// three routes with exactly that field). Substituting a Chromium for the Aloha browser is
// legitimate precisely BECAUSE the lane is only an endpoint — if that ever stopped being
// true this test would be measuring the wrong thing, and so would the design.
//
// What it deliberately does NOT do is launch the Aloha app: `open` is wired to fail the
// test. A parity run must not open the developer's browser, and the lane must not need it
// when something is already answering.

private nonisolated let parityBrowserIsAvailable = ChromeLauncher().isAvailable
private nonisolated let parityBrowserIsRequired =
    ProcessInfo.processInfo.environment["ALOHAJET_REQUIRE_BROWSER"] == "1"

private let parityHTML = """
<!doctype html>
<html><head><title>Lane Parity</title></head>
<body>
  <h1>Lane Parity</h1>
  <p id="status">one page, two lanes</p>
  <button id="b1">Press me</button>
</body></html>
"""

@Suite("browser lanes, one endpoint", .serialized,
       .enabled(if: parityBrowserIsAvailable || parityBrowserIsRequired))
struct BrowserLaneParityTests {

    @Test("both lanes reach the same endpoint and return the same RawToolResult")
    func lanesAgree() async throws {
        try #require(parityBrowserIsAvailable,
                     "no browser at \(ChromeLauncher().executablePath) — install one; ALOHAJET_REQUIRE_BROWSER is set, so this is a failure, not a skip")

        let server = LocalPageServer(html: parityHTML)
        try server.start()
        defer { server.stop() }

        // One browser. Everything below attaches to it; nothing else is launched.
        try await withHeadlessBrowser { owner in
            let port = try #require(owner.launchedBrowser?.port, "the launch reported no port")

            // Open the page once, so both lanes read the SAME tab. Two `open` calls would
            // yield two tab ids and the comparison would be vacuous.
            let opened = await owner.run("manage_tabs", arguments: ["action": "open", "url": server.url])
            #expect(opened.isError != true, "open failed: \(opened.output)")
            let tabId = try #require(tabIdentifier(opened), "open printed no tab id:\n\(opened.output)")

            // LANE 1 — `--cdp <port>`.
            let chromium = try await BrowserToolSession.attach(port: port)

            // LANE 2 — `--browser aloha`, through the real discovery read. The opener is wired
            // to fail: a listener is already answering, so the lane must never reach it.
            let aloha = AlohaBrowser(open: { Issue.record("the aloha lane launched an app while one was already answering") })
            let discovered = try await aloha.endpoint(port: port)
            #expect(discovered.scheme == "ws", "discovery yielded \(discovered)")
            let alohaSession = try await BrowserToolSession.attach(webSocketURL: discovered.absoluteString)

            // The same command, on the same tab, through each lane.
            let viaCdp = await chromium.run("manage_tabs", arguments: ["action": "read", "tab_id": tabId])
            let viaAloha = await alohaSession.run("manage_tabs", arguments: ["action": "read", "tab_id": tabId])

            #expect(viaCdp.isError != true, "the --cdp lane failed: \(viaCdp.output)")
            #expect(viaAloha.isError != true, "the aloha lane failed: \(viaAloha.output)")
            #expect(viaCdp.output.contains("one page, two lanes"))

            // BYTE-FOR-BYTE. The markdown carries the element refs the next command addresses,
            // so a lane that rendered them differently would hand the model refs the other
            // lane cannot use — the exact failure "both lanes end in the same CDPClient" is
            // supposed to rule out.
            #expect(viaAloha.output == viaCdp.output, """
                the two lanes rendered the same page differently
                --cdp:
                \(viaCdp.output)
                --browser aloha:
                \(viaAloha.output)
                """)
            #expect(viaAloha.isError == viaCdp.isError)
            #expect(viaAloha.status == viaCdp.status)

            await alohaSession.shutdown()
            await chromium.shutdown()
        }
    }
}
