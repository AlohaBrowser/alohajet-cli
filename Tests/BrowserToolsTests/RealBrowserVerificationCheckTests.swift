import Foundation
import Testing
import CDP
import ToolABI
@testable import BrowserTools

// The CDP half of the verification-check line against a live Chromium: a frame of another
// site inside a closed shadow root (Turnstile's shape), which no page script can see, is
// found, tied to its own page, and pending until the page holds the token.
//
// `ALOHAJET_BROWSER` picks the browser when set, so a machine with Chrome for Testing and no
// Chrome runs this too. Skipped with no browser unless `ALOHAJET_REQUIRE_BROWSER=1`.

private nonisolated let checkBrowserPath = ProcessInfo.processInfo.environment["ALOHAJET_BROWSER"]
    .flatMap { $0.isEmpty ? nil : $0 } ?? ChromeLauncher.defaultExecutablePath
private nonisolated let checkBrowserIsAvailable = FileManager.default.isExecutableFile(atPath: checkBrowserPath)
private nonisolated let checkBrowserIsRequired = ProcessInfo.processInfo.environment["ALOHAJET_REQUIRE_BROWSER"] == "1"

private func signUpPage(frame: String?, script: String = "") -> String {
    """
    <!doctype html>
    <html><head><title>Sign up</title></head>
    <body>
      <h1>Sign up</h1>
      <form><input type="hidden" name="cf-turnstile-response" value=""><div id="widget"></div>
        <button type="submit">Create account</button></form>
      <script>
        \(frame.map { """
        const root = document.getElementById('widget').attachShadow({ mode: 'closed' });
        const frame = document.createElement('iframe');
        frame.src = '\($0)';
        frame.width = 300;
        frame.height = 65;
        root.appendChild(frame);
        """ } ?? "")
        \(script)
      </script>
    </body></html>
    """
}

@MainActor
private func withCheckBrowser<T>(_ body: (BrowserToolSession) async throws -> T) async throws -> T {
    let session = try await BrowserToolSession.launch(executablePath: checkBrowserPath, headless: true, port: nil)
    do {
        let value = try await body(session)
        await session.shutdown()
        return value
    } catch {
        await session.shutdown()
        throw error
    }
}

@Suite("verification checks, real browser", .serialized, .enabled(if: checkBrowserIsAvailable || checkBrowserIsRequired))
@MainActor struct RealBrowserVerificationCheckTests {

    @Test("a check frame of another site in a closed shadow root is pending until the page holds its token")
    func closedShadowRootFrame() async throws {
        try #require(checkBrowserIsAvailable, "no browser at \(checkBrowserPath)")
        let widget = LocalPageServer(html: "<!doctype html><title>widget</title><p>I am not a robot</p>")
        try widget.start()
        defer { widget.stop() }
        let widgetOrigin = "localhost:\(widget.port)"
        let page = LocalPageServer(html: signUpPage(frame: "http://\(widgetOrigin)/widget", script: """
            window.completeCheck = () => { document.getElementsByName('cf-turnstile-response')[0].value = 'token'; };
            """))
        try page.start()
        defer { page.stop() }
        let classify: @Sendable (String) -> VerificationCheckVendor? = { url in
            guard let components = URLComponents(string: url), let host = components.host, let port = components.port
            else { return nil }
            return "\(host):\(port)" == widgetOrigin ? .cloudflare : nil
        }

        try await withCheckBrowser { session in
            let opened = await session.run("manage_tabs", arguments: ["action": "open", "url": page.url])
            #expect(opened.isError != true, "\(opened.output)")
            let tabId = try #require(tabIdentifier(opened))
            let tab = try #require(session.tabs?.tab(tabId) as? CDPTabHandle)

            var checks: PendingVerificationChecks?
            for _ in 0..<40 {
                checks = await tab.pendingVerificationChecks(classify: classify, settleMilliseconds: 0, signal: nil)
                if checks?.vendors.isEmpty == false { break }
                try await Task.sleep(nanoseconds: 250_000_000)
            }
            #expect(checks == PendingVerificationChecks(vendors: [.cloudflare], headless: true))

            let sessionId = try await tab.session.ensureAttached()
            _ = try await tab.session.client.send(
                method: "Runtime.evaluate", params: ["expression": .string("completeCheck()")], sessionId: sessionId)
            #expect(await tab.pendingVerificationChecks(classify: classify, settleMilliseconds: 0, signal: nil)
                == PendingVerificationChecks(vendors: [], headless: true))
        }
    }

    @Test("a check frame in another tab is not this page's")
    func anotherTabsFrame() async throws {
        try #require(checkBrowserIsAvailable, "no browser at \(checkBrowserPath)")
        let widget = LocalPageServer(html: "<!doctype html><title>widget</title><p>I am not a robot</p>")
        try widget.start()
        defer { widget.stop() }
        let widgetOrigin = "localhost:\(widget.port)"
        let withCheck = LocalPageServer(html: signUpPage(frame: "http://\(widgetOrigin)/widget"))
        try withCheck.start()
        defer { withCheck.stop() }
        let without = LocalPageServer(html: signUpPage(frame: nil))
        try without.start()
        defer { without.stop() }
        let classify: @Sendable (String) -> VerificationCheckVendor? = { url in
            guard let components = URLComponents(string: url), let host = components.host, let port = components.port
            else { return nil }
            return "\(host):\(port)" == widgetOrigin ? .cloudflare : nil
        }

        try await withCheckBrowser { session in
            let first = await session.run("manage_tabs", arguments: ["action": "open", "url": withCheck.url])
            let firstId = try #require(tabIdentifier(first))
            let firstTab = try #require(session.tabs?.tab(firstId) as? CDPTabHandle)
            for _ in 0..<40 {
                let checks = await firstTab.pendingVerificationChecks(classify: classify, settleMilliseconds: 0, signal: nil)
                if checks?.vendors.isEmpty == false { break }
                try await Task.sleep(nanoseconds: 250_000_000)
            }
            let second = await session.run("manage_tabs", arguments: ["action": "open", "url": without.url])
            let secondId = try #require(tabIdentifier(second))
            let secondTab = try #require(session.tabs?.tab(secondId) as? CDPTabHandle)

            #expect(await secondTab.pendingVerificationChecks(classify: classify, settleMilliseconds: 0, signal: nil)
                == PendingVerificationChecks(vendors: [], headless: true))
        }
    }

    @Test("a headless browser's command line says it is headless")
    func headlessCommandLine() async throws {
        try #require(checkBrowserIsAvailable, "no browser at \(checkBrowserPath)")
        try await withCheckBrowser { session in
            #expect(await browserStartedHeadless(session.client))
        }
    }

    @Test("the read of a Cloudflare challenge page names the check and who cannot complete it")
    func challengePageRead() async throws {
        try #require(checkBrowserIsAvailable, "no browser at \(checkBrowserPath)")
        let challenge = LocalPageServer(html: signUpPage(frame: nil, script: "window._cf_chl_opt = { cType: 'managed' };"))
        try challenge.start()
        defer { challenge.stop() }
        let plain = LocalPageServer(html: signUpPage(frame: nil))
        try plain.start()
        defer { plain.stop() }

        try await withCheckBrowser { session in
            let blocked = await session.run("manage_tabs", arguments: ["action": "open", "url": challenge.url])
            #expect(blocked.isError != true, "\(blocked.output)")
            #expect(blocked.output.contains("Verification check not completed on this page: Cloudflare."), "\(blocked.output)")
            #expect(blocked.output.contains("it is headless, and no person can see it"), "\(blocked.output)")

            let open = await session.run("manage_tabs", arguments: ["action": "open", "url": plain.url])
            #expect(open.isError != true, "\(open.output)")
            #expect(!open.output.contains("Verification check"), "\(open.output)")
        }
    }
}
