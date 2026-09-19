import Foundation

// MARK: - Duplicate form submission
//
// THE AGENT SUBMITS THE SAME FORM TWO OR THREE TIMES. Measured on run 34091492655, t631 r0: it
// filled `/submit/sports`, clicked submit, and the receipt said
// `Navigated to /f/sports/2/looking-for-running-shoe-recommendations-under-100`. It then read
// that page three times over, saw it in full each time -- and went back to `/submit/sports` and
// submitted the identical form twice more, producing ids 3 and 4. Seven of about fifteen
// post-creating attempts in that run did this.
//
// It is not that the confirmation was missing or hidden; it had the confirmation three times. It
// has no notion of BEING DONE. Its own history is a list of calls with no conclusions attached,
// so it re-derives the plan from the task and the plan says "post in a subreddit". Asking it to
// write down what it learned was tried and did nothing (`_inject_answer_scope`, reverted: the
// note reached 3,209 of 3,209 turns and moved the count of turns carrying text by zero).
//
// So the guard goes at the tool boundary, which is the shape that has actually held --
// `closeRefusal` eliminated self-closes 44 -> 3 the first time it ran. A click that would submit
// a form byte-identical to one this session already submitted is refused, and the refusal names
// the page the first submission created.
//
// GENERAL, not stand-shaped: submitting the same form twice is a duplicate order, a duplicate
// message, a double charge. A browser agent that cannot tell it already did something should not
// be allowed to do it again by accident.

/// A stable, non-reversible digest of what was in a form.
///
/// FNV-1a rather than `Hasher`: `String.hashValue` is seeded per process, and while this registry
/// does not outlive the process, a key that changes between runs cannot be asserted in a test.
/// Non-reversible matters too — the registry then holds no typed text, so a password or a
/// personal detail never sits in memory just because a form was submitted.
func stableDigest(_ text: String) -> String {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in text.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 0x0000_0100_0000_01B3
    }
    return String(hash, radix: 16)
}

/// What identifies one submission: the page the form is on, plus a digest of its values.
///
/// The QUERY AND FRAGMENT ARE DROPPED from the page but the path is kept, so `/submit/sports` is
/// one form whatever tracking parameters follow it. Values are digested together, so changing any
/// field — fixing a typo, correcting a title — yields a different key and submits freely. That is
/// the property that keeps this from blocking a legitimate retry after a rejected form.
func submissionKey(pageURL: String, values: String) -> String {
    let page: String
    if let parsed = URL(string: pageURL), let host = parsed.host, !host.isEmpty {
        let path = parsed.path.isEmpty ? "/" : parsed.path
        page = "\(parsed.scheme ?? "")://\(host)\(parsed.port.map { ":\($0)" } ?? "")\(path)"
    } else {
        page = pageURL
    }
    return page + "#" + stableDigest(values)
}

/// The refusal for a form this session already submitted, or nil when the click may proceed.
///
/// Says WHERE the first submission went, because a refusal the agent cannot act on just moves the
/// dead end — the same reason `closeRefusal` names `page_navigate back`.
func duplicateSubmitRefusal(alreadyAt existing: String?) -> String? {
    guard let existing, !existing.isEmpty else { return nil }
    return "Refusing to submit: you already submitted this exact form in this session, and it "
        + "created \(existing). Submitting it again would make a second copy, not a correction. "
        + "That page is the result of your work — open it with manage_tabs read if you need to "
        + "check it. To submit something DIFFERENT, change a field first; to change what you "
        + "already posted, edit it at that page."
}

/// FORMS THIS SESSION HAS ALREADY SUBMITTED, and where each landed.
///
/// Bounded and lock-guarded for the same reasons as `OpenedTabURLs`: it is reached from whatever
/// task runs a tool, and entries would otherwise accumulate for the life of the process.
/// `nonisolated` and self-guarding, like `StepTraceFirstResult`.
nonisolated final class SubmittedForms: @unchecked Sendable {
    private let lock = NSLock()
    private var landedAt: [String: String] = [:]
    private var order: [String] = []
    private var typed: Set<String> = []
    private let cap = 256

    /// Where the submission identified by `key` landed, or nil if this form is new.
    func result(for key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return landedAt[key]
    }

    /// Remember that `key` was submitted and landed on `url`. First writer wins: the URL worth
    /// reporting is the FIRST one, which is the copy the agent should be looking at, not the
    /// duplicate it made afterwards.
    func record(_ key: String, landedOn url: String) {
        guard !key.isEmpty, !url.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        if landedAt[key] != nil { return }
        landedAt[key] = url
        order.append(key)
        while order.count > cap, let oldest = order.first {
            order.removeFirst()
            landedAt.removeValue(forKey: oldest)
        }
    }

    // MARK: tabs that have been typed into

    /// A DUPLICATE SUBMISSION NEEDS A FILLED FORM, AND A FILLED FORM NEEDS TYPING. So the form
    /// read that feeds the check only has to happen on a tab something was typed into — which is
    /// a small minority of clicks, most being navigation on a listing page.
    ///
    /// Why it matters: reading the form on EVERY click added a CDP round-trip to the hottest path
    /// in the run. Alone it is cheap; at nav-33's concurrency of 16 over 99 attempts it was not.
    /// That run timed out 25 attempts (rc=124) with a median wall of 382s against 126s before,
    /// while the same build on a 25-attempt preset showed nothing — the cost is contention, not
    /// the script.
    ///
    /// Never cleared, deliberately: forgetting would need a navigation hook, and the false
    /// positives it would save are cheap (one extra read on a tab that was typed into once)
    /// while a missed clear would silently disable the guard.
    func noteTyped(_ tabId: String) {
        guard !tabId.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        typed.insert(tabId)
    }

    func hasTyped(_ tabId: String) -> Bool {
        guard !tabId.isEmpty else { return false }
        lock.lock(); defer { lock.unlock() }
        return typed.contains(tabId)
    }

    /// Test seam only: forget everything.
    func reset() {
        lock.lock(); defer { lock.unlock() }
        landedAt.removeAll()
        order.removeAll()
        typed.removeAll()
    }
}

let submittedForms = SubmittedForms()
