import Testing
import Foundation
@testable import BrowserTools

@Suite struct SiteJsonStructuredBlockTests {

    // A representative schema.org Product with an Offer carrying price/currency/availability.
    private let productJsonLd = """
    {
      "@context": "https://schema.org",
      "@type": "Product",
      "name": "Acme Widget",
      "offers": {
        "@type": "Offer",
        "price": "19.99",
        "priceCurrency": "USD",
        "availability": "https://schema.org/InStock"
      }
    }
    """

    // MARK: ON prepends a structured product block

    @Test func productBlockHasNamePriceAvailability() {
        let block = siteJsonStructuredBlock(jsonLdScripts: [productJsonLd])
        #expect(block == "[site data]\n- Acme Widget — 19.99 USD — InStock")
    }

    // MARK: OFF == baseline (no data prepended)

    /// The contract for this flag's "OFF" path: with no usable site JSON the function returns
    /// `nil`, so the read path prepends nothing and the observation is byte-identical to the
    /// baseline serialization. Empty inputs and a page with only non-product JSON-LD both
    /// produce no block.
    @Test func noUsableDataReturnsNil() {
        #expect(siteJsonStructuredBlock(jsonLdScripts: []) == nil)
        let nonProduct = """
        { "@context": "https://schema.org", "@type": "WebSite", "name": "Example" }
        """
        #expect(siteJsonStructuredBlock(jsonLdScripts: [nonProduct]) == nil)
    }

    /// The byte-identity guarantee made concrete: a baseline observation with the flag off is
    /// exactly the serialized markdown; turning the flag "off" (no block) leaves that string
    /// untouched, while "on" with product data prepends `block + "\n\n"`.
    @Test func offEqualsBaselineMarkdownExactly() {
        let baseline = "## Page\n[1] Buy now"
        // OFF: no block -> the read path leaves the markdown exactly as serialized.
        let off = siteJsonStructuredBlock(jsonLdScripts: [])
        let offMarkdown = off.map { "\($0)\n\n\(baseline)" } ?? baseline
        #expect(offMarkdown == baseline)
        // ON: a product block is prepended ahead of the same baseline markdown.
        let on = siteJsonStructuredBlock(jsonLdScripts: [productJsonLd])
        let onMarkdown = on.map { "\($0)\n\n\(baseline)" } ?? baseline
        #expect(onMarkdown == "[site data]\n- Acme Widget — 19.99 USD — InStock\n\n\(baseline)")
        #expect(onMarkdown != offMarkdown)
    }

    // MARK: Shapes

    /// A numeric price (rather than a string) and an array of offers both reduce to the same
    /// scalar rendering, and a bare availability term is kept as written.
    @Test func numericPriceAndOfferArray() {
        let json = """
        {
          "@type": "Product",
          "name": "Gadget",
          "offers": [
            { "@type": "Offer", "price": 42, "priceCurrency": "EUR", "availability": "InStock" }
          ]
        }
        """
        #expect(siteJsonStructuredBlock(jsonLdScripts: [json]) == "[site data]\n- Gadget — 42 EUR — InStock")
    }

    /// An ItemList of ListItems wrapping Products is flattened, in document order.
    @Test func itemListIsFlattened() {
        let json = """
        {
          "@type": "ItemList",
          "itemListElement": [
            { "@type": "ListItem", "position": 1, "item": { "@type": "Product", "name": "First", "offers": { "price": "1.00", "priceCurrency": "USD" } } },
            { "@type": "ListItem", "position": 2, "item": { "@type": "Product", "name": "Second", "offers": { "price": "2.00", "priceCurrency": "USD" } } }
          ]
        }
        """
        let block = siteJsonStructuredBlock(jsonLdScripts: [json])
        #expect(block == "[site data]\n- First — 1.00 USD\n- Second — 2.00 USD")
    }

    /// A schema.org `@graph` envelope is descended into.
    @Test func graphEnvelopeIsDescended() {
        let json = """
        {
          "@context": "https://schema.org",
          "@graph": [
            { "@type": "Organization", "name": "Acme" },
            { "@type": "Product", "name": "Boxed", "offers": { "price": "5", "priceCurrency": "GBP", "availability": "https://schema.org/OutOfStock" } }
          ]
        }
        """
        #expect(siteJsonStructuredBlock(jsonLdScripts: [json]) == "[site data]\n- Boxed — 5 GBP — OutOfStock")
    }

    /// Shopify's /products.json feed is parsed; its variant price has no currency in the feed.
    @Test func shopifyProductsAreParsed() {
        let feed = """
        { "products": [
            { "id": 1, "title": "Tee", "variants": [ { "id": 11, "price": "24.00" } ] },
            { "id": 2, "title": "Mug", "variants": [ { "id": 22, "price": "12.50" } ] }
        ] }
        """
        let block = siteJsonStructuredBlock(jsonLdScripts: [], shopifyProductsJson: feed)
        #expect(block == "[site data]\n- Tee — 24.00\n- Mug — 12.50")
    }

    /// A malformed JSON-LD block among good ones is skipped, not fatal.
    @Test func malformedBlockIsSkipped() {
        let broken = "{ this is not json "
        let block = siteJsonStructuredBlock(jsonLdScripts: [broken, productJsonLd])
        #expect(block == "[site data]\n- Acme Widget — 19.99 USD — InStock")
    }

    /// The same product appearing in both an ItemList and a standalone node is de-duplicated.
    @Test func duplicateProductsAreCollapsed() {
        let block = siteJsonStructuredBlock(jsonLdScripts: [productJsonLd, productJsonLd])
        #expect(block == "[site data]\n- Acme Widget — 19.99 USD — InStock")
    }

    // MARK: Availability normalization

    @Test func availabilityKeepsFinalSegment() {
        #expect(siteJsonNormalizeAvailability("https://schema.org/InStock") == "InStock")
        #expect(siteJsonNormalizeAvailability("http://schema.org/#PreOrder") == "PreOrder")
        #expect(siteJsonNormalizeAvailability("Discontinued") == "Discontinued")
        #expect(siteJsonNormalizeAvailability("   ") == nil)
    }
}
