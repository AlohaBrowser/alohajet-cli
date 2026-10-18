import Foundation
import Testing
import CDP
import ToolABI
@testable import BrowserTools

// A PAGE WRAPPED IN AN ELEMENT THAT LISTENS FOR CLICKS, read in a real headless Chromium.
//
// saucedemo-sort-cheapest (W4, 2026-10-18): after a replay sorted Swag Labs' inventory by price, the
// agent read the page to answer "which item is the cheapest" and saw only the "[View details for …]"
// links and the "Add to cart" buttons. React puts `onclick` on its root `<div id="root">`, the walker
// highlighted that root like a button, and every non-interactive node under a highlighted node is
// dropped (a control's label carries its text) -- so the whole inventory became the root's label,
// cut to "[Open Menu Close Menu Swag Labs Produc... [content truncated, 1230 chars hidden] ...]". No
// price ever reached the model: 0 of 3 replayed answers named "$7.99", and one run spent four more
// model rounds hunting for it. The fixture keeps the markup that mattered on the live site: the
// root's click listener, the item cards (link + name + description + price + button) and React's
// price written as two text nodes, "$" and the amount.
//
// Skipped without a browser, like `RealBrowserE2ETests`; `ALOHAJET_REQUIRE_BROWSER=1` makes a
// missing browser a failure.

private nonisolated let wrappedPageBrowserIsAvailable = ChromeLauncher().isAvailable
private nonisolated let wrappedPageBrowserIsRequired = ProcessInfo.processInfo.environment["ALOHAJET_REQUIRE_BROWSER"] == "1"

/// saucedemo's inventory sorted "Price (low to high)", as React renders it.
private let sortedInventoryHTML = """
<!doctype html>
<html><head><title>Swag Labs</title></head>
<body>
  <div id="root"><div id="page_wrapper" class="page_wrapper">
    <header class="header_container"><button id="react-burger-menu-btn">Open Menu</button><div class="app_logo">Swag Labs</div><a class="shopping_cart_link" href="#cart" aria-label="Cart, empty"></a></header>
    <div class="header_secondary_container"><span class="title" data-test="title">Products</span>
      <span class="select_container"><span class="active_option" data-test="active-option">Price (low to high)</span>
      <select class="product_sort_container" data-test="product-sort-container"><option value="az">Name (A to Z)</option><option value="za">Name (Z to A)</option><option value="lohi" selected>Price (low to high)</option><option value="hilo">Price (high to low)</option></select></span></div>
    <div id="inventory_container" class="inventory_container"><div class="inventory_list" data-test="inventory-list">
      <div class="inventory_item" data-test="inventory-item">
        <a href="#4" id="item_2_title_link" aria-label="View details for Sauce Labs Onesie"><div class="inventory_item_name" data-test="inventory-item-name">Sauce Labs Onesie</div></a>
        <div class="inventory_item_desc" data-test="inventory-item-desc">Rib snap infant onesie for the junior automation engineer in development. Reinforced 3-snap bottom closure, two-needle hemmed sleeved and bottom won't unravel.</div>
        <div class="pricebar"><div class="inventory_item_price" data-test="inventory-item-price" data-price="7.99"></div><button id="add-to-cart-sauce-labs-onesie">Add to cart</button></div>
      </div>
      <div class="inventory_item" data-test="inventory-item">
        <a href="#0" id="item_0_title_link" aria-label="View details for Sauce Labs Bike Light"><div class="inventory_item_name" data-test="inventory-item-name">Sauce Labs Bike Light</div></a>
        <div class="inventory_item_desc" data-test="inventory-item-desc">A red light isn't the desired state in testing but it sure helps when riding your bike at night. Water-resistant with 3 lighting modes, 1 AAA battery included.</div>
        <div class="pricebar"><div class="inventory_item_price" data-test="inventory-item-price" data-price="9.99"></div><button id="add-to-cart-sauce-labs-bike-light">Add to cart</button></div>
      </div>
      <div class="inventory_item" data-test="inventory-item">
        <a href="#1" id="item_1_title_link" aria-label="View details for Sauce Labs Bolt T-Shirt"><div class="inventory_item_name" data-test="inventory-item-name">Sauce Labs Bolt T-Shirt</div></a>
        <div class="inventory_item_desc" data-test="inventory-item-desc">Get your testing superhero on with the Sauce Labs bolt T-shirt. From American Apparel, 100% ringspun combed cotton, heather gray with red bolt.</div>
        <div class="pricebar"><div class="inventory_item_price" data-test="inventory-item-price" data-price="15.99"></div><button id="add-to-cart-sauce-labs-bolt-t-shirt">Add to cart</button></div>
      </div>
    </div></div>
    <div class="promo" onclick="location.hash = 'promo'"><p class="promo_text">Free shipping on every order over fifty dollars this week only, with returns accepted for thirty days, gift wrapping at no extra cost, a two-year warranty on every jacket and backpack, and a price match guarantee against every other online store that sells the same item.</p><button id="promo-yes">Tell me more</button><button id="promo-no">No thanks</button></div>
  </div></div>
  <script>
    document.getElementById('root').onclick = function () {};
    document.querySelectorAll('[data-price]').forEach(function (el) { el.append('$', el.getAttribute('data-price')); });
  </script>
</body></html>
"""

@MainActor
private func wrappedPageElementId(forLabel label: String, kind: String, in markdown: String) -> String? {
    for line in markdown.split(separator: "\n") where line.contains(label) && line.contains(" \(kind)}") {
        guard let marker = line.range(of: "{aloha-id=\"") else { continue }
        let rest = line[marker.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { continue }
        return String(rest[..<end])
    }
    return nil
}

@Suite("end to end, real browser: a page wrapped in a click listener", .serialized,
       .enabled(if: wrappedPageBrowserIsAvailable || wrappedPageBrowserIsRequired))
struct RealBrowserClickWrappedPageTests {

    /// The read after the sort shows every card's name, description and price, in the page's order,
    /// so the cheapest item AND its price are on the page the model reads.
    @Test func theSortedInventoryReadShowsEveryPrice() async throws {
        try #require(wrappedPageBrowserIsAvailable)
        let server = LocalPageServer(html: sortedInventoryHTML)
        try server.start()
        defer { server.stop() }

        try await withHeadlessBrowser { session in
            let opened = await session.run("manage_tabs", arguments: ["action": "open", "url": server.url])
            #expect(opened.isError != true, "open failed: \(opened.output)")
            let tabId = try #require(tabIdentifier(opened))
            let read = await session.run("manage_tabs", arguments: ["action": "read", "tab_id": tabId])
            #expect(read.isError != true, "read failed: \(read.output)")
            let page = read.output
            let lines = page.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }

            // The root is not one control whose label holds the page (live, before the fix:
            // "[Open Menu Close Menu Swag Labs Produc... [content truncated, 1230 chars hidden] ...]").
            #expect(!lines.contains { $0.hasPrefix("[Open Menu") && $0.contains("content truncated") },
                    "the root's label swallowed the page:\n\(page)")
            #expect(!lines.contains { $0.hasPrefix("[Open Menu Swag Labs") }, "\(page)")
            #expect(!lines.contains { $0.contains("Sauce Labs Onesie") && $0.contains("content truncated") }, "\(page)")

            // Every price is a line of its own, "$" included (React writes it as its own text node).
            for price in ["$7.99", "$9.99", "$15.99"] {
                #expect(lines.contains(price), "\(price) is not a line of the read:\n\(page)")
            }
            #expect(!lines.contains("7.99"), "the price lost its currency sign:\n\(page)")

            // Name, description and price of the first card come in the page's order.
            let name = try #require(page.range(of: "[Sauce Labs Onesie]"), "\(page)")
            let description = try #require(page.range(of: "Rib snap infant onesie for the junior automation engineer"), "\(page)")
            let price = try #require(page.range(of: "\n$7.99\n"), "\(page)")
            let nextName = try #require(page.range(of: "[Sauce Labs Bike Light]"), "\(page)")
            #expect(name.lowerBound < description.lowerBound && description.lowerBound < price.lowerBound
                    && price.lowerBound < nextName.lowerBound, "\(page)")

            // The active sort label is still read, and the controls keep their ids.
            #expect(page.contains("Price (low to high)"), "\(page)")
            #expect(wrappedPageElementId(forLabel: "[View details for Sauce Labs Onesie]", kind: "a", in: page) != nil, "\(page)")
            #expect(wrappedPageElementId(forLabel: "[Open Menu]", kind: "button", in: page) != nil, "\(page)")
            #expect(page.components(separatedBy: "[Add to cart]").count - 1 == 3, "\(page)")

            // A clickable card with two buttons and more text than a label shows keeps its own line and
            // id, and its text is read whole, as content.
            #expect(lines.contains { $0.hasPrefix("[Free shipping") && $0.hasSuffix(" div}") }, "\(page)")
            #expect(lines.contains { $0.hasPrefix("Free shipping on every order") && $0.hasSuffix("sells the same item.") }, "\(page)")
        }
    }

    /// The ids the read hands out still work: a click on the first card's button acts on that card,
    /// with the root's click listener in place.
    @Test func aCardButtonUnderTheListeningRootStillClicks() async throws {
        try #require(wrappedPageBrowserIsAvailable)
        let html = sortedInventoryHTML.replacingOccurrences(
            of: #"<button id="add-to-cart-sauce-labs-onesie">Add to cart</button>"#,
            with: #"<button id="add-to-cart-sauce-labs-onesie" onclick="this.textContent = 'Remove'">Add to cart</button>"#)
        let server = LocalPageServer(html: html)
        try server.start()
        defer { server.stop() }

        try await withHeadlessBrowser { session in
            let opened = await session.run("manage_tabs", arguments: ["action": "open", "url": server.url])
            #expect(opened.isError != true, "open failed: \(opened.output)")
            let tabId = try #require(tabIdentifier(opened))
            let read = await session.run("manage_tabs", arguments: ["action": "read", "tab_id": tabId])
            let page = read.output
            // The first "[Add to cart]" line is the Onesie's: the cards come in the page's order.
            let button = try #require(wrappedPageElementId(forLabel: "[Add to cart]", kind: "button", in: page), "\(page)")
            let clicked = await session.run("page_click", arguments: ["aloha_id": button])
            #expect(clicked.isError != true, "\(clicked.output)")
            let after = await session.run("manage_tabs", arguments: ["action": "read", "tab_id": tabId])
            #expect(after.output.contains("[Remove]"), "the click did not reach the Onesie's button:\n\(after.output)")
            #expect(after.output.components(separatedBy: "[Add to cart]").count - 1 == 2, "\(after.output)")
        }
    }
}
