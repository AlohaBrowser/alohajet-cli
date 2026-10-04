import Testing
import Foundation
import ToolABI
@testable import BrowserTools

// MARK: - The press-keys receipt names what the keys went into
//
// Agent run osm-route-r12 (2026-09-22): From and To typed into OpenStreetMap's directions form,
// then `page_press_keys "Enter"` as its own step. The route came back on foot and the run was
// right, but the receipt read `Keys "Enter" sent successfully` -- no element, no selector, no
// page delta -- so the mint invented a selector for the submit step and its own guard refused the
// scenario. The receipt now has the shape every other write receipt has, and `[submitted=enter]`
// when a plain Enter went into an element.

@Suite("page_press_keys receipt")
@MainActor
struct PagePressKeysReceiptTests {

    private let note = " [selector=#route_to] [tool=page_press_keys] [matches=2] [index=2/2] [attrs=type=\"text\" name=\"route_to\" id=\"route_to\"]"

    /// THE OSM SHAPE: Enter in a focused field, and the page moved.
    @Test func enterInAFieldThatSubmitted() {
        let out = PagePressKeysExecutorTool.receipt(
            keys: "Enter", focusedAlohaId: "2766-66bf57a8-2",
            urlBefore: "https://www.openstreetmap.org/directions#map=8/42.334/43.369",
            urlAfter: "https://www.openstreetmap.org/directions?engine=fossgis_osrm_foot&route=48.85%2C2.29%3B48.86%2C2.33",
            selectorNote: note)
        #expect(out.hasPrefix("Pressed \"Enter\" in element \"2766-66bf57a8-2\"."))
        #expect(out.contains(" Navigated to https://www.openstreetmap.org/directions?engine=fossgis_osrm_foot"))
        #expect(out.contains("[selector=#route_to] [tool=page_press_keys] [matches=2] [index=2/2]"))
        #expect(out.hasSuffix(PageToolReceipt.submittedNote))
        // The URL is never followed by punctuation (a mint copies it verbatim).
        #expect(!out.contains("48.86%2C2.33."))
    }

    /// Enter that did not move the page still says where it went and that it submitted.
    @Test func enterThatStayedOnThePage() {
        let out = PagePressKeysExecutorTool.receipt(
            keys: "Enter", focusedAlohaId: "1a", urlBefore: "https://h/search", urlAfter: "https://h/search", selectorNote: " [selector=[name=\"q\"]] [matches=1]")
        #expect(out.contains("The URL is still https://h/search"))
        #expect(out.contains("[selector=[name=\"q\"]]"))
        #expect(out.hasSuffix(PageToolReceipt.submittedNote))
    }

    /// Nothing focused: the receipt says so, carries no selector and no submit token -- the
    /// key press was not aimed at an element, so there is nothing for a mint to build a step from.
    @Test func nothingHadFocus() {
        let out = PagePressKeysExecutorTool.receipt(
            keys: "Escape", focusedAlohaId: nil, urlBefore: "https://h/", urlAfter: "https://h/", selectorNote: " [selector=body]")
        #expect(out.hasPrefix("Pressed \"Escape\" (nothing on the page had focus)."))
        #expect(!out.contains("[selector="))
        #expect(!out.contains("[submitted="))
    }

    /// Other keys into a focused element name the element but never claim a submit.
    @Test func otherKeysNameTheElementWithoutASubmitToken() {
        for keys in ["Escape", "Tab", "Control+a", "Shift+Enter", "ArrowDown"] {
            let out = PagePressKeysExecutorTool.receipt(keys: keys, focusedAlohaId: "1a", urlBefore: "https://h/", urlAfter: "https://h/", selectorNote: note)
            #expect(out.contains("in element \"1a\""), Comment(rawValue: keys))
            #expect(out.contains("[selector=#route_to]"), Comment(rawValue: keys))
            #expect(!out.contains("[submitted="), Comment(rawValue: keys))
        }
    }

    @Test func onlyAPlainTrailingEnterSubmits() {
        for keys in ["Enter", "enter", "Return", "ArrowDown Enter", "ArrowDown,Enter"] {
            #expect(PagePressKeysExecutorTool.submitsForm(keys), Comment(rawValue: keys))
        }
        for keys in ["Shift+Enter", "Control+Enter", "Enter Escape", "Escape", "Tab", "", "  "] {
            #expect(!PagePressKeysExecutorTool.submitsForm(keys), Comment(rawValue: keys))
        }
    }

    /// Through the mock browser nothing has focus, so the receipt says so and still carries the
    /// key and the page delta -- never the old `Keys "Enter" sent successfully`.
    @Test func throughTheMockBrowserTheReceiptHasTheNewShape() async throws {
        let fixture = try await makePageToolsCDPFixture()
        let services = NativeToolServices(tabsService: fixture.tabsService)
        let result = try await PagePressKeysExecutorTool().execute(.object(["keys": .string("Enter")]), makePageToolContext(services: services))
        await fixture.client.close()
        #expect(result.isError != true)
        #expect(result.output.hasPrefix("Pressed \"Enter\" (nothing on the page had focus)."), "\(result.output)")
        #expect(!result.output.contains("[submitted="))
        #expect(!result.output.contains("sent successfully"))
    }
}
