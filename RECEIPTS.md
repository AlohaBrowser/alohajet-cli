# What the client sends: receipt brackets and resolver pseudos

The one list of every bracket this package writes into a tool result and every procedural pseudo
its selector resolver understands. It is kept true by a test:
`node Tests/BrowserToolsTests/receipt_registry.js` fails when the resolver gains or loses a
pseudo, or the client writes a bracket, that this file does not list (and the other way round).

**Changing either means changing this file in the same commit**, adding a line to the change
log at the bottom, and telling llmdex in the same message.

This file was copied from the agent repository (AlohaBrowser/alohajet, branch `windows-on-snips`)
when the receipts moved into this package; the change log keeps that repository's commit hashes
for the entries made there, and this package's for the entries made here.

## Resolver pseudos

The resolver is `window.__snips.resolveAll` (`Sources/BrowserTools/Runtime/SelectorResolverScript.swift`,
`const PROC`). A selector is split into a CSS part and a chain of the pseudos below, which are
applied left to right to what the CSS part matched. **Any other `:name(` is ordinary CSS**, so
it goes to `querySelectorAll` as written. A quoted argument (`"…"` or `'…'`) is unquoted; a
`/re/flags` argument is a regex where noted.

| Pseudo | Holds | Keeps | Since |
|---|---|---|---|
| `:has-text(t)` | text, quoted, bare or `/re/` | elements whose text contains `t`, case-insensitive. A quoted `t` prefers the elements whose whole text equals it, then those where it is a whole word, then falls back to a whitespace-insensitive match and an attribute match (aria-label, title, alt, placeholder, value, name, and -- for an element with no text, since 2026-10-18 -- the alt of an image inside it). Empty `t` matches nothing | 2026-07-01 |
| `:upward(n\|sel)` | a number or a CSS selector | for each element, its `n`th ancestor, or `closest(sel)` | 2026-07-01 |
| `:matches-attr(name=v)` | `name`, or `name=v` (`v` may be `/re/`) | elements that have the attribute, or whose value contains `v` | 2026-07-01 |
| `:nth-match(n)` | a positive integer | the `n`th of what the chain matched so far, in document order; nothing when there are fewer | 2026-09-23 |
| `:sub-path(/tail)` | a tail that starts with `/` | links on this origin that lead to the current path followed by exactly `/tail` (query included, hash and trailing slashes ignored). Nothing on the site root. **No longer written** in receipts since 2026-10-01, but still resolved for scenarios minted with it | 2026-09-28 |
| `:rel-href(ref)` | a relative reference: `releases`, `..`, `../issues`, `?tab=versions` | links whose target equals `ref` resolved against the current path **taken as a directory**: origin + path + query compared, hash and trailing slashes ignored, same origin only. `:sub-path("/x")` is `:rel-href("x")` | 2026-10-01 |

## Receipt brackets

A receipt follows the sentence a page tool returns, e.g.
`Clicked element "…". Navigated to … [selector=…] [tool=page_click] [matches=1] …`.
Brackets come in the order below. A value can contain spaces and brackets, so a bracket ends at
the `]` that **closes** its opening `[`, never at a space or at the next `]`. An address
(`[selector=]`, `[anchor=]`, `[path=]`) nests brackets **at most once** and always balances them:
`[selector=a[href="/x"]]` and `[anchor=…:has-text("Add [x]")]` are written, `[name="user[email]"]`
and `[aria-label="Save [draft]"]` never are. The ladder writes a square bracket inside an attribute
value as a six-digit CSS hex escape (`[name="product\00005bqty\00005d"]` for `name="product[qty]"`,
which `querySelectorAll` and the resolver read back as the name); anchor rules 1a/1b refuse a
bracketed value; any other anchor candidate that would nest deeper or leave a bracket open is
dropped. llmdex's grammar reads one level (since 2026-10-18).
Writer: `PageToolReceipt.selectorNote` (`Sources/BrowserTools/Tools/PageToolsSupport.swift`).

| Bracket | Holds | Since | Meaning last changed |
|---|---|---|---|
| `[selector=]` | the address to replay with: the selector ladder's pick (`Tabs/StepTraceSelector.swift`): id, data-testid, name, input type, `a[href="/path"]`, role, classes, else a position path `body>…`. **Verified on the live page before it is written** (every rung, since 2026-10-04): a selector whose live matches do not include the element is replaced by a position path rebuilt from the live element, or, when none can be built, written as it is with `[index=none]`. **One exception** follows this table | 2026-08-11 | 2026-10-04 |
| `[tool=]` | the tool that wrote the receipt: `page_click`, `page_type`, `page_select`, `page_press_keys`, `get_text`; `answer` for an answer receipt (below) | 2026-09-30 | 2026-10-18 (`answer`) |
| `[source=]` | where a non-tool line came from: `main-heading` (the heading line a page read carries) | 2026-09-30 | — |
| `[path=]` | the ladder's position path, present **only** when exception 1 moved it out of `[selector=]` | 2026-10-01 | — |
| `[matches=]` | how many elements `[selector=]` matches on the page now | 2026-09-21 | 2026-10-01 (it follows `[selector=]`) |
| `[index=]` | `i/n`: which of the `n` matches this element is, 1-based, document order. Only when `n > 1`. Under exception 1 it is counted among the anchor's matches (below). **`none`**: `[selector=]` matched `n` elements (`[matches=]`, possibly 0) and this element was not among them, and no live path could be rebuilt -- the address is UNVERIFIED; replay by `[list=]`, `[path=]` or `[anchor=]` instead, never by this selector | 2026-09-21 | 2026-10-18 (kept under exception 1) |
| `[text=]` | the element's own rendered text, quoted, whitespace collapsed, at most 60 characters. With no text: its aria-label, `value` attribute or placeholder, then its title, then the alt of an image inside it. A FIELD A PERSON TYPES INTO (a text-entry `<input>`: no type, text, search, email, url, tel, password, number, a date or time type; a `<textarea>`) is never named by what it holds -- its `value` attribute or a textarea's text is typed data, a password included: only its aria-label, placeholder or title. Any other input keeps its `value` as its name (a submit's `Go`, a radio's `M`). On every receipt that names an element, batched `page_type` fields included (`ElementTextProbe`, `Runtime/ReceiptProbes.swift`) | 2026-09-21 | 2026-10-18 (batched fields; title and image-alt fallbacks; a field's content never) |
| `[attrs=]` | the element's real attributes as `name="value"` pairs (aria-label, href, role, name, data-*…) | 2026-09-21 | — |
| `[list=]` | `<list selector> i/n`: the repeating list the element sits in, and its place there. Only when the list has 2+ members | 2026-09-23 | — |
| `[anchor=]` | the address chosen by the anchor rule (below) and checked on the live page with the resolver | 2026-09-23 | 2026-10-01 (rule 0 is `:rel-href`) |
| `[anchor-nth=]` | `n`: replay the anchor with `nth=n` (`:nth-match(n)`). Written whenever `[anchor=]` matches 2+ elements: the anchor is a list ordinal (rule 3), or several elements share it (rule 0: every link that leads to the same place) and this one is the `n`th of them in the order the resolver returns them | 2026-09-23 | 2026-10-18 (whenever the anchor matches 2+, rule 0 included) |
| `[submitted=enter]` | the type or press-keys call pressed Enter | 2026-09-22 | — |

**Exception 1 (2026-10-01): a semantic anchor beats a position path.** When the ladder fell to a
position path (`body` or `body>…`) and the anchor is not positional and is not a list ordinal
(rule 3; a rule-0 anchor that several links share carries `[anchor-nth=]` since 2026-10-18 and still
qualifies):
- `[selector=]` is the anchor;
- `[path=]` holds the position path;
- `[matches=]` is the anchor's match count;
- `[index=]` is `i/n` counted among the **anchor's** matches when the anchor matches `n > 1` (a rule-0
  link that several links on the page share): `i` is this element's place in the order the resolver
  returns them, which is the `nth` a replay of `[selector=]` needs. With one match it is left out.
  Never `none`: the anchor was verified. (Until 2026-10-18 it was always left out, and a rule-0
  selector matching 2+ could not be minted: a step on it needs an `nth`, and an `nth` needs a
  reported ordinal.)

`[anchor=]` is still written, and it is the same string as `[selector=]`.

**Exception 2 (2026-10-02, reads only): a read's `[selector=]` never contains what it read.**
When the ladder's selector contains the text a `get_text` read (3+ characters, any case), for
example `a[href="/…/releases/tag/v3.8.5"]` for the read `v3.8.5`:
- `[selector=]` becomes the element's `[list=]` selector, with `[matches=]` the list's size and
  `[index=]` its place;
- with no list, `[selector=]` becomes the answer-free `[anchor=]`, with `[matches=]` its count
  and, when it matches 2+, `[index=]` the element's place among those matches (since 2026-10-18).

The old selector is dropped. No `[path=]` is added. `[anchor=]` is still written.

**Anchor rule** (`ReceiptAnchorProbe`, `Sources/BrowserTools/Runtime/ReceiptAnchor.swift`). Candidates
are tried in this order, and the first one that resolves back to the element wins:
- **0:** `tag:rel-href("ref")`, when the element is a link relative to the current page. Up to
  2026-10-01 this rule wrote `tag:sub-path("/tail")`. Every link that leads to the same place
  matches it, so it wins when the element is AMONG its matches; when there are several,
  `[anchor-nth=]` says which one (since 2026-10-18).
- **1:** the ladder's stable selector, when it is not a position path.
- **1a:** `a[href="…"]` verbatim, for a link whose href is absolute or carries a query (rung 4b
  takes only a relative query-free path, rule 0 only a link relative to this page), when the
  value is quotable (no quote, backslash, whitespace, control character or, since 2026-10-18, square
  bracket) and no other link on the page leads there (since 2026-10-04). A bare
  fragment (`#release-v3.8.5`) and a `javascript:` URL are not destinations and are never offered.
- **1b:** `tag[aria-label="…"]` or `tag[title="…"]`, when the label has no digit (since 2026-09-30)
  and no square bracket (since 2026-10-18).
- **2:** `<list>:has-text("…")`.
- **3:** `<list>` with `[anchor-nth=]`.
- **4:** `<selector>:has-text("…")`.

A label containing a digit never becomes a text anchor (since 2026-10-01). For reads, rules 2
and 4 are skipped, and so is any candidate that contains the value read. The check runs
`window.__snips.resolveAll` (`Runtime/SelectorResolverScript.swift`, installed on the page when
absent), so a reported anchor is one the replay's resolver picks.

**Live verification (2026-10-04).** The ladder's selector comes from the page snapshot the agent
last read, and a page that keeps rendering after that can move the element (github.com inserted
a `div` above its header, agent run github-ss-r75) or rename it (a re-minted id, a swapped
class). Before any receipt is written, `AgentBrowserBridge.liveSelector`
(`Sources/BrowserTools/Runtime/ReceiptProbes.swift`) asks the live page, in one round trip,
whether the selector's matches include the element:
- yes: the selector is kept, `[matches=]` is its live count;
- no, and a position path built from the live element resolves back to it: that path is the
  `[selector=]`, `[matches=]` its count;
- no, and nothing can be rebuilt (the element is gone, a shadow root is in the way): the selector
  is written as it was, `[matches=]` is its live count, and `[index=none]` marks it unverified.

The ladder itself screens a `data-testid` / `data-test` value through the same generated-id rule
as an id (`radix-3`, `_r_1d_`, `JV2FMF8` are skipped), since a numbered test hook is no more
durable than a numbered id.

## Whole-page reads

A `manage_tabs read` names no element, so it carries one more section after the Tab/URL lines,
in the same bracket form, for the page's main heading(s) -- the visible `h1`s (at most 3), else
a visible `[role=heading][aria-level="1"]`, else the first visible `h2`:

```
Main heading on this page:
- [selector=h1.d-inline.mr-3] [source=main-heading] [matches=2] [index=1/2] [text="v4.31.0"]
```

Writer: `MainHeadingProbe` (`Sources/BrowserTools/Runtime/MainHeadingReceipt.swift`).

## Answer receipts

Most fact-finding runs answer from the page an action returned, not from a `get_text`, so the run
holds no receipt for the element the answer came from. After the turn, on the page the agent
observed last (`AnswerPageTracker`: the tab of the latest page tool, by CDP target id), the host
asks `answerReceipts(onTab:answer:prompt:)` for a receipt per value the final answer repeats from
that page, and sends them with the verdict (llmdex `POST /v1/verdict`, `answer_receipts`, the
tab's URL as `answer_url`). One line per value, at most 4 (`AnswerReceipt.maxValues`; never more
than 12, `maxLines`), each line shorter than 4000 characters (`maxLineLength`, llmdex's entry cap):

```
answer "v3.8.5": [selector=body>div>main>section:nth-of-type(1)>div>h2>a] [tool=answer] [matches=1] [text="v3.8.5"] [attrs=href="/MHSanaei/3x-ui/releases/tag/v3.8.5"]
answer "You logged into a secure area! ×": [selector=#flash] [tool=answer] [matches=1] [text="You logged into a secure area! ×"] [attrs=data-alert="" id="flash"] [list=body>div>div>div 1/3] [anchor=#flash]
answer "Augusta Ada Byron 10 December 1815 London, England": [selector=td.infobox-data:has(.nickname)] [tool=answer] [matches=1] [text="…"] [list=…>table>tbody>tr>td 2/9] [anchor=td.infobox-data:has(.nickname)]
```

- **Which elements.** Every visible element whose own text is at most 80 characters and that the
  answer repeats as a whole run of words the task did not already say; innermost element only; a
  lone word only when the answer bolded or quoted it, a lone number only with 3+ characters; with
  no word match, an element whose numbers all appear in the answer. The answer's bold / quoted
  spans rank the candidates, **the earlier span first** (since 2026-10-18: the answer's lead value
  is never pushed out by names it merely lists after it); an element the turn's `get_text` read (or
  one inside it) ranks first; an element in the page's main content (`main`, `article`, role=main)
  ranks above one in its chrome (`nav`, `aside`, a page-level `header` / `footer`). **A piece of a
  value is not the value** (since 2026-10-18): when an element holds a whole bold / quoted span of
  2+ words, an element whose text is only part of that span is dropped (unless the turn read it),
  and of the elements holding the span only the innermost is kept.
- **Which spans are values.** A bold span with the colon inside it (`**Time:** 50 min`) is a label,
  and the rest of its line is the value. A bold span with the colon after it is a label only when it
  opens its line or clause and a value follows on the same line (`**Walking distance**: 3.7 km`);
  otherwise it IS the value (`attributed to **André Gide**:` followed by a line break, since
  2026-10-18).
- **Which brackets.** The `get_text` receipt of the element, built with the same writer and the
  read rules (no anchor built from the value read; exception 2 when the selector holds the value).
  `[selector=]` is, since 2026-10-18, the **selector ladder's** pick for the element (its id, test
  hook, name, input type, link path, role or stable classes, from the attributes the page matcher
  read), kept only when its live matches include the element. A ladder selector several elements
  share is narrowed to `<selector>:has(.<class>)` with the first stable class inside the element
  that makes it match exactly this element (at most three tried); otherwise it stays, and
  `[index=]` says which of its matches the element is. With no ladder rung (or one that misses the
  element) the element's live position path, as before; when it has a semantic anchor free of the
  value, exception 1 puts that in `[selector=]` and the path in `[path=]`. `[tool=answer]` says who
  wrote it. A line that would reach 4000 characters loses its `[attrs=]`; one still too long is
  not sent.
- **The prefix** `answer "<value>":` is prose: the element's text, with `"` written `'` and square
  brackets written as parentheses, so it never reads as a bracket.

Writer: `AnswerReceipt` (`Sources/BrowserTools/Runtime/AnswerReceipt.swift`); the page side is
exercised by `Tests/BrowserToolsTests/answer_receipt.js`, the whole chain on a real page by
`RealBrowserSeedPolishTests`.

## Change log

| Date | Commit | Change |
|---|---|---|
| 2026-07-01 | alohajet `23c64c3` | resolver: `:has-text`, `:upward`, `:matches-attr` |
| 2026-08-11 | alohajet `ac926e8` | `[selector=]` |
| 2026-09-14 | alohajet `f6ce70d` `1d3a15d` | the position path rung (no whitespace) |
| 2026-09-21 | alohajet `2acdf63` `5a6ca71` `0de5166` | `[matches=]`, `[index=]`, `[attrs=]`, `[text=]` |
| 2026-09-21 | alohajet `05bd08e` | a URL is never followed by punctuation |
| 2026-09-22 | alohajet `7c3a3f0` `c7ee473` | `[submitted=enter]`; `page_press_keys` names the focused element |
| 2026-09-22 | alohajet `079ea00` `7f6ecd4` | the ladder refuses generated ids and 4-char hashes, gains href and role rungs |
| 2026-09-23 | alohajet `0b1e08e` `c825a62` `70661e3` `a478463` | `[list=]`; `get_text` receipts; the main-heading line; resolver `:nth-match` |
| 2026-09-28 | alohajet `49d1d1e` | resolver `:sub-path` |
| 2026-09-30 | alohajet `e1f4c09` | hashed classes and counter ids are not stable |
| 2026-09-30 | alohajet `34160ce` | `[tool=]`, `[source=]` |
| 2026-10-01 | alohajet `80b929c` | a position path that matches nothing is rebuilt from the live element (no format change) |
| 2026-10-01 | alohajet `85bc8e3` | resolver `:rel-href` |
| 2026-10-02 | alohajet `f6c3380` | the read exception (a read's `[selector=]` is its list when the selector held the value) |
| 2026-10-04 | alohajet-cli `03d2e47` | every rung is verified on the live page before it is written; `[index=none]` marks an unverified address; a `data-testid` is screened by the generated-id rule |
| 2026-10-04 | this package, PR `port/07-receipts-and-ladder` | the brackets above, the ladder, the resolver and this file move into `alohajet-cli` |
| 2026-09-23 | alohajet `b41dda1` | `[anchor=]`, `[anchor-nth=]`; the anchor rule |
| 2026-09-28 | alohajet `49d1d1e` | anchor rule 0 writes `:sub-path`; a read never anchors on its own value |
| 2026-09-30 | alohajet `e1f4c09` | anchor rule 1b (accessible name) |
| 2026-10-01 | alohajet `c8e4388` | a label with a digit is never a text anchor |
| 2026-10-01 | alohajet `85bc8e3` | anchor rule 0 writes `:rel-href` instead of `:sub-path` |
| 2026-10-01 | alohajet `a9c4c17` | `[path=]`; exception 1 (`[selector=]` is the semantic anchor, `[matches=]` follows it, no `[index=]`) |
| 2026-10-02 | alohajet `f6c3380` | exception 2's anchor half (a read with no list is addressed by its answer-free anchor) |
| 2026-10-04 | alohajet-cli `fc182c5` | anchor rule 1a: an absolute or query-bearing href is an anchor candidate, verbatim, when it is the only link to that place |
| 2026-10-04 | this package, PR `port/08-receipt-anchor` | the anchor rule, `[anchor=]`, `[anchor-nth=]`, `[path=]` and both exceptions move into `alohajet-cli` |
| 2026-10-18 | this package, branch `e2e/snips-2026-10-17` | exception 1 keeps `[index=]`, counted among the anchor's matches; the anchor probe reports the element's place among them (re-implements agent repo `a1687b0`, 2026-10-08, which was never pushed) |
| 2026-10-18 | this package, branch `e2e/snips-2026-10-17` | `[anchor-nth=]` whenever `[anchor=]` matches 2+, rule 0 included; exception 1 excludes only the rule-3 list ordinal (re-implements agent repo `6b4a864`, 2026-10-08, which was never pushed) |
| 2026-10-18 | this package, branch `e2e/snips-2026-10-17` | `[text=]` on batched `page_type` fields; `[text=]` falls back to the title, then an inner image's alt; the resolver's `:has-text` and the anchor label read an inner image's alt the same way (re-implements agent repo `9f8db00`, 2026-10-08, which was never pushed) |
| 2026-10-18 | this package, branch `e2e/snips-2026-10-17` | an address nests brackets at most once: anchor rules 1a/1b refuse a value with `[`/`]`, and any other anchor candidate nesting deeper or unbalanced is dropped (no format change; llmdex's grammar reads one level) |
| 2026-10-18 | this package, branch `e2e/snips-2026-10-17` | the ladder writes `[`/`]` inside an attribute value as `\00005b`/`\00005d` (CSS hex escapes) instead of refusing the value, so a Magento / Rails field keeps its name rung |
| 2026-10-18 | this package, branch `e2e/snips-2026-10-17` | `[text=]` and the anchor label never read a field's content: a text-entry input's `value` attribute or a textarea's text (a submit's, a checkbox's or a radio's `value` still names it). A click on a password field whose value the page kept in the attribute wrote the password into the receipt |
| 2026-10-18 | this package, branch `e2e/snips-2026-10-17` | answer receipts (`[tool=answer]`) and the tracker of the answer page move into this package from the agent repository (windows-on-snips `dc514f76`..`a74a7d63`); the temporary ids are found by their prefix, no marker attribute |
| 2026-10-18 | this package, branch `e2e/polish-cli` | answer receipts: `[selector=]` is the selector ladder's pick (verified live; a shared one narrowed with `:has(.<class inside>)`), no longer always the position path; the answer's spans rank in their order; a bold span before a colon is a label only where a label stands; a piece of a value and an outer holder of it are dropped; main content outranks page chrome; at most 12 lines, each < 4000 characters (`[attrs=]` dropped first). No new bracket |
