import Foundation
import Testing
import CDP
import ToolABI
@testable import BrowserTools

// The seams `makeCDPBrowserTabsService` hands a host — the navigation pacer, the
// per-handle creation hook, the control-state hook — exist so a host does not have to
// fork this file to attach its own behaviour to a tab. Each of them fails SILENTLY when
// it is wrong: a tab built down a path nobody announced simply has no sealed-region
// handling and no navigation guard, and a navigation that leaves by the door the pacer
// does not watch is simply never metered. Nothing throws, nothing logs. These tests are
// the only thing that notices.

/// Ordered `"a|b"` lines, so one recorder serves every seam and the assertion reads as
/// the sequence the host would have observed.
@MainActor
private final class SeamLog {
    private(set) var lines: [String] = []
    func record(_ first: String, _ second: String?) { lines.append("\(first)|\(second ?? "-")") }
}

@MainActor
private final class CreatedTabLog {
    private(set) var handles: [CDPTabHandle] = []
    func record(_ handle: CDPTabHandle) { handles.append(handle) }
    var ids: [String] { handles.map(\.id) }
    var distinctHandles: Int { Set(handles.map(ObjectIdentifier.init)).count }
}

@MainActor
private func connectedMock() async throws -> (MockCDP, CDPClient) {
    let cdp = MockCDP()
    let channel = cdp.channel()
    let client = CDPClient(channel: channel)
    try await client.connect()
    return (cdp, client)
}

@Suite("Tabs injection seams")
struct TabsInjectionSeamTests {

    @Test("onTabCreated fires exactly once per handle, on every path that builds one")
    @MainActor
    func onTabCreatedCoversEveryCreationPath() async throws {
        let (cdp, client) = try await connectedMock()
        cdp.addTarget(id: "seeded-target", url: "https://example.com/seeded", title: "Seeded")

        let log = CreatedTabLog()
        let service = await makeCDPBrowserTabsService(
            client: client,
            seed: true,
            onTabCreated: { log.record($0) })
        let model = try #require(service.window?.tabs as? CDPTabsModel)

        // Path 2 of 4: the tab this session opens. Its real Chrome target does not exist
        // yet, so it is announced under the provisional id.
        let created = model.createTab(TabCreateSpec(
            tabType: "website", url: "https://example.com/opened", openedByHuman: false,
            agentControllerId: "agent-1", sessionId: "agent-1"))

        // Path 3 of 4: a live target this model never saw, addressed by id.
        cdp.addTarget(id: "live-target", url: "https://example.com/live", title: "Live")
        let adopting: LivePageTargetAdopting = model
        _ = await adopting.adoptLiveTarget("live-target")

        // Path 4 of 4: the target a click spawned, diffed against a pre-click snapshot.
        let spawnAdopting: ClickSpawnedTabAdopting = model
        let before = await spawnAdopting.currentPageTargetIds()
        cdp.addTarget(id: "spawned-target", url: "https://example.com/spawned", title: "Spawned")
        let spawned = await spawnAdopting.adoptSpawnedTabs(notIn: before)
        #expect(spawned.count == 1, "the spawned-target diff adopted \(spawned.count) tabs")

        #expect(log.ids.sorted() == ["live-target", "seeded-target", "spawned-target", created.id].sorted())
        #expect(log.distinctHandles == 4, "a handle was announced more than once")

        // Re-addressing an already-tracked target returns the handle it already has, and
        // must not announce it again — an `onTabCreated` that re-fires installs the
        // host's hooks twice on one tab.
        _ = await adopting.adoptLiveTarget("live-target")
        _ = await spawnAdopting.adoptSpawnedTabs(notIn: before)
        #expect(log.handles.count == 4, "a re-adoption announced an already-known tab")
    }

    @Test("onTabCreated runs before the control flags are written, so the first transition is seen")
    @MainActor
    func onTabCreatedPrecedesTheFirstControlTransition() async throws {
        let (_, client) = try await connectedMock()
        let log = SeamLog()
        let service = await makeCDPBrowserTabsService(
            client: client,
            seed: false,
            onTabCreated: { handle in
                handle.onControlStateChange = { isAI, isAgent in log.record("\(isAI)", "\(isAgent)") }
            })
        _ = service.window!.tabs.createTab(TabCreateSpec(
            tabType: "website", url: "https://example.com", openedByHuman: false,
            agentControllerId: "agent-1", sessionId: "agent-1"))

        // `createTab` puts the tab under the agent immediately, and that is the only such
        // call a read ever makes (`markTabAgentControlled` finds it already owned and
        // returns). Announce the handle after it and a host's navigation guard never
        // learns the tab became its own.
        #expect(log.lines == ["false|true"])
    }

    @Test("the pacer gates the open path: a refused turn creates no target")
    @MainActor
    func pacerGatesTheOpenPath() async throws {
        let (cdp, client) = try await connectedMock()
        let log = SeamLog()
        let service = await makeCDPBrowserTabsService(
            client: client,
            seed: false,
            navigationPacer: { url, profileId, _ in
                log.record(url, profileId)
                throw SimpleBrowserError("no turn")
            })
        let tab = service.window!.tabs.createTab(TabCreateSpec(
            tabType: "website", url: "https://example.com/opened", openedByHuman: false))

        let result = try await tab.wake(nil)

        #expect(!result.ok)
        // `-` is the absent profile: the open path has no budget to charge against.
        #expect(log.lines == ["https://example.com/opened|-"])
        // The whole point: an open navigates by BEING CREATED, so the refusal has to land
        // before `Target.createTarget`, not after the page has already been fetched.
        #expect(!cdp.received("Target.createTarget"))
    }

    @Test("the pacer gates the bridge goto path, and is handed the profile to charge")
    @MainActor
    func pacerGatesTheGotoPath() async throws {
        let (cdp, client) = try await connectedMock()
        let log = SeamLog()
        let service = await makeCDPBrowserTabsService(
            client: client,
            seed: false,
            navigationPacer: { url, profileId, _ in
                log.record(url, profileId)
                throw SimpleBrowserError("no turn")
            })
        let tab = service.window!.tabs.createTab(TabCreateSpec(
            tabType: "website", url: "https://example.com", openedByHuman: false))
        let handle = try #require(tab as? CDPTabHandle)

        let bridge = AgentBrowserBridge(backend: CDPAgentBridgeBackend(tab: handle))
        bridge.boundToProfile("profile-1")
        let result = await bridge.goto("https://example.com/next")

        #expect(result.isError)
        #expect(log.lines == ["https://example.com/next|profile-1"])
        #expect(!cdp.received("Page.navigate"))
    }

    @Test("a granted turn lets both doors through")
    @MainActor
    func grantedTurnNavigatesOnBothPaths() async throws {
        let (cdp, client) = try await connectedMock()
        let log = SeamLog()
        let service = await makeCDPBrowserTabsService(
            client: client,
            seed: false,
            navigationPacer: { url, profileId, _ in log.record(url, profileId) })
        let tab = service.window!.tabs.createTab(TabCreateSpec(
            tabType: "website", url: "https://example.com", openedByHuman: false))
        let handle = try #require(tab as? CDPTabHandle)

        let woke = try await handle.wake(nil)
        #expect(woke.ok)
        #expect(cdp.received("Target.createTarget"))

        try await handle.navigateToURL("https://example.com/next", profileId: "profile-1", signal: nil)
        #expect(cdp.received("Page.navigate"))

        #expect(log.lines == ["https://example.com|-", "https://example.com/next|profile-1"])
    }

    @Test("the pacer is asked one turn per tab opened, not one per read")
    @MainActor
    func wakeOnAnAlreadyCreatedTabAsksForNoTurn() async throws {
        let (_, client) = try await connectedMock()
        let log = SeamLog()
        let service = await makeCDPBrowserTabsService(
            client: client,
            seed: false,
            navigationPacer: { url, profileId, _ in log.record(url, profileId) })
        let tab = service.window!.tabs.createTab(TabCreateSpec(
            tabType: "website", url: "https://example.com", openedByHuman: false))

        _ = try await tab.wake(nil)
        _ = try await tab.wake(nil)
        _ = try await tab.wake(nil)

        // A re-read of an open tab fetches nothing; charging it a turn would throttle the
        // agent for looking at a page it already has.
        #expect(log.lines.count == 1)
    }

    @Test("this package does not conform CDPTabHandle to PageReadRemediating")
    @MainActor
    func packageLeavesTheRemediationProbeUnconformed() async throws {
        let fixture = try await makePageToolsCDPFixture()
        let tab = try #require(fixture.tabsService.window!.tabs.tab(fixture.tabId))

        #expect(tab is CDPTabHandle, "the fixture no longer yields the handle under test")
        // The host conforms this retroactively. A conformance added HERE would take over
        // silently: `manage_tabs read` would call the package's own `remediateAfterRead`
        // instead of the host's, and the host's CAPTCHA path would go dead with every
        // test still green.
        #expect(tab as? PageReadRemediating == nil)
    }
}
