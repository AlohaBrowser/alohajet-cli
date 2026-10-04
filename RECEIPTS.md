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
| `:has-text(t)` | text, quoted, bare or `/re/` | elements whose text contains `t`, case-insensitive. A quoted `t` prefers the elements whose whole text equals it, then those where it is a whole word, then falls back to a whitespace-insensitive match and an attribute match (aria-label, title, alt, placeholder, value, name). Empty `t` matches nothing | 2026-07-01 |
| `:upward(n\|sel)` | a number or a CSS selector | for each element, its `n`th ancestor, or `closest(sel)` | 2026-07-01 |
| `:matches-attr(name=v)` | `name`, or `name=v` (`v` may be `/re/`) | elements that have the attribute, or whose value contains `v` | 2026-07-01 |
| `:nth-match(n)` | a positive integer | the `n`th of what the chain matched so far, in document order; nothing when there are fewer | 2026-09-23 |
| `:sub-path(/tail)` | a tail that starts with `/` | links on this origin that lead to the current path followed by exactly `/tail` (query included, hash and trailing slashes ignored). Nothing on the site root. **No longer written** in receipts since 2026-10-01, but still resolved for scenarios minted with it | 2026-09-28 |
| `:rel-href(ref)` | a relative reference: `releases`, `..`, `../issues`, `?tab=versions` | links whose target equals `ref` resolved against the current path **taken as a directory**: origin + path + query compared, hash and trailing slashes ignored, same origin only. `:sub-path("/x")` is `:rel-href("x")` | 2026-10-01 |

## Receipt brackets

A receipt follows the sentence a page tool returns, e.g.
`Clicked element "…". Navigated to … [selector=…] [tool=page_click] [matches=1] …`.
Brackets come in the order below. A value can contain spaces and brackets, so a bracket ends at
the `]` that **closes** its opening `[`, never at a space or at the next `]`.
Writer: `PageToolReceipt.selectorNote` (`Sources/BrowserTools/Tools/PageToolsSupport.swift`).

| Bracket | Holds | Since | Meaning last changed |
|---|---|---|---|
| `[selector=]` | the address to replay with: the selector ladder's pick (`Tabs/StepTraceSelector.swift`): id, data-testid, name, input type, `a[href="/path"]`, role, classes, else a position path `body>…`. **Verified on the live page before it is written** (every rung, since 2026-10-04): a selector whose live matches do not include the element is replaced by a position path rebuilt from the live element, or, when none can be built, written as it is with `[index=none]`. **One exception** follows this table | 2026-08-11 | 2026-10-04 |
| `[tool=]` | the tool that wrote the receipt: `page_click`, `page_type`, `page_select`, `page_press_keys`, `get_text` | 2026-09-30 | — |
| `[source=]` | where a non-tool line came from: `main-heading` (the heading line a page read carries) | 2026-09-30 | — |
| `[path=]` | the ladder's position path, present **only** when exception 1 moved it out of `[selector=]` | 2026-10-01 | — |
| `[matches=]` | how many elements `[selector=]` matches on the page now | 2026-09-21 | 2026-10-01 (it follows `[selector=]`) |
| `[index=]` | `i/n`: which of the `n` matches this element is, 1-based, document order. Only when `n > 1`. **`none`**: `[selector=]` matched `n` elements (`[matches=]`, possibly 0) and this element was not among them, and no live path could be rebuilt -- the address is UNVERIFIED; replay by `[list=]`, `[path=]` or `[anchor=]` instead, never by this selector | 2026-09-21 | 2026-10-04 (`none`) |
| `[text=]` | the element's own rendered text, quoted, whitespace collapsed | 2026-09-21 | — |
| `[attrs=]` | the element's real attributes as `name="value"` pairs (aria-label, href, role, name, data-*…) | 2026-09-21 | — |
| `[list=]` | `<list selector> i/n`: the repeating list the element sits in, and its place there. Only when the list has 2+ members | 2026-09-23 | — |
| `[anchor=]` | the address chosen by the anchor rule (below) and checked on the live page with the resolver | 2026-09-23 | 2026-10-01 (rule 0 is `:rel-href`) |
| `[anchor-nth=]` | `n`: the anchor is an ordinal, so replay it with `nth=n` (`:nth-match(n)`) | 2026-09-23 | — |
| `[submitted=enter]` | the type or press-keys call pressed Enter | 2026-09-22 | — |

**Exception 1 (2026-10-01): a semantic anchor beats a position path.** When the ladder fell to a
position path (`body` or `body>…`) and the anchor is not positional and has no
`[anchor-nth=]`:
- `[selector=]` is the anchor;
- `[path=]` holds the position path;
- `[matches=]` is the anchor's match count;
- `[index=]` is left out (neither `i/n` nor `none`: the anchor was verified).

`[anchor=]` is still written, and it is the same string as `[selector=]`.

**Exception 2 (2026-10-02, reads only): a read's `[selector=]` never contains what it read.**
When the ladder's selector contains the text a `get_text` read (3+ characters, any case), for
example `a[href="/…/releases/tag/v3.8.5"]` for the read `v3.8.5`:
- `[selector=]` becomes the element's `[list=]` selector, with `[matches=]` the list's size and
  `[index=]` its place;
- with no list, `[selector=]` becomes the answer-free `[anchor=]`, with `[matches=]` its count.

The old selector is dropped. No `[path=]` is added. `[anchor=]` is still written.

**Anchor rule** (`ReceiptAnchorProbe`, `Sources/BrowserTools/Runtime/ReceiptAnchor.swift`). Candidates
are tried in this order, and the first one that resolves back to the element wins:
- **0:** `tag:rel-href("ref")`, when the element is a link relative to the current page. Up to
  2026-10-01 this rule wrote `tag:sub-path("/tail")`.
- **1:** the ladder's stable selector, when it is not a position path.
- **1a:** `a[href="…"]` verbatim, for a link whose href is absolute or carries a query (rung 4b
  takes only a relative query-free path, rule 0 only a link relative to this page), when the
  value is quotable and no other link on the page leads there (since 2026-10-04).
- **1b:** `tag[aria-label="…"]` or `tag[title="…"]`, when the label has no digit (since 2026-09-30).
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

## Not in this package

Answer receipts (`[tool=answer]`, the `answer_receipts` / `answer_url` fields of the verdict) are
written by the agent (alohajet, `AnswerReceipt.swift`), not by this package, and are documented
in the agent repository's copy of this file.

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
| 2026-10-04 | this package, PR `port/08-receipt-anchor` | the anchor rule, `[anchor=]`, `[anchor-nth=]`, `[path=]` and both exceptions move into `alohajet-cli` |
