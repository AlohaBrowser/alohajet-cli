import Foundation
import Testing
import CDP
import ToolABI
@testable import BrowserTools

// A verification check runs in a frame no aloha-id reaches. With no host to complete it, a
// read says which check the page shows, that it is not completed, and who can complete it.

@Suite("which frame shows a verification check")
struct VerificationCheckVendorTests {

    @Test("a vendor's check frame is named by the host it is served from", arguments: [
        ("https://challenges.cloudflare.com/cdn-cgi/challenge-platform/h/g/turnstile/f/av0/rch/frfuc/"
            + "3x00000000000000000000FF/auto/fbE/new/normal?lang=auto", VerificationCheckVendor.cloudflare),
        ("https://www.google.com/recaptcha/api2/anchor?ar=1&k=6LeIxAcTAAAAAJcZVRqyHh71UMIEGNQ_MXjiZKhI&hl=en&size=normal",
         .recaptcha),
        ("https://www.google.com/recaptcha/enterprise/anchor?ar=1&k=key&size=compact", .recaptcha),
        ("https://www.recaptcha.net/recaptcha/api2/anchor?ar=1&k=key", .recaptcha),
        ("https://newassets.hcaptcha.com/captcha/v1/10dd112850fe5c29df1e51ddc05fdfb8b5f6dbae/static/hcaptcha.html"
            + "#frame=checkbox&id=02mo7qtqhsvl&host=127.0.0.1", .hcaptcha),
        ("https://service.mtcaptcha.com/mtcv1/client/iframe.html?v=2026-10-23&sitekey=MTPublic-UwmxOffel"
            + "&iframeId=mtcaptcha-iframe-1&widgetSize=standard", .mtcaptcha),
    ])
    func vendorFrames(_ url: String, _ vendor: VerificationCheckVendor) {
        #expect(verificationCheckVendor(frameURL: url) == vendor)
    }

    @Test("a frame that shows no check a person can see, or no vendor's, is none", arguments: [
        "https://www.google.com/recaptcha/api2/anchor?ar=1&k=key&size=invisible",
        "https://www.google.com/recaptcha/api2/bframe?hl=en&k=key",
        "https://newassets.hcaptcha.com/captcha/v1/10dd/static/hcaptcha.html#frame=challenge&id=02mo7qtqhsvl",
        "https://newassets.hcaptcha.com/captcha/v1/10dd/static/hcaptcha.html#frame=checkbox-invisible&id=0",
        "https://newassets.hcaptcha.com/captcha/v1/10dd/static/hcaptcha.html",
        "https://evilhcaptcha.com/static/hcaptcha.html#frame=checkbox",
        "https://challenges.cloudflare.com.example.net/turnstile",
        "https://www.google.com/maps/embed?pb=1",
        "https://cdn.respond.io/webchat/widget/chat.html?colorScheme=light",
        "about:blank",
        "",
    ])
    func otherFrames(_ url: String) {
        #expect(verificationCheckVendor(frameURL: url) == nil)
    }

    @Test("every frame below the page's own, with its fragment, at any depth")
    func inProcessFrameURLs() {
        let tree = JSValue.object([
            ("frame", .object([("id", .string("main")), ("url", .string("https://site.example/"))])),
            ("childFrames", .array([
                .object([
                    ("frame", .object([("url", .string("https://a.example/x")), ("urlFragment", .string("#frame=checkbox"))])),
                    ("childFrames", .array([.object([("frame", .object([("url", .string("https://b.example/y"))]))])])),
                ]),
                .object([("frame", .object([("url", .string("about:blank"))]))]),
            ])),
        ])
        #expect(descendantFrameURLs(tree) == ["https://a.example/x#frame=checkbox", "https://b.example/y", "about:blank"])
        #expect(descendantFrameURLs(.object([])) == [])
        #expect(descendantFrameURLs(nil) == [])
    }
}

@Suite("what a read says about a verification check")
struct VerificationCheckLineTests {

    @Test("headless: no one can complete it here, so the user is told the page is blocked")
    func headlessLine() {
        let line = verificationCheckLine(PendingVerificationChecks(vendors: [.cloudflare], headless: true), elsewhere: nil)
        #expect(line == "Verification check not completed on this page: Cloudflare. These tools cannot complete it,"
            + " because it runs in a frame of its own that carries no aloha-id, so do not try to click or type into it."
            + " Some checks complete by themselves within seconds: read the tab again before you go on."
            + " If it is still here, no one can complete it in this browser: it is headless, and no person can see it."
            + " Tell your user that the check blocked the page.")
    }

    @Test("with a window: a person at it can complete the check, and is asked to")
    func headedLine() {
        let line = verificationCheckLine(PendingVerificationChecks(vendors: [.hcaptcha], headless: false), elsewhere: nil)
        #expect(line.hasPrefix("Verification check not completed on this page: hCaptcha. "))
        #expect(line.hasSuffix(" If it is still here, a person at this browser's window can complete it:"
            + " ask your user to, then read the tab again."))
        #expect(!line.contains("headless"))
    }

    @Test("several checks are named together", arguments: [
        ([VerificationCheckVendor.cloudflare, .recaptcha], "Cloudflare and reCAPTCHA."),
        ([.recaptcha, .hcaptcha, .mtcaptcha], "reCAPTCHA, hCaptcha and MTCaptcha."),
    ])
    func severalChecks(_ vendors: [VerificationCheckVendor], _ named: String) {
        let line = verificationCheckLine(PendingVerificationChecks(vendors: vendors, headless: true), elsewhere: nil)
        #expect(line.hasPrefix("Verification check not completed on this page: \(named) "), "\(line)")
    }

    @Test("the host's word on where checks are completed ends the line; none, or an empty one, adds nothing")
    func elsewhereEndsTheLine() {
        let checks = PendingVerificationChecks(vendors: [.mtcaptcha], headless: true)
        let bare = verificationCheckLine(checks, elsewhere: nil)
        #expect(verificationCheckLine(checks, elsewhere: "") == bare)
        #expect(verificationCheckLine(checks, elsewhere: "Run it elsewhere.") == bare + " Run it elsewhere.")
    }
}

/// The page state the check script reports.
private func pageState(
    completed: [String] = [], challengePage: Bool = false, headless: Bool = true
) -> JSValue {
    .object([
        ("completed", .object(VerificationCheckVendor.allCases.map { vendor in
            (vendor.pageStateKey, .bool(completed.contains(vendor.pageStateKey)))
        })),
        ("challengePage", .bool(challengePage)),
        ("headless", .bool(headless)),
    ])
}

@MainActor private func checkedTab() async throws -> (MockCDP, CDPTabHandle) {
    let fixture = try await makePageToolsCDPFixture()
    let tab = try #require(fixture.tabsService.window?.tabs.tab(fixture.tabId) as? CDPTabHandle)
    return (fixture.cdp, tab)
}

@MainActor private func pending(_ tab: CDPTabHandle, settle: Int = 0) async -> PendingVerificationChecks? {
    await tab.pendingVerificationChecks(classify: verificationCheckVendor(frameURL:), settleMilliseconds: settle, signal: nil)
}

private let turnstileFrame = "https://challenges.cloudflare.com/cdn-cgi/challenge-platform/h/g/turnstile/f/av0/rch/a/key/auto/fbE/new/normal"

@Suite("which checks a page over CDP shows and has not completed", .serialized)
@MainActor struct CDPVerificationCheckTests {

    @Test("an out-of-process check frame this page owns, not completed, is pending")
    func ownedFrameIsPending() async throws {
        let (cdp, tab) = try await checkedTab()
        cdp.frameTargets = [("F-1", turnstileFrame)]
        cdp.ownedFrameIds = ["F-1"]
        cdp.verificationPageStates = [pageState(headless: true)]

        #expect(await pending(tab) == PendingVerificationChecks(vendors: [.cloudflare], headless: true))
        let owners = cdp.commands(for: "DOM.getFrameOwner")
        #expect(owners.count == 1)
        #expect(owners.first?.params["frameId"]?.stringValue == "F-1")
        #expect(owners.first?.sessionId != nil, "ownership was asked of the browser, not of the page")
    }

    @Test("a check frame of another tab is not this page's")
    func foreignFrameIsNotPending() async throws {
        let (cdp, tab) = try await checkedTab()
        cdp.frameTargets = [("F-other", turnstileFrame)]
        cdp.verificationPageStates = [pageState()]

        #expect(await pending(tab) == PendingVerificationChecks(vendors: [], headless: true))
    }

    @Test("a check whose token the page holds is completed")
    func completedCheckIsNotPending() async throws {
        let (cdp, tab) = try await checkedTab()
        cdp.frameTargets = [("F-1", turnstileFrame)]
        cdp.ownedFrameIds = ["F-1"]
        cdp.verificationPageStates = [pageState(completed: ["cloudflare"], headless: false)]

        #expect(await pending(tab) == PendingVerificationChecks(vendors: [], headless: false))
    }

    @Test("a check frame in the page's own process counts by its fragment too")
    func inProcessFrames() async throws {
        let (cdp, tab) = try await checkedTab()
        let hcaptcha = "https://newassets.hcaptcha.com/captcha/v1/10dd/static/hcaptcha.html"
        cdp.inProcessFrames = [(hcaptcha, "#frame=challenge&id=1"), (hcaptcha, "#frame=checkbox&id=1")]
        cdp.verificationPageStates = [pageState(completed: ["recaptcha"])]

        #expect(await pending(tab) == PendingVerificationChecks(vendors: [.hcaptcha], headless: true))
    }

    @Test("a Cloudflare challenge page is pending with no frame, and is not watched")
    func challengePage() async throws {
        let (cdp, tab) = try await checkedTab()
        cdp.verificationPageStates = [pageState(completed: ["cloudflare"], challengePage: true), pageState()]

        #expect(await pending(tab, settle: 2_000) == PendingVerificationChecks(vendors: [.cloudflare], headless: true))
        #expect(cdp.commands(for: "Runtime.evaluate").filter { $0.params["expression"]?.stringValue?.contains("_cf_chl_opt") == true }.count == 1)
    }

    @Test("a check that completes itself while it is watched is not reported")
    func settlingCheck() async throws {
        let (cdp, tab) = try await checkedTab()
        cdp.frameTargets = [("F-1", turnstileFrame)]
        cdp.ownedFrameIds = ["F-1"]
        cdp.verificationPageStates = [pageState(), pageState(completed: ["cloudflare"])]

        #expect(await pending(tab, settle: 2_000) == PendingVerificationChecks(vendors: [], headless: true))
    }

    @Test("a check still pending when the watch ends is reported")
    func checkThatStaysPending() async throws {
        let (cdp, tab) = try await checkedTab()
        cdp.frameTargets = [("F-1", turnstileFrame)]
        cdp.ownedFrameIds = ["F-1"]
        cdp.verificationPageStates = [pageState()]

        #expect(await pending(tab, settle: 600) == PendingVerificationChecks(vendors: [.cloudflare], headless: true))
    }

    @Test("a browser started headless is headless though its User-Agent does not say so")
    func headlessByCommandLine() async throws {
        let (cdp, tab) = try await checkedTab()
        cdp.frameTargets = [("F-1", turnstileFrame)]
        cdp.ownedFrameIds = ["F-1"]
        cdp.verificationPageStates = [pageState(headless: false)]
        cdp.browserCommandLine = "/opt/chrome/chrome --headless=new --remote-debugging-port=9222"
            + " --user-agent=Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko)"
            + " Chrome/153.0.0.0 Safari/537.36 about:blank"

        #expect(await pending(tab) == PendingVerificationChecks(vendors: [.cloudflare], headless: true))
        let asked = cdp.commands(for: "SystemInfo.getInfo")
        #expect(asked.count == 1)
        #expect(asked.first?.sessionId == nil, "the command line was asked of the page, not of the browser")
    }

    @Test("a browser started with a window, or one that does not say, is not headless",
          arguments: ["/opt/chrome/chrome --remote-debugging-port=9222 --user-data-dir=/tmp/not--headless about:blank", nil])
    func windowedByCommandLine(_ commandLine: String?) async throws {
        let (cdp, tab) = try await checkedTab()
        cdp.frameTargets = [("F-1", turnstileFrame)]
        cdp.ownedFrameIds = ["F-1"]
        cdp.verificationPageStates = [pageState(headless: false)]
        cdp.browserCommandLine = commandLine

        #expect(await pending(tab) == PendingVerificationChecks(vendors: [.cloudflare], headless: false))
    }

    @Test("a page that cannot be asked says nothing")
    func unaskablePage() async throws {
        let (cdp, tab) = try await checkedTab()
        cdp.frameTargets = [("F-1", turnstileFrame)]
        cdp.ownedFrameIds = ["F-1"]

        #expect(await pending(tab) == nil)
    }
}

// MARK: - The read

@MainActor private final class ReadSession: ChatModeSession {
    var active: String?
    func sessionNetworkDir() -> String? { nil }
    func registerNetworkRecordingTab(_ tab: TabHandle) {}
    func unregisterNetworkRecordingTab(_ tabId: String) {}
    func setActiveBrowserTab(_ tabId: String?) { active = tabId }
    func getActiveBrowserTabId() -> String? { active }
    func clearActiveBrowserTabIfMatches(_ tabId: String) { if active == tabId { active = nil } }
}

private struct StaticPage: AgentDOMSnapshotting {
    func getInteractMarkdown(_ includeScreenshot: Bool, _ b: Bool, includeUrls: Bool) async throws -> ToolABI.InteractMarkdownResult {
        ToolABI.InteractMarkdownResult(markdown: "# Sign up", screenshot: nil, diagnostics: .init())
    }
    func getInteractMarkdown(
        _ includeScreenshot: Bool, _ b: Bool, includeUrls: Bool, signal: AbortSignal?
    ) async throws -> ToolABI.InteractMarkdownResult {
        try await getInteractMarkdown(includeScreenshot, b, includeUrls: includeUrls)
    }
    func getInteractMarkdown(
        _ includeScreenshot: Bool, _ b: Bool, serializeOptions: DomSerializeOptions, signal: AbortSignal?
    ) async throws -> ToolABI.InteractMarkdownResult {
        try await getInteractMarkdown(includeScreenshot, b, includeUrls: false)
    }
}

@MainActor private class CheckedTab: TabHandle, VerificationCheckReporting {
    let id = "t1"
    let title: String? = "Sign up"
    let url = "https://site.example/signup"
    let attribution = TabAttribution(owner: .chat("test-session"))
    let tabType = "website"
    let faviconUrl: String? = nil
    var agentDOM: AgentDOMSnapshotting? { StaticPage() }
    var checks: PendingVerificationChecks?
    private(set) var asked = 0

    init(_ checks: PendingVerificationChecks?) { self.checks = checks }

    func wake(_ signal: AbortSignal?) async throws -> WakeResult { WakeResult(ok: true) }
    func viewportBounds() -> TabViewportBounds? { nil }
    func startNetworkRecording(logPath: String) {}
    func pendingVerificationChecks(_ signal: AbortSignal?) async -> PendingVerificationChecks? {
        asked += 1
        return checks
    }
}

@MainActor private final class RemediatedTab: CheckedTab, PageReadRemediating {
    func remediateAfterRead(_ signal: AbortSignal?) async -> Bool { false }
}

@MainActor private final class OneTabModel: TabsModel {
    let only: TabHandle
    var activeTabId: String?
    init(_ only: TabHandle) { self.only = only }
    func setActiveTabId(_ id: String?) { activeTabId = id }
    var tabsById: [String: TabHandle] { [only.id: only] }
    var orderedTabs: [TabHandle] { [only] }
    func tab(_ id: String) -> TabHandle? { id == only.id ? only : nil }
    func createTab(_ spec: TabCreateSpec) -> TabHandle { only }
    func closeTab(_ id: String, skipConfirm: Bool) async {}
    func getTabContext(windowId: String, tab: TabHandle, signal: AbortSignal?) async throws -> TabReadContext? { nil }
}

@MainActor private final class OneTabWindow: TabsWindow, TabsService {
    let id = "one-tab-window"
    let tabs: TabsModel
    init(_ tab: TabHandle) { tabs = OneTabModel(tab) }
    var window: TabsWindow? { self }
}

@MainActor private func read(_ tab: TabHandle) async throws -> RawToolResult {
    let services = NativeToolServices(tabsService: OneTabWindow(tab), session: ReadSession())
    return try await ManageTabsExecutorTool().execute(
        .object(["action": .string("read"), "tab_id": .string(tab.id)]), makePageToolContext(services: services))
}

@Suite("a read names a verification check only where no host completes it", .serialized)
@MainActor struct VerificationCheckReadTests {

    @Test("a pending check is named below the page's preamble, with the host's word on where to go")
    func pendingCheckIsNamed() async throws {
        let tab = CheckedTab(PendingVerificationChecks(vendors: [.cloudflare], headless: true))
        VerificationCheckNote.elsewhere = "Run it in AlohaJet."
        defer { VerificationCheckNote.elsewhere = nil }

        let result = try await read(tab)
        #expect(result.isError != true, "\(result.output)")
        let expected = verificationCheckLine(tab.checks!, elsewhere: "Run it in AlohaJet.")
        #expect(result.output.contains(expected), "\(result.output)")
        let line = try #require(result.output.range(of: expected))
        let page = try #require(result.output.range(of: "# Sign up"))
        #expect(line.upperBound <= page.lowerBound, "the check is named after the page:\n\(result.output)")
    }

    @Test("no pending check, or a page that cannot be asked, adds nothing", arguments: [
        PendingVerificationChecks?.some(PendingVerificationChecks(vendors: [], headless: true)),
        nil,
    ])
    func nothingPending(_ checks: PendingVerificationChecks?) async throws {
        let tab = CheckedTab(checks)
        let result = try await read(tab)
        #expect(result.isError != true, "\(result.output)")
        #expect(tab.asked == 1)
        #expect(!result.output.contains("Verification check"), "\(result.output)")
    }

    @Test("a tab whose host completes checks after the read is not asked, and the read names none")
    func remediatingHostSpeaksForItself() async throws {
        let tab = RemediatedTab(PendingVerificationChecks(vendors: [.cloudflare], headless: true))
        let result = try await read(tab)
        #expect(result.isError != true, "\(result.output)")
        #expect(tab.asked == 0)
        #expect(!result.output.contains("Verification check"), "\(result.output)")
    }

    @Test("over CDP, a challenge page's read names the check")
    func cdpReadNamesTheCheck() async throws {
        let fixture = try await makePageToolsCDPFixture()
        fixture.cdp.verificationPageStates = [pageState(challengePage: true)]
        let services = NativeToolServices(tabsService: fixture.tabsService, session: ReadSession())
        let result = try await ManageTabsExecutorTool().execute(
            .object(["action": .string("read"), "tab_id": .string(fixture.tabId)]), makePageToolContext(services: services))
        #expect(result.isError != true, "\(result.output)")
        #expect(result.output.contains("Verification check not completed on this page: Cloudflare."), "\(result.output)")
    }
}
