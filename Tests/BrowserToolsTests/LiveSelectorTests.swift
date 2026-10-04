import Testing
import Foundation
import ToolABI
@testable import BrowserTools

// MARK: - A receipt's dead position path is rebuilt from the live page
//
// Agent run github-ss-r75 (2026-09-30): the search button's receipt said
// `[selector=body>div:nth-of-type(1)>div:nth-of-type(4)>…>button] [matches=0]` -- the path came from
// the snapshot the agent had read, and github.com inserted a `div` above its header after that.
// `liveSelector` rebuilds such a path from the element itself (page side, checked live on
// github.com with the shipped script: stale path 0 matches, rebuilt 1, the button).

private let stale = "body>div:nth-of-type(1)>div:nth-of-type(4)>react-partial:nth-of-type(4)>div>div>header>div>button"
private let live = "body>div:nth-of-type(1)>div:nth-of-type(5)>react-partial:nth-of-type(4)>div>div>header>div>button"

@Suite("Live selector repair")
@MainActor
struct LiveSelectorTests {

    @Test func aDeadPositionPathIsRebuiltFromTheLivePage() async {
        let backend = ReceiptProbeBackend([.number(0), .string(live)])
        let rebuilt = await AgentBrowserBridge(backend: backend).liveSelector(stale, alohaId: "b1")
        #expect(rebuilt == live)
        #expect(backend.asked == 2)
        #expect(backend.scripts[1].contains("/* receipt: live selector */"))
    }

    @Test func aPathThatStillMatchesIsKept() async {
        let backend = ReceiptProbeBackend([.number(1)])
        #expect(await AgentBrowserBridge(backend: backend).liveSelector(stale, alohaId: "b1") == stale)
        #expect(backend.asked == 1)
    }

    /// Only position paths are rebuilt: a named selector that matches nothing is reported as it
    /// is (its `[matches=0]` is the truth about it), and nothing is asked of the page.
    @Test func aNamedSelectorIsNeverRebuilt() async {
        let backend = ReceiptProbeBackend([.number(0), .string(live)])
        #expect(await AgentBrowserBridge(backend: backend).liveSelector("[data-testid=\"sort-button\"]", alohaId: "b1")
                == "[data-testid=\"sort-button\"]")
        #expect(backend.asked == 0)
        #expect(await AgentBrowserBridge(backend: backend).liveSelector(nil, alohaId: "b1") == nil)
    }

    /// The page could not rebuild it (element gone, a shadow root on the way): the original stays.
    @Test func anUnrebuildablePathStaysAsItWas() async {
        let backend = ReceiptProbeBackend([.number(0), .string("")])
        #expect(await AgentBrowserBridge(backend: backend).liveSelector(stale, alohaId: "b1") == stale)
        let silent = ReceiptProbeBackend([.number(0), nil])
        #expect(await AgentBrowserBridge(backend: silent).liveSelector(stale, alohaId: "b1") == stale)
    }
}
