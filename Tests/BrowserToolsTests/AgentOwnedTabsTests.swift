import Foundation
import Testing
import ToolABI
import CDP
@testable import BrowserTools

@MainActor
private func seededModel(agentOwned: Set<String>) async throws -> TabsModel {
    let cdp = MockCDP()
    cdp.addTarget(id: "users-target", url: "https://user.example/")
    cdp.addTarget(id: "agents-target", url: "https://agent.example/")
    let channel = cdp.channel()
    let client = CDPClient(channel: channel)
    try await client.connect()
    let service = await makeCDPBrowserTabsService(
        client: client, seededTabsAreHuman: true, agentOwnedTabIds: agentOwned)
    return try #require(service.window).tabs
}

@Test @MainActor func aSeededTabRecordedAsTheAgentsIsNotTheUsers() async throws {
    let tabs = try await seededModel(agentOwned: ["agents-target"])
    #expect(tabs.tab("users-target")?.openedByHuman == true)
    #expect(tabs.tab("agents-target")?.openedByHuman == false)
}

@Test @MainActor func everySeededTabStaysTheUsersWhenNothingWasRecorded() async throws {
    let tabs = try await seededModel(agentOwned: [])
    #expect(tabs.tab("users-target")?.openedByHuman == true)
    #expect(tabs.tab("agents-target")?.openedByHuman == true)
}

@Test @MainActor func aRestoredTabRecordedAsTheAgentsIsNotTheUsers() async throws {
    let cdp = MockCDP()
    cdp.addTarget(id: "agents-target", url: "https://agent.example/")
    let channel = cdp.channel()
    let client = CDPClient(channel: channel)
    try await client.connect()
    let service = await makeCDPBrowserTabsService(
        client: client, seed: false, seededTabsAreHuman: true,
        agentOwnedTabIds: ["agents-target"])
    let tabs = try #require(service.window).tabs
    #expect(tabs.getOrRestoreTab("agents-target", restoreIfNeeded: true)?.openedByHuman == false)
    #expect(tabs.getOrRestoreTab("users-target", restoreIfNeeded: true)?.openedByHuman == true)
}

@Test func recordedOwnershipIsIgnoredWhenTheBrowserIsNotTheOneItWasRecordedAgainst() {
    let recorded = AgentOwnedTabs(endpoint: "ws://127.0.0.1:9222/devtools/browser/old", ids: ["t1"])
    #expect(recorded.ids(matching: "ws://127.0.0.1:9222/devtools/browser/old") == ["t1"])
    #expect(recorded.ids(matching: "ws://127.0.0.1:9222/devtools/browser/new").isEmpty)
}
