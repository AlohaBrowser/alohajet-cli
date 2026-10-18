import Testing
import Foundation
// NOT `@testable`: this file compiles only while the two names below are `public`, which is what
// the agent repository's scenario runner (alohajet `CDPWriteDispatchBackend`, `ReplayRepeatGuard`)
// links against. A plain import sees exactly what a client of the package sees.
import BrowserTools

// THE OVERLAY HIDER IS ONE COPY. The agent's scenario runner resolves a step's target by SELECTOR
// (not by aloha-id) and then calls this package's own `hideConsentLayerContaining` /
// `hideCoveringOverlay` on it, so a served scenario step aimed at a cookie prompt is skipped and
// the prompt hidden exactly the way `page_click` does it. It needs the source and the consent
// vocabulary as public constants; a private second copy in the agent would drift.
@Suite("overlay hider — public surface for the scenario runner")
struct OverlayHiderPublicSurfaceTests {

    @Test func theHiderSourceIsReachableWithoutTestableImport() {
        let src = AgentBrowserBridge.overlayHiderSource
        #expect(src.contains("function hideConsentLayerContaining(el, document, window)"))
        #expect(src.contains("function hideCoveringOverlay(el, document, window)"))
        // A wrapper must put its call on its own line: the source ends in a `//` comment.
        #expect(src.hasSuffix("// END overlay-hider js") || src.contains("// END overlay-hider js"))
    }

    @Test func theConsentVocabularyIsReachableAndCompiles() throws {
        let pattern = AgentBrowserBridge.consentActionPattern
        let re = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        for label in ["Accept all", "Only required cookies", "Reject", "×"] {
            #expect(re.firstMatch(in: label, range: NSRange(label.startIndex..., in: label)) != nil, "\(label)")
        }
        for label in ["ADD TO BAG", "Search", "Size M"] {
            #expect(re.firstMatch(in: label, range: NSRange(label.startIndex..., in: label)) == nil, "\(label)")
        }
    }
}
