import Foundation
import Testing
import CDP
import ToolABI
@testable import BrowserTools

// Headless Chrome puts HeadlessChrome in its User-Agent, and Cloudflare's challenge page
// answered a click from that browser by coming back, every time, where the same browser
// with a windowed User-Agent got through. Measured from the page and the browser, which is
// what a site reads.

private nonisolated let userAgentBrowserPath = ProcessInfo.processInfo.environment["ALOHAJET_BROWSER"]
    .flatMap { $0.isEmpty ? nil : $0 } ?? ChromeLauncher.defaultExecutablePath
private nonisolated let userAgentBrowserIsAvailable = FileManager.default.isExecutableFile(atPath: userAgentBrowserPath)
private nonisolated let userAgentBrowserIsRequired = ProcessInfo.processInfo.environment["ALOHAJET_REQUIRE_BROWSER"] == "1"
private nonisolated let userAgentOverridden = ProcessInfo.processInfo.environment["ALOHAJET_CHROME_USER_AGENT"]
    .map { !$0.isEmpty } ?? false

@Suite("a headless browser's User-Agent, real browser", .serialized,
       .enabled(if: (userAgentBrowserIsAvailable || userAgentBrowserIsRequired) && !userAgentOverridden))
@MainActor struct RealBrowserUserAgentTests {

    @Test("neither the User-Agent nor the client hints of a headless browser say HeadlessChrome")
    func headlessSaysChrome() async throws {
        try #require(userAgentBrowserIsAvailable, "no browser at \(userAgentBrowserPath)")
        let session = try await BrowserToolSession.launch(executablePath: userAgentBrowserPath, headless: true, port: nil)
        defer { Task { await session.shutdown() } }
        let client = session.client

        let version = try await client.send(method: "Browser.getVersion", params: [:])
        let browserUserAgent = try #require(version["userAgent"]?.stringValue)
        #expect(!browserUserAgent.contains("Headless"), "\(browserUserAgent)")
        #expect(browserUserAgent.contains("Chrome/"), "\(browserUserAgent)")

        // `navigator.userAgentData` exists only in a secure context, which a loopback origin is
        // and a fresh about:blank is not.
        let server = LocalPageServer(html: "<!doctype html><title>user agent</title><p>hello</p>")
        try server.start()
        defer { server.stop() }
        let target = try await client.openTab(url: server.url)
        let page = try await client.attachToTarget(targetId: target)
        for _ in 0..<40 {
            let ready = try await client.send(
                method: "Runtime.evaluate",
                params: ["expression": .string("location.href + ' ' + document.readyState"), "returnByValue": .bool(true)],
                sessionId: page)
            if ready["result"]?["value"]?.stringValue == server.url + " complete" { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let result = try await client.send(
            method: "Runtime.evaluate",
            params: [
                "expression": .string("""
                    JSON.stringify({ userAgent: navigator.userAgent, appVersion: navigator.appVersion,
                      brands: navigator.userAgentData ? navigator.userAgentData.brands.map((b) => b.brand) : null })
                    """),
                "returnByValue": .bool(true),
            ],
            sessionId: page)
        let json = try #require(result["result"]?["value"]?.stringValue)
        let read = try JSONDecoder().decode(PageUserAgent.self, from: Data(json.utf8))
        #expect(read.userAgent == browserUserAgent)
        #expect(!read.appVersion.contains("Headless"), "\(read.appVersion)")
        let brands = try #require(read.brands, "the page has no navigator.userAgentData")
        #expect(!brands.isEmpty)
        #expect(!brands.contains { $0.contains("Headless") }, "\(brands)")
    }

    private struct PageUserAgent: Decodable {
        let userAgent: String
        let appVersion: String
        let brands: [String]?
    }
}
