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
        client: client, chatId: "alohajet", seededTabsAreHuman: true, agentOwnedTabIds: agentOwned)
    return try #require(service.window).tabs
}

@Test @MainActor func aSeededTabRecordedAsTheAgentsIsNotTheUsers() async throws {
    let tabs = try await seededModel(agentOwned: ["agents-target"])
    #expect(tabs.tab("users-target")?.attribution.owner == .user)
    #expect(tabs.tab("agents-target")?.attribution.owner == .chat("alohajet"))
}

@Test @MainActor func everySeededTabStaysTheUsersWhenNothingWasRecorded() async throws {
    let tabs = try await seededModel(agentOwned: [])
    #expect(tabs.tab("users-target")?.attribution.owner == .user)
    #expect(tabs.tab("agents-target")?.attribution.owner == .user)
}

@Test @MainActor func aTabAdoptedByIdRecordedAsTheAgentsIsNotTheUsers() async throws {
    let cdp = MockCDP()
    cdp.addTarget(id: "users-target", url: "https://user.example/")
    cdp.addTarget(id: "agents-target", url: "https://agent.example/")
    let channel = cdp.channel()
    let client = CDPClient(channel: channel)
    try await client.connect()
    let service = await makeCDPBrowserTabsService(
        client: client, seed: false, chatId: "alohajet", seededTabsAreHuman: true,
        agentOwnedTabIds: ["agents-target"])
    let adopting = try #require(service.window?.tabs as? LivePageTargetAdopting)
    let agents = await adopting.adoptLiveTarget("agents-target")
    let users = await adopting.adoptLiveTarget("users-target")
    #expect(agents?.attribution.owner == .chat("alohajet"))
    #expect(users?.attribution.owner == .user)
}

@Test func recordedOwnershipIsIgnoredWhenTheBrowserIsNotTheOneItWasRecordedAgainst() {
    let recorded = AgentOwnedTabs(endpoint: "ws://127.0.0.1:9222/devtools/browser/old", ids: ["t1"])
    #expect(recorded.ids(matching: "ws://127.0.0.1:9222/devtools/browser/old") == ["t1"])
    #expect(recorded.ids(matching: "ws://127.0.0.1:9222/devtools/browser/new").isEmpty)
}
