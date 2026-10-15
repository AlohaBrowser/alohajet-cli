import Foundation
import Testing
import ToolABI
import CDP
@testable import BrowserTools

@MainActor private final class ReconciliationSource: TabAttributionSource {
    var foregroundTabId: String?
    var owners: [String: TabOwner] = [:]
    func owner(of tabId: String) -> TabOwner { owners[tabId] ?? .user }
    func attribute(_ tabId: String, to chatId: String) { owners[tabId] = .chat(chatId) }
}

@Suite @MainActor struct TabReconciliationTests {
    private func model(_ cdp: MockCDP, source: TabAttributionSource? = nil, chatId: String? = "chat-A", seed: Bool = true) async throws -> CDPTabsModel {
        let channel = cdp.channel()
        let client = CDPClient(channel: channel)
        try await client.connect()
        let service = await makeCDPBrowserTabsService(client: client, seed: seed, chatId: chatId, attributionSource: source)
        return try #require(service.window?.tabs as? CDPTabsModel)
    }

    private func held(_ cdp: MockCDP, count: Int = 1) async throws {
        let deadline = Date().addingTimeInterval(5)
        while cdp.heldReplies.count < count && Date() < deadline { await Task.yield() }
        try #require(cdp.heldReplies.count == count)
    }

    private func open(_ model: CDPTabsModel) throws -> CDPTabHandle {
        try #require(model.createTab(.init(tabType: "website", url: "https://example.com", owner: .chat("chat-A"))) as? CDPTabHandle)
    }

    @Test func visibleCreationKeepsItsOriginalHandleAndOwner() async throws {
        let cdp = MockCDP()
        let source = ReconciliationSource()
        let model = try await model(cdp, source: source)
        let tab = try open(model)
        let provisional = tab.id
        cdp.holdNextMethod = "Target.createTarget"
        let creating = Task { try await tab.createInBrowser() }
        try await held(cdp)
        var listingStarted = false
        let listing = Task {
            listingStarted = true
            await model.syncTabsWithBrowser()
        }
        // MainActor runs the listing through its first suspension before this resumes.
        while !listingStarted { await Task.yield() }
        // The browser already lists the target but its creator does not yet know its id.
        #expect(model.orderedTabs.count == 1)
        cdp.releaseHeldReply()
        try await creating.value
        await listing.value
        #expect(model.orderedTabs.count == 1)
        #expect(model.tab(tab.id) === tab)
        #expect(model.tab(provisional) === tab)
        #expect(!tab.session.isDestroyed)
        #expect(tab.attribution.owner == .chat("chat-A"))
        source.owners[tab.id] = .user
        #expect(tab.attribution.owner == .user)
        #expect(cdp.commands(for: "Target.createTarget").count == 1)
    }

    @Test func overlappingCreationsKeepBothHandlesWhileSyncWaitsForTheirIds() async throws {
        let cdp = MockCDP()
        let model = try await model(cdp)
        let first = try open(model)
        let second = try open(model)
        cdp.holdNextMethod = "Target.createTarget"
        let firstCreation = Task { try await first.createInBrowser() }
        try await held(cdp)
        cdp.holdNextMethod = "Target.createTarget"
        let secondCreation = Task { try await second.createInBrowser() }
        try await held(cdp, count: 2)
        let listing = Task { await model.syncTabsWithBrowser() }
        cdp.releaseHeldReply(at: 1)
        try await secondCreation.value
        #expect(model.orderedTabs.count == 2)
        cdp.releaseHeldReply()
        try await firstCreation.value
        await listing.value
        #expect(model.orderedTabs.count == 2)
        #expect(Set(model.orderedTabs.map(\.id)).count == 2)
        #expect(model.tab(first.id) === first)
        #expect(model.tab(second.id) === second)
        #expect(model.orderedTabs.allSatisfy { $0.attribution.owner == .chat("chat-A") })
    }

    @Test func snapshotBeforeCreationCannotDestroyNewHandle() async throws {
        let cdp = MockCDP()
        cdp.addTarget(id: "old", url: "https://old.example")
        let model = try await model(cdp)
        cdp.removeTarget(id: "old")
        cdp.holdNextMethod = "Target.getTargets"
        let listing = Task { await model.syncTabsWithBrowser() }
        try await held(cdp)
        let tab = try open(model)
        try await tab.createInBrowser()
        cdp.releaseHeldReply()
        await listing.value
        #expect(model.tab(tab.id) === tab)
        #expect(!tab.session.isDestroyed)
        #expect(model.tab("old") == nil) // Real removals still reconcile.
        #expect(model.orderedTabs.count == 1)
    }

    @Test func olderSyncCannotUndoNewerSync() async throws {
        let cdp = MockCDP()
        cdp.addTarget(id: "old", url: "https://old.example")
        let model = try await model(cdp)
        cdp.holdNextMethod = "Target.getTargets"
        let oldListing = Task { await model.syncTabsWithBrowser() }
        try await held(cdp)
        cdp.removeTarget(id: "old")
        cdp.addTarget(id: "new", url: "https://new.example")
        await model.syncTabsWithBrowser()
        let new = try #require(model.tab("new"))
        cdp.releaseHeldReply()
        await oldListing.value
        #expect(model.tab("old") == nil)
        #expect(model.tab("new") === new)
        #expect(model.orderedTabs.count == 1)
    }

    @Test func failedCreationReleasesListingBarrierAndCanRetry() async throws {
        let cdp = MockCDP()
        let model = try await model(cdp)
        let tab = try open(model)
        cdp.methodsNotImplemented.insert("Target.createTarget")
        cdp.holdNextMethod = "Target.createTarget"
        let creating = Task { try await tab.createInBrowser() }
        try await held(cdp)
        let listing = Task { await model.syncTabsWithBrowser() }
        cdp.addTarget(id: "unrelated", url: "https://other.example")
        cdp.releaseHeldReply()
        do { try await creating.value; Issue.record("creation should fail") } catch {}
        await listing.value
        #expect(model.tab("unrelated") != nil)
        #expect(!tab.session.isDestroyed)
        cdp.methodsNotImplemented.remove("Target.createTarget")
        try await tab.createInBrowser()
        await model.syncTabsWithBrowser()
        #expect(model.tab(tab.id) === tab)
        #expect(model.orderedTabs.count == 2)
    }

    @Test(arguments: [false, true], [false, true]) func listingDoesNotSuppressPopupResult(useSource: Bool, chatScoped: Bool) async throws {
        let cdp = MockCDP()
        cdp.addTarget(id: "parent", url: "https://example.com")
        let source = ReconciliationSource()
        let model = try await model(cdp, source: useSource ? source : nil, chatId: chatScoped ? "chat-A" : nil)
        let before = await model.currentPageTargetIds()
        cdp.addTarget(id: "popup", url: "https://example.com/popup")
        source.owners["popup"] = .chat("chat-B")
        await model.syncTabsWithBrowser()
        let discovered = try #require(model.tab("popup"))
        cdp.addTarget(id: "popup", url: "https://example.com/settled")
        let adopted = await model.adoptSpawnedTabs(notIn: before)
        #expect(adopted.map(\.id) == ["popup"])
        #expect(adopted.map(\.url) == ["https://example.com/settled"])
        #expect(model.tab("popup") === discovered)
        #expect(discovered.attribution.owner == (useSource ? .chat("chat-B") : (chatScoped ? .chat("chat-A") : .user)))
        #expect(model.tab("parent")?.attribution.owner == .user)
        #expect(await model.adoptSpawnedTabs(notIn: before).isEmpty)
        #expect(cdp.commands(for: "Target.createTarget").isEmpty)
    }

    @Test func preexistingAndClosedTargetsAreNeverAdoptedAsPopups() async throws {
        let cdp = MockCDP()
        let model = try await model(cdp)
        cdp.addTarget(id: "existing", url: "https://example.com")
        await model.syncTabsWithBrowser()
        let before = await model.currentPageTargetIds()
        #expect(await model.adoptSpawnedTabs(notIn: before).isEmpty)
        #expect(model.tab("existing")?.attribution.owner == .user)
        await model.closeTab("existing", skipConfirm: true)
        cdp.addTarget(id: "existing", url: "https://example.com") // delayed close visibility
        #expect(await model.adoptSpawnedTabs(notIn: []).isEmpty)
        #expect(model.tab("existing") == nil)
    }

    @Test(arguments: [false, true], [false, true])
    func retriedSyncIsOrderedByItsActualRequest(removeTarget: Bool, failedCreation: Bool) async throws {
        let cdp = MockCDP()
        cdp.addTarget(id: "existing", url: "https://example.com/old")
        let model = try await model(cdp)
        let existing = try #require(model.tab("existing") as? CDPTabHandle)
        cdp.holdNextMethod = "Target.getTargets"
        let first = Task { await model.syncTabsWithBrowser() }
        try await held(cdp)

        let created = try open(model)
        let provisional = created.id
        if failedCreation { cdp.methodsNotImplemented.insert("Target.createTarget") }
        do {
            try await created.createInBrowser()
            #expect(!failedCreation)
        } catch { #expect(failedCreation) }
        cdp.methodsNotImplemented.remove("Target.createTarget")
        cdp.holdNextMethod = "Target.getTargets"
        let second = Task { await model.syncTabsWithBrowser() }
        try await held(cdp, count: 2)
        if removeTarget {
            cdp.removeTarget(id: "existing")
        } else {
            cdp.addTarget(id: "existing", url: "https://example.com/new", title: "New title")
        }
        cdp.releaseHeldReply()
        await first.value // Epoch retry now applies a newer actual request than second.
        #expect(model.tab("existing")?.url == (removeTarget ? nil : "https://example.com/new"))
        cdp.releaseHeldReply()
        await second.value
        #expect(model.tab("existing")?.url == (removeTarget ? nil : "https://example.com/new"))
        #expect(existing.session.isDestroyed == removeTarget)
        if !removeTarget {
            #expect(model.tab("existing") === existing)
            #expect(existing.title == "New title")
        }
        #expect(model.tab(provisional) === created)
        #expect(model.tab(created.id) === created)
        #expect(!created.session.isDestroyed)
        #expect(Set(model.orderedTabs.map(\.id)).count == model.orderedTabs.count)
    }

    @Test(arguments: [false, true], [false, true])
    func delayedPopupAdoptionRefreshesAfterNewerListing(popupRemainsLive: Bool, useSource: Bool) async throws {
        let cdp = MockCDP()
        cdp.addTarget(id: "parent", url: "https://example.com")
        let source = ReconciliationSource()
        let model = try await model(cdp, source: useSource ? source : nil)
        let before = await model.currentPageTargetIds()
        cdp.addTarget(id: "popup", url: "https://example.com/popup")
        source.owners["popup"] = .chat("chat-B")
        await model.syncTabsWithBrowser()
        let original = try #require(model.tab("popup") as? CDPTabHandle)
        model.setActiveTabId("popup")
        cdp.holdNextMethod = "Target.getTargets"
        let adoption = Task { await model.adoptSpawnedTabs(notIn: before) }
        try await held(cdp)
        if popupRemainsLive {
            cdp.addTarget(id: "popup", url: "https://example.com/settled", title: "Settled")
        } else {
            cdp.removeTarget(id: "popup")
        }
        await model.syncTabsWithBrowser()
        #expect(original.session.isDestroyed == !popupRemainsLive)
        cdp.releaseHeldReply()
        let adopted = await adoption.value
        if popupRemainsLive {
            #expect(adopted.map(\.id) == ["popup"])
            #expect(adopted.map(\.url) == ["https://example.com/settled"])
            #expect(adopted.map(\.title) == ["Settled"])
            #expect(model.tab("popup") === original)
            #expect(original.attribution.owner == .chat(useSource ? "chat-B" : "chat-A"))
            #expect(model.activeTabId == "popup")
        } else {
            #expect(adopted.isEmpty)
            #expect(model.tab("popup") == nil)
            #expect(model.activeTabId == nil)
        }
        #expect(await model.adoptSpawnedTabs(notIn: before).isEmpty)
        #expect(model.tab("parent") != nil)
        #expect(cdp.commands(for: "Target.createTarget").isEmpty)
    }

    @Test func newerPopupAdoptionSupersedesOlderListingMetadata() async throws {
        let cdp = MockCDP()
        let model = try await model(cdp)
        let before = await model.currentPageTargetIds()
        cdp.addTarget(id: "popup", url: "https://example.com/old")
        cdp.holdNextMethod = "Target.getTargets"
        let listing = Task { await model.syncTabsWithBrowser() }
        try await held(cdp)
        cdp.addTarget(id: "popup", url: "https://example.com/new")
        let adopted = await model.adoptSpawnedTabs(notIn: before)
        let handle = try #require(model.tab("popup"))
        #expect(adopted.map(\.id) == ["popup"])
        cdp.releaseHeldReply()
        await listing.value
        #expect(model.tab("popup") === handle)
        #expect(handle.url == "https://example.com/new")
        #expect(handle.attribution.owner == .chat("chat-A"))
    }


    @Test(arguments: [false, true])
    func delayedSeedOrLiveAdmissionCannotReviveRemovedTarget(seedAdmission: Bool) async throws {
        let cdp = MockCDP()
        cdp.addTarget(id: "existing", url: "https://example.com")
        let model = try await model(cdp, seed: false)
        cdp.holdNextMethod = "Target.getTargets"
        let admission = Task {
            if seedAdmission {
                await model.seedFromBrowser()
                return model.tab("existing")
            }
            return await model.adoptLiveTarget("existing")
        }
        try await held(cdp)
        await model.syncTabsWithBrowser()
        let original = try #require(model.tab("existing") as? CDPTabHandle)
        cdp.removeTarget(id: "existing")
        await model.syncTabsWithBrowser()
        #expect(original.session.isDestroyed)
        cdp.releaseHeldReply()
        #expect(await admission.value == nil)
        #expect(model.tab("existing") == nil)
        #expect(model.orderedTabs.isEmpty)
        cdp.addTarget(id: "live-control", url: "https://example.com/live")
        let live = await model.adoptLiveTarget("live-control")
        #expect(live?.id == "live-control")
        #expect(live?.attribution.owner == .user)
    }

}
