import Foundation
import Testing
import ToolABI
@testable import BrowserTools

// The cap on this session's agent tabs: 402 opens against 26 closes on run 34032045467, and the
// tab count is what decided whether the run was graded on the page the agent worked on. It is a
// policy, off by default — a user's tabs are not closed under them because a benchmark grader
// reads an arbitrary context.

@MainActor private func capFixture(_ policy: TabHousekeepingPolicy)
    -> (PageToolsStubTabsModel, PageToolsStubSession, ToolExecutionContext) {
    let model = PageToolsStubTabsModel([])
    let session = PageToolsStubSession()
    let services = NativeToolServices(
        tabsService: PageToolsStubTabsService(PageToolsStubTabsWindow(model)), session: session,
        tabHousekeeping: policy)
    return (model, session, makePageToolContext(services: services))
}

@MainActor private func openTab(_ url: String, use: Bool = true, _ context: ToolExecutionContext) async throws -> RawToolResult {
    var arguments: [String: WorkflowValue] = ["action": .string("open"), "url": .string(url)]
    if !use { arguments["use"] = .bool(false) }
    return try await ManageTabsExecutorTool().execute(.object(arguments), context)
}

@Suite("agent tab cap") @MainActor struct AgentTabCapTests {

    @Test("off by default: every open adds a tab and nothing is closed")
    func defaultPolicyDoesNotTrim() async throws {
        let (model, _, context) = capFixture(.off)
        for i in 1...5 { _ = try await openTab("http://h/p\(i)", context) }
        #expect(model.orderedTabs.count == 5)
    }

    @Test("over the cap, the oldest tab goes and the receipt says so")
    func theOldestTabGoes() async throws {
        let (model, _, context) = capFixture(TabHousekeepingPolicy(maxAgentTabs: 2))
        _ = try await openTab("http://h/p1", context)
        _ = try await openTab("http://h/p2", context)
        let oldest = try #require(model.orderedTabs.first).id

        let third = try await openTab("http://h/p3", context)

        #expect(model.orderedTabs.count == 2)
        #expect(model.tab(oldest) == nil)
        #expect(third.output.contains("Closed 1 older tab(s) of yours to stay under the 2-tab limit"))
        #expect(third.output.contains(oldest))
        #expect(third.output.contains("Any aloha-id from those tabs is gone"))
    }

    /// The tab in use is resolved the way the page tools resolve it — the session's pointer —
    /// so a background open never closes the page the agent is working in.
    @Test("the tab in use is never the victim, even when it is the oldest")
    func theTabInUseIsProtected() async throws {
        let (model, session, context) = capFixture(TabHousekeepingPolicy(maxAgentTabs: 2))
        _ = try await openTab("http://h/working", context)
        let working = try #require(session.active)
        _ = try await openTab("http://h/p2", use: false, context)
        #expect(session.active == working)

        _ = try await openTab("http://h/p3", use: false, context)

        #expect(model.orderedTabs.count == 2)
        #expect(model.tab(working) != nil)
        #expect(session.active == working)
    }

    @Test("the user's tabs do not count against the cap and are never closed by it")
    func theUsersTabsAreOutsideTheCap() async throws {
        let (model, _, context) = capFixture(TabHousekeepingPolicy(maxAgentTabs: 1))
        let seeded = model.createTab(TabCreateSpec(tabType: "website", url: "http://h/theirs", openedByHuman: true))

        _ = try await openTab("http://h/p1", context)
        _ = try await openTab("http://h/p2", context)

        #expect(model.tab(seeded.id) != nil)
        #expect(model.orderedTabs.filter { !$0.openedByHuman }.count == 1)
    }
}
