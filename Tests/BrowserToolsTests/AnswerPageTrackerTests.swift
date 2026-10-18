import Testing
import Foundation
import ToolABI
import CDP
@testable import BrowserTools

// MARK: - The page the answer was read from, and the close that waits for its receipts
//
// hn-swift-r80 (2026-10-01): the agent closed the tab it had read, and the turn's answer receipts
// were then looked for on another tab. Receipts come from the last observed tab or not at all; a
// close of that tab waits until they are taken -- only while a runner that flushes has asked.
// Ported from the agent repository (windows-on-snips `AnswerPageTrackerTests`), plus the package
// side: the page tools note into the tracker, and a turn can bind its own.

@MainActor private final class TrackerSession: ChatModeSession {
    var active: String?
    func sessionNetworkDir() -> String? { nil }
    func registerNetworkRecordingTab(_ tab: TabHandle) {}
    func unregisterNetworkRecordingTab(_ tabId: String) {}
    func setActiveBrowserTab(_ tabId: String?) { active = tabId }
    func getActiveBrowserTabId() -> String? { active }
    func clearActiveBrowserTabIfMatches(_ tabId: String) { if active == tabId { active = nil } }
}

/// One chat's tool services, keeping that chat's tracker (a host running several chats at once).
@MainActor private final class ChatServices: NativeToolServices, AnswerPageTrackerOwning {
    let answerPageTracker = AnswerPageTracker()
}

@MainActor
@Suite("Answer page tracker")
struct AnswerPageTrackerTests {

    @Test func theLatestObservationIsTheAnswerPage() {
        let t = AnswerPageTracker()
        t.beginTurn(deferringCloses: true)
        #expect(t.observedTargetId == nil)
        t.noteObservation(targetId: "T1")
        t.noteObservation(targetId: "T2")
        #expect(t.observedTargetId == "T2")
    }

    @Test func aCloseOfTheObservedTabWaitsAndOthersDoNot() {
        let t = AnswerPageTracker()
        t.beginTurn(deferringCloses: true)
        t.noteObservation(targetId: "T1")
        #expect(t.deferCloseIfObserved(tabId: "tab-a", targetId: "T1"))
        #expect(!t.deferCloseIfObserved(tabId: "tab-b", targetId: "T2"))
        #expect(!t.deferCloseIfObserved(tabId: "tab-c", targetId: nil))
        #expect(t.deferCloseIfObserved(tabId: "tab-a", targetId: "T1"))     // asked twice, recorded once
        #expect(t.isCloseDeferred(tabId: "tab-a"))
        #expect(t.takeDeferredCloses() == ["tab-a"])
        // Flushed: nothing waits for the rest of the turn.
        #expect(!t.deferCloseIfObserved(tabId: "tab-a", targetId: "T1"))
        #expect(t.takeDeferredCloses().isEmpty)
    }

    /// Off unless a runner that flushes turned it on: the GUI path never keeps a tab open.
    @Test func withoutARunnerNothingIsDeferred() {
        let t = AnswerPageTracker()
        t.noteObservation(targetId: "T1")
        #expect(!t.deferCloseIfObserved(tabId: "tab-a", targetId: "T1"))
        t.beginTurn(deferringCloses: false)
        t.noteObservation(targetId: "T1")
        #expect(!t.deferCloseIfObserved(tabId: "tab-a", targetId: "T1"))
    }

    /// github-ss-r87: the answer receipt prefers the element `get_text` read, so reads are kept per
    /// tab, oldest first, a re-read moved last, and forgotten by the next turn.
    @Test func readsAreKeptPerTabInOrderAndForgottenByTheNextTurn() {
        let t = AnswerPageTracker()
        t.beginTurn(deferringCloses: true)
        t.noteRead(alohaId: "before-any-page")                  // no page yet: nothing to attach it to
        t.noteObservation(targetId: "T1")
        t.noteRead(alohaId: "a")
        t.noteRead(alohaId: "b")
        t.noteRead(alohaId: "a")
        t.noteObservation(targetId: "T2")
        t.noteRead(alohaId: "c")
        #expect(t.readIds(onTarget: "T1") == ["b", "a"])
        #expect(t.readIds(onTarget: "T2") == ["c"])
        t.beginTurn(deferringCloses: true)
        #expect(t.readIds(onTarget: "T1").isEmpty)
    }

    @Test func aNewTurnForgetsTheLastOne() {
        let t = AnswerPageTracker()
        t.beginTurn(deferringCloses: true)
        t.noteObservation(targetId: "T1")
        _ = t.deferCloseIfObserved(tabId: "tab-a", targetId: "T1")
        t.beginTurn(deferringCloses: true)
        #expect(t.observedTargetId == nil)
        #expect(t.takeDeferredCloses().isEmpty)
    }

    /// A turn bound with `tracking` notes into its own tracker; outside it, `current` is `shared`.
    @Test func aBoundTurnHasItsOwnTracker() async {
        let mine = AnswerPageTracker()
        #expect(AnswerPageTracker.current === AnswerPageTracker.shared)
        await mine.tracking {
            #expect(AnswerPageTracker.current === mine)
            AnswerPageTracker.current.noteObservation(targetId: "T9")
        }
        #expect(mine.observedTargetId == "T9")
        #expect(AnswerPageTracker.current === AnswerPageTracker.shared)
    }

    // MARK: The page tools feed it

    /// `get_text` on a real (MockCDP-backed) tab: the tab is the observed page and the element read
    /// is remembered on it; a failed read is not.
    @Test func getTextNotesThePageAndTheElementRead() async throws {
        let fixture = try await makePageToolsCDPFixture()
        defer { Task { await fixture.client.close() } }
        fixture.cdp.alohaRawCallReplies = [(match: "__aloha.getText(", reply: .string("v3.8.5"))]
        let services = NativeToolServices(tabsService: fixture.tabsService)
        let tracker = AnswerPageTracker()
        tracker.beginTurn(deferringCloses: false)
        let result = try await tracker.tracking {
            try await GetTextExecutorTool().execute(
                .object(["aloha_id": .string("only-this-test-1")]), makePageToolContext(services: services))
        }
        #expect(result.isError != true)
        let window = try #require(fixture.tabsService.window)
        // Noted by the CDP target id: the id the tab carries once the browser made it.
        let targetId = try #require(window.tabs.tab(fixture.tabId)).id
        let observed = try #require(tracker.observedTab(in: window))
        #expect(observed.id == targetId)
        #expect(tracker.observedTargetId == targetId)
        #expect(tracker.readIds(onTarget: targetId) == ["only-this-test-1"])
        // The process-wide tracker was not touched by this bound turn. (Other tests' page tools
        // note into it concurrently, on MockCDP tabs with the same target ids, so only this test's
        // own read is looked for.)
        #expect(!AnswerPageTracker.shared.readIds(onTarget: targetId).contains("only-this-test-1"))
    }

    /// `manage_tabs close` of the observed tab, while a runner defers: answered as closed, the tab
    /// stays until the runner flushes after its receipts. Without deferral it closes at once.
    @Test func closingTheObservedTabWaitsForTheRunner() async throws {
        let fixture = try await makePageToolsCDPFixture()
        defer { Task { await fixture.client.close() } }
        fixture.cdp.alohaRawCallReplies = [(match: "__aloha.getText(", reply: .string("v3.8.5"))]
        let services = NativeToolServices(tabsService: fixture.tabsService, session: TrackerSession())
        let window = try #require(fixture.tabsService.window)
        let tracker = AnswerPageTracker()
        tracker.beginTurn(deferringCloses: true)
        try await tracker.tracking {
            _ = try await GetTextExecutorTool().execute(
                .object(["aloha_id": .string("x")]), makePageToolContext(services: services))
            let closed = try await ManageTabsExecutorTool().execute(
                .object(["action": .string("close"), "tab_id": .string(fixture.tabId)]),
                makePageToolContext(services: services))
            #expect(closed.isError != true)
            #expect(closed.output.contains("Closed:"))
            #expect(!closed.output.contains("in use"))
        }
        let open = try #require(window.tabs.tab(fixture.tabId))     // still open: the receipts come first
        #expect(tracker.observedTab(in: window)?.id == open.id)
        #expect(window.tabs.activeTabId == nil)                       // but out of use, as a closed tab is
        let next = try await GetTextExecutorTool().execute(
            .object(["aloha_id": .string("x")]), makePageToolContext(services: services))
        #expect(next.isError == true)                                 // no page tool acts on it any more
        #expect(await tracker.closeDeferredTabs(in: window) == [fixture.tabId])
        #expect(window.tabs.tab(fixture.tabId) == nil)
        #expect(tracker.observedTab(in: window) == nil)
        #expect(await tracker.closeDeferredTabs(in: window).isEmpty)
    }

    @Test func withoutDeferralTheCloseHappensAtOnce() async throws {
        let fixture = try await makePageToolsCDPFixture()
        defer { Task { await fixture.client.close() } }
        fixture.cdp.alohaRawCallReplies = [(match: "__aloha.getText(", reply: .string("v3.8.5"))]
        let services = NativeToolServices(tabsService: fixture.tabsService, session: TrackerSession())
        let window = try #require(fixture.tabsService.window)
        let tracker = AnswerPageTracker()
        tracker.beginTurn(deferringCloses: false)
        try await tracker.tracking {
            _ = try await GetTextExecutorTool().execute(
                .object(["aloha_id": .string("x")]), makePageToolContext(services: services))
            _ = try await ManageTabsExecutorTool().execute(
                .object(["action": .string("close"), "tab_id": .string(fixture.tabId)]),
                makePageToolContext(services: services))
        }
        #expect(window.tabs.tab(fixture.tabId) == nil)
        #expect(tracker.takeDeferredCloses().isEmpty)
    }

    // MARK: One tracker per chat

    /// Services that keep a tracker are noted into it, whatever task the call runs in; services that
    /// keep none fall back to `current` (a bound turn's, else the process-wide one).
    @Test func servicesThatKeepATrackerAreNotedIntoIt() async throws {
        let fixture = try await makePageToolsCDPFixture()
        defer { Task { await fixture.client.close() } }
        fixture.cdp.alohaRawCallReplies = [(match: "__aloha.getText(", reply: .string("v3.8.5"))]
        let chat = ChatServices(tabsService: fixture.tabsService, session: TrackerSession())
        let plain = NativeToolServices(tabsService: fixture.tabsService)
        #expect(AnswerPageTracker.current(for: chat) === chat.answerPageTracker)
        #expect(AnswerPageTracker.current(for: plain) === AnswerPageTracker.current)
        #expect(AnswerPageTracker.current(for: nil) === AnswerPageTracker.current)
        let bound = AnswerPageTracker()
        await bound.tracking {
            #expect(AnswerPageTracker.current(for: chat) === chat.answerPageTracker)
            #expect(AnswerPageTracker.current(for: plain) === bound)
        }
        chat.answerPageTracker.beginTurn(deferringCloses: true)
        _ = try await GetTextExecutorTool().execute(
            .object(["aloha_id": .string("chat-own-read-1")]), makePageToolContext(services: chat))
        let window = try #require(fixture.tabsService.window)
        let targetId = try #require(window.tabs.tab(fixture.tabId)).id
        #expect(chat.answerPageTracker.observedTargetId == targetId)
        #expect(chat.answerPageTracker.readIds(onTarget: targetId) == ["chat-own-read-1"])
        #expect(!AnswerPageTracker.shared.readIds(onTarget: targetId).contains("chat-own-read-1"))
    }

    /// W2-review-build F1: two desktop conversations whose turns overlap. Chat A reads a tab and
    /// closes it (deferred: A's agent is told "Closed:"); chat B's turn starts and reads. With one
    /// shared tracker B's begin dropped A's deferred close -- the tab was never closed -- and A's
    /// receipts were looked for on B's page. Each chat's own tracker keeps its own.
    @Test func anOverlappingTurnOfAnotherChatKeepsThisChatsPageAndClose() async throws {
        let fixture = try await makePageToolsCDPFixture()
        defer { Task { await fixture.client.close() } }
        fixture.cdp.alohaRawCallReplies = [(match: "__aloha.getText(", reply: .string("v3.8.5"))]
        let window = try #require(fixture.tabsService.window)
        let chatA = ChatServices(tabsService: fixture.tabsService, session: TrackerSession())
        let sessionB = TrackerSession()
        let chatB = ChatServices(tabsService: fixture.tabsService, session: sessionB)

        chatA.answerPageTracker.beginTurn(deferringCloses: true)
        _ = try await GetTextExecutorTool().execute(
            .object(["aloha_id": .string("a")]), makePageToolContext(services: chatA))
        let closed = try await ManageTabsExecutorTool().execute(
            .object(["action": .string("close"), "tab_id": .string(fixture.tabId)]),
            makePageToolContext(services: chatA))
        #expect(closed.output.contains("Closed:"))
        let targetId = try #require(window.tabs.tab(fixture.tabId)).id

        // Chat B's turn starts while A's is still running, and B's agent looks at a page.
        chatB.answerPageTracker.beginTurn(deferringCloses: true)
        sessionB.active = fixture.tabId
        _ = try await GetTextExecutorTool().execute(
            .object(["aloha_id": .string("b")]), makePageToolContext(services: chatB))
        #expect(chatB.answerPageTracker.observedTargetId == targetId)
        #expect(chatB.answerPageTracker.takeDeferredCloses().isEmpty)

        // Chat A's turn ends: its page and its deferred close are still its own.
        #expect(chatA.answerPageTracker.observedTargetId == targetId)
        #expect(chatA.answerPageTracker.readIds(onTarget: targetId) == ["a"])
        #expect(chatA.answerPageTracker.isCloseDeferred(tabId: fixture.tabId))
        #expect(await chatA.answerPageTracker.closeDeferredTabs(in: window) == [fixture.tabId])
        #expect(window.tabs.tab(fixture.tabId) == nil)
    }
}
