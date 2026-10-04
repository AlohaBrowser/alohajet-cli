import Foundation
import Testing
import ToolABI
@testable import BrowserTools

/// At the end of a turn a final-URL grader reads `final_url` from an arbitrary CDP context, so
/// every tab still standing is another way to be scored on a page the agent abandoned.
///
/// THE KEEPER IS THE MOST SPECIFIC TAB, not the one in use. The first version kept whatever the
/// session pointer named, and that was wrong in the one case this exists for: on run
/// 34099567394, t625 r0 created exactly the right post,
/// `/f/MachineLearning/2/the-effectiveness-of-online-learning`, and was graded on
/// `/f/MachineLearning` — the collapse kept the forum and closed the post. It scored 0 of 5 while
/// producing the correct post in all five reps.
///
/// It also has to agree with `closeRefusal`, which already refuses to let the AGENT close its
/// most specific tab. A turn-end pass that closes that same tab itself is a contradiction.
@Suite struct AgentTabCollapseTests {

    private func tab(_ id: String, _ url: String,
                     _ agent: String? = "s1", human: Bool = false) -> AgentTabSnapshot {
        AgentTabSnapshot(id: id, url: url, agentId: agent, openedByHuman: human)
    }

    // MARK: the case this was rebuilt for

    /// t625: the post is deeper than the forum, and the forum is the tab in use.
    @Test("the created post is kept even when the shallow tab is in use")
    func theMeasuredCase() {
        let tabs = [
            tab("forum", "http://h/f/MachineLearning"),
            tab("post", "http://h/f/MachineLearning/2/the-effectiveness-of-online-learning"),
        ]
        #expect(collapseKeeper(tabs, sessionId: "s1", activeId: "forum") == "post")
        #expect(agentTabsToCollapse(tabs, sessionId: "s1", activeId: "forum") == ["forum"])
    }

    /// And the way the agent gets there: a fresh tab on the bare origin, opened after the work.
    @Test("a fresh origin tab does not become the keeper just by being in use")
    func freshOriginTabLoses() {
        let tabs = [
            tab("post", "http://h/f/sports/2/looking-for-shoes"),
            tab("origin", "http://h/"),
        ]
        #expect(collapseKeeper(tabs, sessionId: "s1", activeId: "origin") == "post")
        #expect(agentTabsToCollapse(tabs, sessionId: "s1", activeId: "origin") == ["origin"])
    }

    @Test("the report page, whose identity is deep in its path, is kept")
    func deepReportKept() {
        let tabs = [
            tab("dash", "http://h/admin/admin/dashboard"),
            tab("report", "http://h/admin/reports/report_sales/sales/filter/abc"),
        ]
        #expect(collapseKeeper(tabs, sessionId: "s1", activeId: "dash") == "report")
    }

    // MARK: ties and ordering

    @Test("a tie goes to the tab in use when it is among the deepest")
    func tiePrefersActive() {
        let tabs = [tab("a", "http://h/f/books/hot"), tab("b", "http://h/f/pics/hot")]
        #expect(collapseKeeper(tabs, sessionId: "s1", activeId: "a") == "a")
        #expect(collapseKeeper(tabs, sessionId: "s1", activeId: "b") == "b")
    }

    /// Window order is oldest-first, so the last tied tab is the most recent thing reached.
    @Test("a tie with no tab in use among the deepest goes to the newest")
    func tieFallsToNewest() {
        let tabs = [tab("a", "http://h/f/books/hot"),
                    tab("b", "http://h/f/pics/hot"),
                    tab("shallow", "http://h/")]
        #expect(collapseKeeper(tabs, sessionId: "s1", activeId: "shallow") == "b")
        #expect(collapseKeeper(tabs, sessionId: "s1", activeId: nil) == "b")
    }

    @Test("one tab is already the end state and nothing is closed")
    func singleTabIsANoop() {
        let tabs = [tab("a", "http://h/f/books/2/post")]
        #expect(collapseKeeper(tabs, sessionId: "s1", activeId: "a") == "a")
        #expect(agentTabsToCollapse(tabs, sessionId: "s1", activeId: "a").isEmpty)
    }

    @Test("all tabs equally shallow still leaves exactly one")
    func allShallow() {
        let tabs = [tab("a", "http://h/"), tab("b", "http://h/"), tab("c", "http://h/")]
        #expect(agentTabsToCollapse(tabs, sessionId: "s1", activeId: nil).count == 2)
        #expect(collapseKeeper(tabs, sessionId: "s1", activeId: "a") == "a")
    }

    // MARK: what must never be touched

    @Test("a tab this session does not own is never closed and never kept")
    func otherSessionsAreLeftAlone() {
        let tabs = [tab("mine", "http://h/f/books"),
                    tab("theirs", "http://h/f/books/2/deeper", "s2"),
                    tab("nobody", "http://h/f/x/3/deepest", nil)]
        // Theirs is deeper, but it is not ours to keep OR to close.
        #expect(collapseKeeper(tabs, sessionId: "s1", activeId: nil) == "mine")
        #expect(agentTabsToCollapse(tabs, sessionId: "s1", activeId: nil).isEmpty)
    }

    @Test("the user's tab is never closed, and never becomes the keeper")
    func theUsersTabIsOutOfScope() {
        let tabs = [tab("users", "http://h/f/books/2/post", human: true),
                    tab("plain", "http://h/f/books")]
        #expect(collapseKeeper(tabs, sessionId: "s1", activeId: "users") == "plain")
        #expect(agentTabsToCollapse(tabs, sessionId: "s1", activeId: "users").isEmpty)
    }

    @Test("a session that owns nothing closes nothing")
    func nothingOfOurs() {
        #expect(collapseKeeper([], sessionId: "s1", activeId: "a") == nil)
        #expect(agentTabsToCollapse([], sessionId: "s1", activeId: "a").isEmpty)
        let theirs = [tab("x", "http://h/a", "s2")]
        #expect(collapseKeeper(theirs, sessionId: "s1", activeId: "x") == nil)
        #expect(agentTabsToCollapse(theirs, sessionId: "s1", activeId: "x").isEmpty)
    }

    /// An unparseable url scores 0, so it can still be kept when it is all there is, but it never
    /// outranks a real page.
    @Test("a garbage url never outranks a real page")
    func garbageUrlLoses() {
        let tabs = [tab("junk", "not a url"), tab("real", "http://h/f/books")]
        #expect(collapseKeeper(tabs, sessionId: "s1", activeId: "junk") == "real")
        let onlyJunk = [tab("junk", "not a url")]
        #expect(collapseKeeper(onlyJunk, sessionId: "s1", activeId: nil) == "junk")
    }

    // MARK: the agreement with closeRefusal

    /// The contradiction this rebuild removes: whatever `closeRefusal` protects from the agent,
    /// the collapse must not close itself.
    @Test("the tab closeRefusal protects is the tab the collapse keeps")
    func agreesWithCloseRefusal() {
        let snaps = [tab("forum", "http://h/f/MachineLearning"),
                     tab("post", "http://h/f/MachineLearning/2/the-post")]
        #expect(closeRefusal(snaps, sessionId: "s1", target: "post") != nil)
        #expect(collapseKeeper(snaps, sessionId: "s1", activeId: "forum") == "post")
    }

    // MARK: the ranking the live probe walks

    /// The head of the ranking IS the old answer, so a caller that cannot probe is unchanged.
    @Test("the ranking's head is exactly what collapseKeeper returns")
    func headIsTheKeeper() {
        let tabs = [
            tab("forum", "http://h/f/sports"),
            tab("origin", "http://h/"),
            tab("post", "http://h/f/sports/2/running-shoes-under-100"),
        ]
        let ranked = collapseKeeperRanked(tabs, sessionId: "s1", activeId: "origin")
        #expect(ranked.first == collapseKeeper(tabs, sessionId: "s1", activeId: "origin"))
        #expect(ranked.first == "post")
    }

    /// EVERY candidate is in it, deepest first — that is what makes skipping a dead tab
    /// possible without inventing a second rule for the fallback.
    @Test("the ranking carries every candidate, deepest first")
    func rankingIsTotal() {
        let tabs = [
            tab("origin", "http://h/"),
            tab("post", "http://h/f/sports/2/running-shoes-under-100"),
            tab("forum", "http://h/f/sports"),
        ]
        #expect(collapseKeeperRanked(tabs, sessionId: "s1", activeId: nil)
                == ["post", "forum", "origin"])
    }

    @Test("ties go to the tab in use, then to the newest")
    func tieBreakIsUnchanged() {
        let tabs = [
            tab("first", "http://h/f/sports"),
            tab("second", "http://h/f/news"),
        ]
        #expect(collapseKeeperRanked(tabs, sessionId: "s1", activeId: "first").first == "first")
        #expect(collapseKeeperRanked(tabs, sessionId: "s1", activeId: nil).first == "second")
    }

    @Test("the ranking ignores the user's tabs and other sessions")
    func rankingRespectsOwnership() {
        let tabs = [
            tab("mine", "http://h/f/sports"),
            tab("theirs", "http://h/f/sports/2/deeper-than-mine", "s2"),
            tab("users", "http://h/f/sports/3/deeper-still", human: true),
        ]
        #expect(collapseKeeperRanked(tabs, sessionId: "s1", activeId: nil) == ["mine"])
    }

    // MARK: victims follow the keeper that was actually chosen

    /// THE BUG THIS SHAPE PREVENTS. When the probe passes over the deepest tab because it
    /// cannot wake, the victim list must be computed from the keeper that WAS chosen. Deriving
    /// it from the rule again put the keeper into its own kill list.
    @Test("victims exclude the chosen keeper, not the top-ranked one")
    func victimsFollowTheChoice() {
        let tabs = [
            tab("dead", "http://h/f/sports/2/running-shoes-under-100"),
            tab("live", "http://h/f/sports"),
        ]
        let victims = agentTabsToCollapse(tabs, sessionId: "s1", keeper: "live")
        #expect(victims == ["dead"])
        #expect(!victims.contains("live"))
    }

    @Test("a nil keeper closes nothing")
    func nilKeeperClosesNothing() {
        let tabs = [tab("only", "http://h/f/sports")]
        #expect(agentTabsToCollapse(tabs, sessionId: "s1", keeper: nil).isEmpty)
    }
}

// MARK: - The live collapse over a window

@MainActor private struct CollapseFixture {
    let forum: PageToolsStubTabHandle
    let post: PageToolsStubTabHandle
    let users: PageToolsStubTabHandle
    let model: PageToolsStubTabsModel
    let window: PageToolsStubTabsWindow
    let session: PageToolsStubSession

    init() {
        users = PageToolsStubTabHandle(id: "users", url: "http://h/", openedByHuman: true)
        forum = PageToolsStubTabHandle(id: "forum", url: "http://h/f/MachineLearning")
        forum.setAIControlledTab(false, agentId: "s1")
        post = PageToolsStubTabHandle(id: "post", url: "http://h/f/MachineLearning/2/the-post")
        post.setAIControlledTab(false, agentId: "s1")
        model = PageToolsStubTabsModel([users, forum, post])
        window = PageToolsStubTabsWindow(model)
        session = PageToolsStubSession()
        session.active = "forum"
    }

    var services: NativeToolServices {
        NativeToolServices(tabsService: PageToolsStubTabsService(window), session: session)
    }
}

/// `collapseAgentTabsToActive` against a window: what it closes, what it points the session at,
/// and what it does when the best tab is dead.
@Suite("turn-end collapse over a window") @MainActor struct AgentTabCollapseLiveTests {

    @Test("the post is kept, the forum closed, and the session pointed at the post")
    func collapsesToTheWorkPage() async {
        let f = CollapseFixture()
        let result = await collapseAgentTabsToActive(f.window, f.session, sessionId: "s1")

        #expect(result.keeper == "post")
        #expect(result.closed == ["forum"])
        #expect(result.mine == 2)
        #expect(f.session.active == "post")
        #expect(f.model.tab("forum") == nil)
        #expect(f.model.tab("post") != nil)
        #expect(f.session.unregistered == ["forum"])
    }

    @Test("the user's tab is never touched")
    func theUsersTabSurvives() async {
        let f = CollapseFixture()
        _ = await collapseAgentTabsToActive(f.window, f.session, sessionId: "s1")
        #expect(f.model.tab("users") != nil)
    }

    /// Measured over every archived trace with a wake failure: 14 of 16 collapses kept a tab that
    /// could not wake, and 6 of those had an alternative. The probe takes the alternative.
    @Test("a keeper that cannot wake is passed over for the next that can")
    func deadKeeperIsPassedOver() async {
        let f = CollapseFixture()
        f.post.wakeResult = WakeResult(ok: false, message: "renderer gone")

        let result = await collapseAgentTabsToActive(f.window, f.session, sessionId: "s1")

        #expect(result.keeper == "forum")
        #expect(result.closed == ["post"])
        #expect(f.session.active == "forum")
    }

    @Test("when nothing wakes the head is kept anyway — an empty window is not better")
    func nothingWakesKeepsTheHead() async {
        let f = CollapseFixture()
        f.post.wakeResult = WakeResult(ok: false)
        f.forum.wakeResult = WakeResult(ok: false)

        let result = await collapseAgentTabsToActive(f.window, f.session, sessionId: "s1")

        #expect(result.keeper == "post")
        #expect(result.closed == ["forum"])
    }

    /// ONE CANDIDATE IS NOT A CHOICE: a wake on a dead tab pays its full deadline, and 68 of 97
    /// archived collapses had a single agent tab, so the probe is skipped there.
    @Test("a single candidate is not probed")
    func singleCandidateIsNotProbed() async {
        let only = PageToolsStubTabHandle(id: "only", url: "http://h/f/books")
        only.setAIControlledTab(false, agentId: "s1")
        let model = PageToolsStubTabsModel([only])
        let session = PageToolsStubSession()

        let result = await collapseAgentTabsToActive(PageToolsStubTabsWindow(model), session, sessionId: "s1")

        #expect(result.keeper == "only")
        #expect(result.closed.isEmpty)
        #expect(only.wakeCalls == 0)
        // Nothing was closed, so the pointer is left as it was.
        #expect(session.active == nil)
    }

    @Test("a session that owns no tab reports a nil keeper and closes nothing")
    func nothingOfOursLive() async {
        let f = CollapseFixture()
        let result = await collapseAgentTabsToActive(f.window, f.session, sessionId: "someone-else")
        #expect(result.keeper == nil)
        #expect(result.mine == 0)
        #expect(result.closed.isEmpty)
        #expect(f.model.orderedTabs.count == 3)
    }

    // MARK: the policy switch

    @Test("off by default: the turn-end entry point does nothing and says so")
    func defaultPolicyDoesNotCollapse() async {
        let f = CollapseFixture()
        let result = await collapseAgentTabsAtTurnEnd(f.services, sessionId: "s1")
        #expect(result == nil)
        #expect(f.model.orderedTabs.count == 3)
        #expect(f.session.active == "forum")
    }

    @Test("under the policy the turn-end entry point collapses")
    func policyCollapses() async {
        let f = CollapseFixture()
        let services = NativeToolServices(
            tabsService: PageToolsStubTabsService(f.window), session: f.session,
            tabHousekeeping: .finalPageGraded)
        let result = await collapseAgentTabsAtTurnEnd(services, sessionId: "s1")
        #expect(result?.keeper == "post")
        #expect(result?.closed == ["forum"])
    }
}
