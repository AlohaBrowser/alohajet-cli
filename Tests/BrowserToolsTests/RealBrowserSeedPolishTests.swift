import Foundation
import Testing
import CDP
import ToolABI
@testable import BrowserTools

// THE FOUR PAGE SHAPES THE 2026-10-18 SEEDING RUN TRIPPED ON, in a real headless Chromium: the
// answer receipts' selectors (the-internet's `#flash`, Wikipedia's infobox cell, quotes.toscrape's
// author list), a click whose result appears elsewhere on the page (demoqa's text box), and a page
// wrapped in an element that listens for clicks (React's root on saucedemo.com). Each fixture keeps
// the markup that mattered on the live site; `$E2E/reports/W5-cli-polish.md` has the before/after
// of the live pages themselves.
//
// Skipped without a browser, like `RealBrowserE2ETests`; `ALOHAJET_REQUIRE_BROWSER=1` makes a
// missing browser a failure.

private nonisolated let seedBrowserIsAvailable = ChromeLauncher().isAvailable
private nonisolated let seedBrowserIsRequired = ProcessInfo.processInfo.environment["ALOHAJET_REQUIRE_BROWSER"] == "1"

/// The answers' page: the-internet's flash, a Wikipedia infobox with a reference whose access date
/// repeats part of the birth date, and a quotes list whose first author the answer names first.
private let answerPageHTML = """
<!doctype html>
<html><head><title>Answer Fixture</title></head>
<body>
  <div class="row"><div id="flash" class="flash success" data-alert="">You logged into a secure area! <a class="close" href="#">×</a></div></div>
  <main>
    <table class="infobox biography vcard"><tbody>
      <tr><th scope="row" class="infobox-label">Born</th><td class="infobox-data"><div style="display:inline" class="nickname">Augusta Ada Byron</div><br><span style="display:none">(<span class="bday">1815-12-10</span>)</span>10 December 1815<br><div style="display:inline" class="birthplace">London, England</div></td></tr>
      <tr><th scope="row" class="infobox-label">Died</th><td class="infobox-data">27 November 1852</td></tr>
      <tr><th scope="row" class="infobox-label">Known for</th><td class="infobox-data">Mathematics, computing</td></tr>
    </tbody></table>
    <ol class="references"><li><cite>"Ada Lovelace". Retrieved <span id="mwCTM">10 December</span> 2020.</cite></li></ol>
    <div class="col-md-8">
      <div class="quote"><span class="text">“It is better to be hated for what you are than to be loved for what you are not.”</span>
        <span>by <small class="author" itemprop="author">André Gide</small> <a href="/author/Andre-Gide">(about)</a></span></div>
      <div class="quote"><span class="text">“This life is what you make it. No matter what, you're going to mess up sometimes.”</span>
        <span>by <small class="author" itemprop="author">Marilyn Monroe</small> <a href="/author/Marilyn-Monroe">(about)</a></span></div>
      <div class="quote"><span class="text">“You may not be her first, her last, or her only. She loved before she may love again.”</span>
        <span>by <small class="author" itemprop="author">Bob Marley</small> <a href="/author/Bob-Marley">(about)</a></span></div>
      <div class="quote"><span class="text">“The opposite of love is not hate, it's indifference.”</span>
        <span>by <small class="author" itemprop="author">Friedrich Nietzsche</small> <a href="/author/Friedrich-Nietzsche">(about)</a></span></div>
      <div class="quote"><span class="text">“Love never dies a natural death. It dies because we don't know how to replenish its source.”</span>
        <span>by <small class="author" itemprop="author">Pablo Neruda</small> <a href="/author/Pablo-Neruda">(about)</a></span></div>
    </div>
  </main>
</body></html>
"""

/// demoqa's text box: Submit writes the submission into `#output` below the form; a second button
/// rewrites text that is already there; a third does nothing at all.
private let clickEffectHTML = """
<!doctype html>
<html><head><title>Click Effect Fixture</title></head>
<body>
  <h1>Text Box</h1>
  <form id="userForm" onsubmit="return false">
    <input id="userName" aria-label="Full Name" value="Jane Doe">
    <button type="button" id="submit" onclick="var o = document.getElementById('output'); var p = document.createElement('p'); p.id = 'name'; p.textContent = 'Name:Jane Doe'; o.appendChild(p);">Submit</button>
  </form>
  <div id="output"></div>
  <p>Status: <span id="status">idle</span></p>
  <button type="button" id="rename" onclick="document.getElementById('status').firstChild.nodeValue = 'renamed-OK'">Rename</button>
  <button type="button" id="inert">Does nothing</button>
</body></html>
"""

/// saucedemo's inventory, as React renders it: the whole app inside `<div id="root">`, which React
/// gives an `onclick`; each price written as two text nodes, `$` and the amount.
private let reactRootHTML = """
<!doctype html>
<html><head><title>Swag Labs</title></head>
<body>
  <div id="root"><div id="page_wrapper" class="page_wrapper">
    <header class="header_container"><button id="react-burger-menu-btn">Open Menu</button><div class="app_logo">Swag Labs</div><span class="title">Products</span></header>
    <div id="inventory_container" role="main"><div class="inventory_list">
      <div class="inventory_item">
        <a href="#" id="item_2_title_link" aria-label="View details for Sauce Labs Onesie"><div class="inventory_item_name" data-test="inventory-item-name">Sauce Labs Onesie</div></a>
        <div class="inventory_item_desc">Rib snap infant onesie for the junior automation engineer in development. Reinforced 3-snap bottom closure, two-needle hemmed sleeved and bottom won't unravel.</div>
        <div class="pricebar"><div class="inventory_item_price" data-test="inventory-item-price" data-price="7.99"></div><button id="add-to-cart-sauce-labs-onesie">Add to cart</button></div>
      </div>
      <div class="inventory_item">
        <a href="#" id="item_0_title_link" aria-label="View details for Sauce Labs Bike Light"><div class="inventory_item_name" data-test="inventory-item-name">Sauce Labs Bike Light</div></a>
        <div class="inventory_item_desc">A red light isn't the desired state in testing but it sure helps when riding your bike at night.</div>
        <div class="pricebar"><div class="inventory_item_price" data-test="inventory-item-price" data-price="9.99"></div><button id="add-to-cart-sauce-labs-bike-light">Add to cart</button></div>
      </div>
      <div class="inventory_item">
        <a href="#" id="item_4_title_link" aria-label="View details for Sauce Labs Backpack"><div class="inventory_item_name" data-test="inventory-item-name">Sauce Labs Backpack</div></a>
        <div class="inventory_item_desc">carry.allTheThings() with the sleek, streamlined Sly Pack that melds uncompromising style with unequaled laptop and tablet protection.</div>
        <div class="pricebar"><div class="inventory_item_price" data-test="inventory-item-price" data-price="29.99"></div><button id="add-to-cart-sauce-labs-backpack">Add to cart</button></div>
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
private func elementId(forLabel label: String, kind: String, in markdown: String) -> String? {
    for line in markdown.split(separator: "\n") where line.contains(label) && line.contains(" \(kind)}") {
        guard let marker = line.range(of: "{aloha-id=\"") else { continue }
        let rest = line[marker.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { continue }
        return String(rest[..<end])
    }
    return nil
}

@Suite("end to end, real browser: the seeding run's pages", .serialized, .enabled(if: seedBrowserIsAvailable || seedBrowserIsRequired))
struct RealBrowserSeedPolishTests {

    /// Answer receipts address the element by the ladder (an id, a class), narrow a shared class
    /// with one inside the element, keep the answer's lead value, and send no piece of a value.
    @Test func answerReceiptsNameTheElementByWhatItIs() async throws {
        try #require(seedBrowserIsAvailable)
        let server = LocalPageServer(html: answerPageHTML)
        try server.start()
        defer { server.stop() }

        try await withHeadlessBrowser { session in
            let opened = await session.run("manage_tabs", arguments: ["action": "open", "url": server.url])
            #expect(opened.isError != true, "open failed: \(opened.output)")
            let tabId = try #require(tabIdentifier(opened))
            let tab = try #require(session.tabs?.tab(tabId) as? CDPTabHandle)
            let tracker = AnswerPageTracker()

            // heroku-login-secure-area: the flash, by its id.
            let flash = await answerReceipts(
                onTab: tab, answer: #"Logged in successfully as **tomsmith**. The page message was: **"You logged into a secure area!"**"#,
                prompt: "Log in on this page as tomsmith using the demo credentials it shows, and tell me the message you get.",
                tracker: tracker).map(\.text)
            #expect(flash.first?.hasPrefix(#"answer "You logged into a secure area! ×": [selector=#flash] [tool=answer] [matches=1]"#) == true,
                    "\(flash)")

            // wiki-ada-lovelace-birthdate: ONE receipt, the Born cell, narrowed by a class inside it;
            // neither its row nor the reference's "10 December".
            let born = await answerReceipts(
                onTab: tab, answer: "Ada Lovelace was born on **10 December 1815**. I've opened the [Wikipedia article](https://en.wikipedia.org/wiki/Ada_Lovelace).",
                prompt: "Open the Wikipedia article on Ada Lovelace and tell me her date of birth.", tracker: tracker).map(\.text)
            #expect(born.count == 1, "\(born)")
            #expect(born.first?.contains("[selector=td.infobox-data:has(.nickname)] [tool=answer] [matches=1]") == true, "\(born)")
            #expect(!born.contains { $0.hasPrefix(#"answer "10 December""#) }, "\(born)")

            // quotes-love-first-author: the lead value first, by its class and its place among the authors.
            let quotes = await answerReceipts(
                onTab: tab, answer: """
                The first quote is attributed to **André Gide**:

                > “It is better to be hated for what you are than to be loved for what you are not.”

                The rest are attributed, in order, to **Marilyn Monroe, Bob Marley, Friedrich Nietzsche,** and **Pablo Neruda**.
                """,
                prompt: "Show the quotes tagged love and tell me who wrote the first one.", tracker: tracker).map(\.text)
            #expect(quotes.first?.hasPrefix(#"answer "André Gide": [selector=small.author] [tool=answer] [matches=5] [index=1/5]"#) == true,
                    "\(quotes)")
            #expect(!quotes.contains { $0.hasPrefix(#"answer "by "#) }, "\(quotes)")
            #expect(quotes.count <= AnswerReceipt.maxLines && quotes.allSatisfy { $0.unicodeScalars.count < AnswerReceipt.maxLineLength })
            // The temporary ids are gone again.
            let read = await session.run("manage_tabs", arguments: ["action": "read", "tab_id": tabId])
            #expect(!read.output.contains("aloha-answer-"))
        }
    }

    /// demoqa-text-box-submit: a Submit whose result appears below the form is not a no-op; neither is
    /// a click that rewrites text already on the page; a click that changes nothing still says so.
    @Test func aClickThatChangesThePageIsNotANoOp() async throws {
        try #require(seedBrowserIsAvailable)
        let server = LocalPageServer(html: clickEffectHTML)
        try server.start()
        defer { server.stop() }

        try await withHeadlessBrowser { session in
            let opened = await session.run("manage_tabs", arguments: ["action": "open", "url": server.url])
            #expect(opened.isError != true, "open failed: \(opened.output)")
            let submit = try #require(elementId(forLabel: "[Submit]", kind: "button", in: opened.output), "\(opened.output)")
            let rename = try #require(elementId(forLabel: "[Rename]", kind: "button", in: opened.output), "\(opened.output)")
            let inert = try #require(elementId(forLabel: "[Does nothing]", kind: "button", in: opened.output), "\(opened.output)")

            let submitted = await session.run("page_click", arguments: ["aloha_id": submit])
            #expect(submitted.isError != true, "\(submitted.output)")
            #expect(!submitted.output.contains("NOTHING observable"), "\(submitted.output)")
            #expect(submitted.output.contains(#"new text is showing -- "Name:Jane Doe""#), "\(submitted.output)")

            // Text rewritten in place moves no fingerprint: the page is still sent back.
            let renamed = await session.run("page_click", arguments: ["aloha_id": rename])
            #expect(!renamed.output.contains("NOTHING observable"), "\(renamed.output)")
            #expect(renamed.output.contains(#"new text is showing -- "renamed-OK""#), "\(renamed.output)")
            let sentBack = renamed.output.components(separatedBy: "<interactive_page_markdown>").dropFirst().joined()
            #expect(sentBack.contains("renamed-OK"), "the rewritten page was not sent back:\n\(renamed.output)")

            let idle = await session.run("page_click", arguments: ["aloha_id": inert])
            #expect(idle.output.contains("That click did NOTHING observable"), "\(idle.output)")
            #expect(!idle.output.contains("new text is showing"), "\(idle.output)")
        }
    }

    /// saucedemo-sort-cheapest: React's root listens for clicks, and was read as ONE control whose
    /// label held the whole page -- the products' prices and descriptions never reached the read.
    @Test func aPageWrappedInAClickListenerReadsItsContent() async throws {
        try #require(seedBrowserIsAvailable)
        let server = LocalPageServer(html: reactRootHTML)
        try server.start()
        defer { server.stop() }

        try await withHeadlessBrowser { session in
            let opened = await session.run("manage_tabs", arguments: ["action": "open", "url": server.url])
            #expect(opened.isError != true, "open failed: \(opened.output)")
            let tabId = try #require(tabIdentifier(opened))
            let read = await session.run("manage_tabs", arguments: ["action": "read", "tab_id": tabId])
            let page = read.output
            let lines = page.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            // No line is the root's label holding the whole page ("[Open Menu Swag Labs Produc...").
            #expect(!lines.contains { $0.hasPrefix("[Open Menu Swag Labs") }, "the root's label swallowed the page:\n\(page)")
            for price in ["$7.99", "$9.99", "$29.99"] {
                #expect(lines.contains(price),
                        "\(price) is not a line of the read:\n\(page)")
            }
            #expect(page.contains("Rib snap infant onesie for the junior automation engineer"), "\(page)")
            // The controls are all still there, with their ids.
            #expect(elementId(forLabel: "[View details for Sauce Labs Onesie]", kind: "a", in: page) != nil, "\(page)")
            #expect(page.components(separatedBy: "[Add to cart]").count - 1 == 3, "\(page)")
            // A clickable card with two buttons and more text than its label shows keeps its own line
            // and id, and its text is read whole, as content.
            #expect(lines.contains { $0.hasPrefix("[Free shipping") && $0.hasSuffix(" div}") }, "\(page)")
            #expect(lines.contains { $0.hasPrefix("Free shipping on every order") && $0.hasSuffix("sells the same item.") }, "\(page)")
        }
    }
}
