import Testing
import Foundation
import ToolABI
@testable import BrowserTools

// MARK: - A receipt's selector is verified on the live page before it is written
//
// Agent run github-ss-r75 (2026-09-30): the search button's receipt said
// `[selector=body>div:nth-of-type(1)>div:nth-of-type(4)>…>button] [matches=0]` -- the path came from
// the snapshot the agent had read, and github.com inserted a `div` above its header after that.
// The 2026-10-04 audit asked that every rung be checked the same way: a class or id the framework
// swapped on re-render names a different element, or none, and a receipt must not say otherwise.
// `liveSelector` keeps a selector whose live matches include the element, rebuilds a position path
// from the element when they do not, and otherwise hands the selector back for `[index=none]`.
// The page side runs under Node in `live_selector.js`.

private let stale = "body>div:nth-of-type(1)>div:nth-of-type(4)>react-partial:nth-of-type(4)>div>div>header>div>button"
private let live = "body>div:nth-of-type(1)>div:nth-of-type(5)>react-partial:nth-of-type(4)>div>div>header>div>button"
private func reply(n: Int, has: Bool, path: String = "", pathN: Int = 0) -> JSValue {
    .string(#"{"n":\#(n),"has":\#(has),"path":"\#(path)","pathN":\#(pathN)}"#)
}

@Suite("Live selector verification")
@MainActor
struct LiveSelectorTests {

    @Test func aDeadPositionPathIsRebuiltFromTheLivePage() async {
        let backend = ReceiptProbeBackend([reply(n: 0, has: false, path: live, pathN: 1)])
        let checked = await AgentBrowserBridge(backend: backend).liveSelector(stale, alohaId: "b1")
        #expect(checked == LiveSelector(selector: live, matches: 1))
        #expect(backend.asked == 1)
        #expect(backend.scripts[0].contains("/* receipt: live selector */"))
        #expect(backend.scripts[0].contains(#""b1""#))
    }

    @Test func aSelectorThatStillNamesTheElementIsKeptWithItsCount() async {
        #expect(await AgentBrowserBridge(backend: ReceiptProbeBackend([reply(n: 1, has: true)])).liveSelector(stale, alohaId: "b1")
                == LiveSelector(selector: stale, matches: 1))
        #expect(await AgentBrowserBridge(backend: ReceiptProbeBackend([reply(n: 3, has: true)])).liveSelector("button.size", alohaId: "b1")
                == LiveSelector(selector: "button.size", matches: 3))
    }

    /// A NAMED rung is verified too: when the live page's `#q` is another element (the id moved
    /// on re-render), the receipt gets the element's live position instead.
    @Test func aNamedSelectorThatNamesAnotherElementIsRebuilt() async {
        let checked = await AgentBrowserBridge(backend: ReceiptProbeBackend([reply(n: 1, has: false, path: "body>form>input:nth-of-type(2)", pathN: 1)]))
            .liveSelector("#q", alohaId: "b1")
        #expect(checked == LiveSelector(selector: "body>form>input:nth-of-type(2)", matches: 1))
    }

    /// The page could not rebuild it (element gone, a shadow root on the way): the selector stays,
    /// with its live count, and the identity probe's missing index marks it `[index=none]`.
    @Test func anUnverifiableSelectorStaysWithItsCount() async {
        #expect(await AgentBrowserBridge(backend: ReceiptProbeBackend([reply(n: 0, has: false)])).liveSelector(stale, alohaId: "b1")
                == LiveSelector(selector: stale, matches: 0))
        #expect(await AgentBrowserBridge(backend: ReceiptProbeBackend([reply(n: 2, has: false)])).liveSelector("a.card", alohaId: "b1")
                == LiveSelector(selector: "a.card", matches: 2))
        // A selector the page cannot parse has no count.
        #expect(await AgentBrowserBridge(backend: ReceiptProbeBackend([reply(n: -1, has: false)])).liveSelector("a[", alohaId: "b1")
                == LiveSelector(selector: "a[", matches: nil))
    }

    /// A page that cannot answer, or answers nonsense, leaves the selector alone with no count;
    /// no selector means nothing to verify.
    @Test func aSilentPageLeavesTheSelectorAlone() async {
        #expect(await AgentBrowserBridge(backend: ReceiptProbeBackend([.string("")])).liveSelector(stale, alohaId: "b1")
                == LiveSelector(selector: stale, matches: nil))
        #expect(await AgentBrowserBridge(backend: ReceiptProbeBackend([nil])).liveSelector(stale, alohaId: "b1")
                == LiveSelector(selector: stale, matches: nil))
        #expect(await AgentBrowserBridge(backend: ReceiptProbeBackend(error: ReceiptProbeFailure())).liveSelector("#q", alohaId: "b1")
                == LiveSelector(selector: "#q", matches: nil))
        let untouched = ReceiptProbeBackend([reply(n: 1, has: true)])
        #expect(await AgentBrowserBridge(backend: untouched).liveSelector(nil, alohaId: "b1") == nil)
        #expect(await AgentBrowserBridge(backend: untouched).liveSelector("", alohaId: "b1") == nil)
        #expect(untouched.asked == 0)
    }

    @Test func theReplyParses() {
        #expect(LiveSelectorProbe.parse(#"{"n":2,"has":true,"path":"","pathN":0}"#)
                == .init(matches: 2, contains: true, rebuiltPath: nil, rebuiltMatches: nil))
        #expect(LiveSelectorProbe.parse(#"{"n":0,"has":false,"path":"body>a","pathN":1}"#)
                == .init(matches: 0, contains: false, rebuiltPath: "body>a", rebuiltMatches: 1))
        #expect(LiveSelectorProbe.parse(#"{"n":-1,"has":false,"path":"","pathN":0}"#)
                == .init(matches: nil, contains: false, rebuiltPath: nil, rebuiltMatches: nil))
        #expect(LiveSelectorProbe.parse("Example Domain") == nil)
        #expect(LiveSelectorProbe.parse("[1]") == nil)
    }

    /// The expression embeds the selector and the id as JSON literals (no injection through either).
    @Test func theExpressionEmbedsLiterals() {
        let expression = LiveSelectorProbe.expression(selector: "a[href*=\"x\"]", alohaId: "1g\"; alert(1); //")
        #expect(expression.contains(#""a[href*=\"x\"]""#))
        #expect(expression.contains(#""1g\"; alert(1); //""#))
        #expect(expression.contains("\(StepTraceSelector.maxPathSegments)"))
        #expect(!expression.contains("\\#("))
    }
}
