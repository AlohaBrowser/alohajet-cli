import Testing
import Foundation
import ToolABI
@testable import BrowserTools

/// THE AGENT DOES THE TASK AND THEN DOES NOT STOP.
///
/// Measured on run 34091492655, t631 r0: it filled `/submit/sports`, submitted, and the receipt
/// said `Navigated to /f/sports/2/looking-for-running-shoe-recommendations-under-100`. It then
/// read that page three times, seeing it in full each time — and went back and submitted the
/// identical form twice more, producing ids 3 and 4 of the same slug. Seven of about fifteen
/// post-creating attempts in that run did this. The confirmation was never missing; nothing
/// terminates the plan.
///
/// The dangerous direction for this guard is refusing a LEGITIMATE resubmit — a form the site
/// rejected, or a second, different post. Those are pinned below alongside the refusals, because
/// a browser agent that cannot submit twice on purpose is worse than one that does it by accident.
struct DuplicateSubmitTests {

    // MARK: the key

    @Test("the same form on the same page is one key")
    func sameFormSameKey() {
        let a = submissionKey(pageURL: "http://h/submit/sports", values: "title=Shoes&&url=")
        let b = submissionKey(pageURL: "http://h/submit/sports", values: "title=Shoes&&url=")
        #expect(a == b)
    }

    /// The property that keeps a correction working: change any field and it is a new submission.
    @Test("changing any value makes it a different submission")
    func changedValueChangesKey() {
        let a = submissionKey(pageURL: "http://h/submit/sports", values: "title=Shoes&&url=")
        let b = submissionKey(pageURL: "http://h/submit/sports", values: "title=Boots&&url=")
        #expect(a != b)
    }

    @Test("the same values on a different form page are different submissions")
    func differentPageDifferentKey() {
        let a = submissionKey(pageURL: "http://h/submit/sports", values: "title=Shoes")
        let b = submissionKey(pageURL: "http://h/submit/running", values: "title=Shoes")
        #expect(a != b)
    }

    @Test("query and fragment on the form page are ignored, the path is not")
    func queryIgnored() {
        let plain = submissionKey(pageURL: "http://h/submit/sports", values: "t=1")
        let tracked = submissionKey(pageURL: "http://h/submit/sports?utm=x#top", values: "t=1")
        #expect(plain == tracked)
    }

    @Test("host and port are part of the identity")
    func originCounts() {
        #expect(submissionKey(pageURL: "http://h:1/s", values: "t=1")
                != submissionKey(pageURL: "http://h:2/s", values: "t=1"))
    }

    @Test("an unparseable page url still produces a usable, stable key")
    func garbagePageURL() {
        let a = submissionKey(pageURL: "not a url", values: "t=1")
        #expect(a == submissionKey(pageURL: "not a url", values: "t=1"))
        #expect(a != submissionKey(pageURL: "not a url", values: "t=2"))
    }

    @Test("the digest is stable and does not carry the text back")
    func digestIsStableAndOpaque() {
        #expect(stableDigest("title=Shoes") == stableDigest("title=Shoes"))
        #expect(stableDigest("title=Shoes") != stableDigest("title=Boots"))
        #expect(stableDigest("") == stableDigest(""))
        // What is retained must not be the typed text — a form can hold anything.
        #expect(!stableDigest("title=Shoes").contains("Shoes"))
    }

    // MARK: the refusal

    @Test("a form already submitted is refused, and the refusal says where it landed")
    func refusesAndPointsAtTheResult() {
        let why = duplicateSubmitRefusal(alreadyAt: "http://h/f/sports/2/looking-for-shoes")
        #expect(why != nil)
        #expect(why?.contains("http://h/f/sports/2/looking-for-shoes") == true)
        // A refusal the agent cannot act on just moves the dead end.
        #expect(why?.contains("manage_tabs read") == true)
        #expect(why?.contains("change a field") == true)
    }

    @Test("a form never submitted is not refused")
    func newFormPasses() {
        #expect(duplicateSubmitRefusal(alreadyAt: nil) == nil)
        #expect(duplicateSubmitRefusal(alreadyAt: "") == nil)
    }

    // MARK: the registry

    @Test("a recorded submission is found again by the same key")
    func recordAndFind() {
        let forms = SubmittedForms()
        forms.record("k1", landedOn: "http://h/f/s/2/post")
        #expect(forms.result(for: "k1") == "http://h/f/s/2/post")
        #expect(forms.result(for: "k2") == nil)
    }

    /// The FIRST landing is the one worth reporting: it is the copy the agent should be looking
    /// at, not a duplicate made afterwards.
    @Test("first writer wins")
    func firstWriterWins() {
        let forms = SubmittedForms()
        forms.record("k1", landedOn: "http://h/f/s/2/post")
        forms.record("k1", landedOn: "http://h/f/s/3/post")
        #expect(forms.result(for: "k1") == "http://h/f/s/2/post")
    }

    @Test("empty keys and empty urls are not recorded")
    func emptiesIgnored() {
        let forms = SubmittedForms()
        forms.record("", landedOn: "http://h/x")
        forms.record("k", landedOn: "")
        #expect(forms.result(for: "") == nil)
        #expect(forms.result(for: "k") == nil)
    }

    @Test("the registry is bounded, and forgetting the oldest is what it costs")
    func bounded() {
        let forms = SubmittedForms()
        for i in 0...300 {
            forms.record("k\(i)", landedOn: "http://h/\(i)")
        }
        // The newest survive; the oldest are gone rather than growing for the life of the process.
        #expect(forms.result(for: "k300") == "http://h/300")
        #expect(forms.result(for: "k0") == nil)
    }

    // MARK: the typed-tab gate

    /// The form read that feeds this check runs only on tabs a `page_type` touched. That is not a
    /// heuristic: a duplicate submission needs a filled form, and a filled form needs typing — so
    /// the gate cannot miss a case the check could have caught. It exists because reading the form
    /// on EVERY click timed out 25 of 99 nav-33 attempts at concurrency 16.
    @Test("a tab is only checked once something was typed into it")
    func typedGate() {
        let forms = SubmittedForms()
        #expect(forms.hasTyped("tab-1") == false)
        forms.noteTyped("tab-1")
        #expect(forms.hasTyped("tab-1") == true)
        // Other tabs stay unchecked, which is the whole saving.
        #expect(forms.hasTyped("tab-2") == false)
    }

    @Test("an empty tab id is neither recorded nor reported")
    func typedGateEmptyId() {
        let forms = SubmittedForms()
        forms.noteTyped("")
        #expect(forms.hasTyped("") == false)
    }

    @Test("reset forgets typed tabs too, or a test would leak into the next")
    func typedGateReset() {
        let forms = SubmittedForms()
        forms.noteTyped("tab-1")
        forms.reset()
        #expect(forms.hasTyped("tab-1") == false)
    }

    // MARK: the whole loop, as it happened

    @Test("t631's three submissions become one")
    func theMeasuredCase() {
        let forms = SubmittedForms()
        let page = "http://127.0.0.1:17782/submit/sports"
        let filled = "title=Looking for running shoe recommendations under $100&&url=http://example.com/placeholder"
        let key = submissionKey(pageURL: page, values: filled)

        // First submit: nothing on record, so it proceeds and lands on the new post.
        #expect(duplicateSubmitRefusal(alreadyAt: forms.result(for: key)) == nil)
        forms.record(key, landedOn: "http://127.0.0.1:17782/f/sports/2/looking-for-running-shoe-recommendations-under-100")

        // Second and third: identical form, so both are refused and both are told where id 2 is.
        for _ in 0..<2 {
            let why = duplicateSubmitRefusal(alreadyAt: forms.result(for: key))
            #expect(why != nil)
            #expect(why?.contains("/f/sports/2/") == true)
        }

        // And a genuinely different post still goes through from the same page.
        let other = submissionKey(pageURL: page, values: "title=Trail shoes under $150&&url=")
        #expect(duplicateSubmitRefusal(alreadyAt: forms.result(for: other)) == nil)
    }
}
