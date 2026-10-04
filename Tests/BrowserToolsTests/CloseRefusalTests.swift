import Foundation
import Testing
import ToolABI
@testable import BrowserTools

/// The agent finishes the work, closes the tab holding it, and is graded on the front page.
///
/// nav-33 is 90 of 93 `url_match`, so the last page IS the answer. Across runs 34041986201,
/// 34052929955, 34055934215 and 34083460926, attempts that closed a page deeper than the one they
/// were finally graded on passed **0 of 24**, against 23-26% for attempts that closed nothing.
/// t625 closed `/f/MachineLearning/2/the-effectiveness-of-online-learning` — the post it had just
/// been asked to create — and was graded on `/`.
///
/// The dangerous direction for this rule is refusing too much: an agent that cannot close a tab
/// it must escape is stuck for the rest of the turn. So the escapes are pinned as hard as the
/// refusals, and `escapingAnImageIsStillAllowed` is the specific one that must never break.
@Suite struct CloseRefusalTests {

    private func tab(_ id: String, _ url: String,
                     _ agent: String? = "s1", human: Bool = false) -> AgentTabSnapshot {
        AgentTabSnapshot(id: id, url: url, agentId: agent, openedByHuman: human)
    }

    // MARK: what must be refused

    @Test("the measured case: closing the post it just created")
    func theCreatedPost() {
        let tabs = [
            tab("a", "http://h/f/MachineLearning"),
            tab("b", "http://h/f/MachineLearning/2/the-effectiveness-of-online-learning"),
        ]
        let why = closeRefusal(tabs, sessionId: "s1", target: "b")
        #expect(why != nil)
        // A refusal that does not offer the alternative just moves the dead end: `back` was
        // called 3 times in the run against 30 closes.
        #expect(why?.contains("back") == true)
        #expect(why?.contains("manage_tabs use") == true)
    }

    /// The refusal describes what the tab HOLDS and what the model may close instead. It does
    /// not tell the model what it is judged on: that is the harness's business, and a model
    /// told it is scored on its final page starts optimising the page rather than the task.
    @Test("the refusal names the work and a shallower tab, and says nothing about grading")
    func theRefusalNamesTheWorkAndAnAlternative() throws {
        let tabs = [
            tab("forum", "http://h/f/MachineLearning"),
            tab("post", "http://h/f/MachineLearning/2/the-post"),
        ]
        let why = try #require(closeRefusal(tabs, sessionId: "s1", target: "post"))
        #expect(why.contains("the page the task's work is on"))
        #expect(why.contains("\"forum\""))
        #expect(why.contains("http://h/f/MachineLearning"))
        #expect(!why.lowercased().contains("judged"))
        #expect(!why.lowercased().contains("graded"))
    }

    @Test("the shallower tab it names is the shallowest one")
    func namesTheShallowestTab() {
        let tabs = [
            tab("mid", "http://h/f/books"),
            tab("root", "http://h/"),
            tab("deep", "http://h/f/books/2/post"),
        ]
        let why = closeRefusal(tabs, sessionId: "s1", target: "deep") ?? ""
        #expect(why.contains("\"root\""))
        #expect(!why.contains("\"mid\""))
    }

    @Test("the only tab is never closed — it would leave no page at all")
    func theLastTab() {
        let why = closeRefusal([tab("a", "http://h/f/books")], sessionId: "s1", target: "a")
        #expect(why != nil)
        #expect(why?.contains("only tab") == true)
        #expect(why?.contains("back") == true)
    }

    @Test("the only tab is refused even when it is the bare origin")
    func theLastTabAtRoot() {
        #expect(closeRefusal([tab("a", "http://h/")], sessionId: "s1", target: "a") != nil)
    }

    @Test("someone else's shallow tab does not license closing our deep one")
    func otherSessionsDoNotCount() {
        let tabs = [tab("mine", "http://h/f/books/2/post"), tab("theirs", "http://h/", "s2")]
        #expect(closeRefusal(tabs, sessionId: "s1", target: "mine") != nil)
    }

    // MARK: what must still close

    /// THE ESCAPE THAT MUST NEVER BREAK. Clicking a post's `a.submission__link` on Postmill lands
    /// on a raw `/submission_images/<hash>.jpg`, whose read says "This page carries no aloha-id at
    /// all" — there is nothing to click, and closing it is the way out. It is shallower than the
    /// `/f/<forum>/hot` page it came from, so the rule lets it go.
    @Test("escaping an image is still allowed")
    func escapingAnImageIsStillAllowed() {
        let tabs = [
            tab("forum", "http://h/f/space/hot"),
            tab("image", "http://h/submission_images/69fe1dc2.jpg"),
        ]
        #expect(closeRefusal(tabs, sessionId: "s1", target: "image") == nil)
    }

    @Test("a duplicate of equal depth closes — neither is more specific")
    func equalDepthCloses() {
        let tabs = [tab("a", "http://h/f/books/hot"), tab("b", "http://h/f/books/hot")]
        #expect(closeRefusal(tabs, sessionId: "s1", target: "b") == nil)
    }

    @Test("a shallower tab closes while a deeper one remains")
    func shallowerCloses() {
        let tabs = [tab("root", "http://h/"), tab("deep", "http://h/f/books/2/post")]
        #expect(closeRefusal(tabs, sessionId: "s1", target: "root") == nil)
    }

    @Test("closing is allowed when ONE remaining tab is at least as specific")
    func oneDeepEnoughSiblingIsEnough() {
        let tabs = [
            tab("a", "http://h/"),
            tab("b", "http://h/f/books/2/post"),
            tab("c", "http://h/f/books/2/post"),
        ]
        #expect(closeRefusal(tabs, sessionId: "s1", target: "c") == nil)
    }

    @Test("tabs that are not ours are not our business")
    func foreignTabsAreUntouched() {
        let tabs = [tab("x", "http://h/f/books/2/post", "s2"), tab("y", "http://h/", nil)]
        #expect(closeRefusal(tabs, sessionId: "s1", target: "x") == nil)
        #expect(closeRefusal(tabs, sessionId: "s1", target: "y") == nil)
    }

    /// The user's tab is refused earlier, by `manageTabsClose`'s own guard, with a message about
    /// whose tab it is. This rule must not shadow that with a different reason.
    @Test("the user's tab is left to the ownership check")
    func theUsersTabIsNotOurRefusal() {
        let tabs = [tab("a", "http://h/f/books/2/post", human: true), tab("b", "http://h/")]
        #expect(closeRefusal(tabs, sessionId: "s1", target: "a") == nil)
    }

    @Test("an unknown target is not refused — `tab not found` is the right error")
    func unknownTarget() {
        #expect(closeRefusal([tab("a", "http://h/")], sessionId: "s1", target: "gone") == nil)
    }

    // MARK: the specificity measure

    @Test("specificity counts path segments, and garbage counts as none")
    func specificity() {
        #expect(pageSpecificity("http://h/") == 0)
        #expect(pageSpecificity("http://h") == 0)
        #expect(pageSpecificity("http://h/f/books") == 2)
        #expect(pageSpecificity("http://h/f/books/2/post") == 4)
        // Trailing slashes must not inflate the count, or a tab would protect itself by luck.
        #expect(pageSpecificity("http://h/f/books/") == 2)
        #expect(pageSpecificity("not a url") == 0)
        #expect(pageSpecificity("") == 0)
    }

    @Test("a query string is not extra specificity, but it is not lost either")
    func querySegments() {
        // t705 closed a report whose identity was entirely in its query. Depth cannot see that,
        // so such a tab is protected only by being the deepest or the last — recorded here so
        // the limitation is not mistaken for coverage later.
        #expect(pageSpecificity("http://h/admin/reports/sales/filter/abc") == 5)
        #expect(pageSpecificity("http://h/search?q=running+shoes") == 1)
    }
}

// MARK: - Through the action, under the policy

@MainActor private func closeFixture(_ policy: TabHousekeepingPolicy)
    -> (PageToolsStubTabsModel, ManageTabsActionContext, PageToolsStubTabsWindow) {
    let forum = PageToolsStubTabHandle(id: "forum", url: "http://h/f/MachineLearning")
    forum.setAIControlledTab(false, agentId: "s1")
    let post = PageToolsStubTabHandle(id: "post", url: "http://h/f/MachineLearning/2/the-post")
    post.setAIControlledTab(false, agentId: "s1")
    let model = PageToolsStubTabsModel([forum, post])
    let ctx = ManageTabsActionContext(
        sessionId: "s1", toolCallId: "c", session: PageToolsStubSession(), abortSignal: nil,
        housekeeping: policy)
    return (model, ctx, PageToolsStubTabsWindow(model))
}

/// The rule only runs when the host asked for it. An ordinary user who says "close this tab"
/// gets the tab closed.
@Suite("close refusal through manage_tabs") @MainActor struct CloseRefusalPolicyTests {

    @Test("off by default: the deepest tab closes like any other")
    func defaultPolicyCloses() async {
        let (model, ctx, window) = closeFixture(.off)
        let result = await manageTabsClose("post", window, ctx)
        #expect(!result.isError)
        #expect(model.tab("post") == nil)
    }

    @Test("under the policy the work page is refused and the receipt names the shallower tab")
    func policyRefusesTheWorkPage() async {
        let (model, ctx, window) = closeFixture(TabHousekeepingPolicy(refuseClosingWorkPage: true))
        let result = await manageTabsClose("post", window, ctx)
        #expect(result.isError)
        #expect(result.output?.contains("the page the task's work is on") == true)
        #expect(result.output?.contains("\"forum\"") == true)
        #expect(model.tab("post") != nil)
    }

    @Test("under the policy the shallower tab still closes")
    func policyLetsTheShallowerTabGo() async {
        let (model, ctx, window) = closeFixture(TabHousekeepingPolicy(refuseClosingWorkPage: true))
        let result = await manageTabsClose("forum", window, ctx)
        #expect(!result.isError)
        #expect(model.tab("forum") == nil)
    }
}
