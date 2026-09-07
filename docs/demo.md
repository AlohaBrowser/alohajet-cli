# A real session

Every line below is captured output from one run — no edits, no reordering, no
prettifying. Reproduce it in about a minute; the page is served from disk so the
transcript does not depend on anyone else's website staying the same.

Recorded on macOS 26.2 (arm64), Swift 6.2.3, Google Chrome 152.0.7977.77, at commit
`9e168b6`, and re-run at `b43cd28`: every `aloha-id` below came back identical. Four
things are per-run and will differ for you — the tab ids, the `K="..."` fence keys, the
CDP port in the last line, and the order `alohajet tabs` lists tabs in, which comes from
the browser rather than from alohajet.

## Set the page up

```sh
mkdir -p /tmp/widgets && cd /tmp/widgets

cat > index.html <<'EOF'
<!doctype html>
<meta charset="utf-8">
<title>Widgets</title>
<h1>Widgets</h1>
<p>A catalogue of widgets, served from disk so this demo needs no network.</p>
<ul>
  <li><a href="/about.html">Learn more</a></li>
</ul>
<form action="/stock.html" method="get">
  <label>Part number <input name="q" type="text" placeholder="e.g. W-4471"></label>
  <button type="submit">Search</button>
</form>
EOF

cat > about.html <<'EOF'
<!doctype html>
<meta charset="utf-8">
<title>About widgets</title>
<h1>About widgets</h1>
<p>Widgets are round. This page exists so the demo has somewhere to click to.</p>
<a href="/">Back to the catalogue</a>
EOF

cat > stock.html <<'EOF'
<!doctype html>
<meta charset="utf-8">
<title>Stock</title>
<h1>Stock</h1>
<p id="result">Nothing searched yet.</p>
<script>
  var q = new URLSearchParams(location.search).get("q");
  if (q) document.getElementById("result").textContent = "In stock: " + q + " (14 units)";
</script>
<a href="/">Back to the catalogue</a>
EOF

python3 -m http.server 8731 --bind 127.0.0.1
```

## The session

Ten commands, each one its own process. The browser is launched by the first and
outlives every one of them until `quit`.

```console
$ alohajet open http://127.0.0.1:8731/
Opened: http://127.0.0.1:8731/
Tab ID: 86843BAC3F45676162335FF276B4946C
This tab is now the one page_click, page_type, page_select, page_navigate, page_press_keys, page_wait_for and get_text address. The page below is a snapshot taken at open; nothing refreshes it for you. After any click, type or navigation, call manage_tabs read with this tab_id to see the current page. Pass use: false on open to skip taking it.
Tab: "Widgets" (ID: "86843BAC3F45676162335FF276B4946C")
URL: http://127.0.0.1:8731/
Viewport: 756x469

Interactive view: the page rendered as structural markdown — # headings, - list items, [text](href) links, | a | b | table rows, and plain paragraphs. Content is clean and id-free; every actionable element (link, button, input, select, landmark) carries a trailing {aloha-id="ID" tag} marker. Use that id with page_click, page_type, page_select and get_text; to act on a row or a card, use the id on its own link or button trailer. The page tools address the tab currently in use — manage_tabs open and manage_tabs use both set it. Cross-origin iframe internals (payment widgets, embedded auth) cannot be inspected and carry no inner ids; do not read payment values back out.

<untrusted_page_markdown K="76FAC03A">
<interactive_page_markdown>
# Widgets
A catalogue of widgets, served from disk so this demo needs no network.
- Learn more
  [Learn more] {aloha-id="2e54000d" a}
input("e.g. W-4471") {aloha-id="1b14379e" input}
[Search] {aloha-id="6586acdd" button}
</interactive_page_markdown>
</untrusted_page_markdown K="76FAC03A">

$ alohajet read
Tab: "Widgets" (ID: "86843BAC3F45676162335FF276B4946C")
URL: http://127.0.0.1:8731/
Viewport: 756x469

Interactive view: the page rendered as structural markdown — # headings, - list items, [text](href) links, | a | b | table rows, and plain paragraphs. Content is clean and id-free; every actionable element (link, button, input, select, landmark) carries a trailing {aloha-id="ID" tag} marker. Use that id with page_click, page_type, page_select and get_text; to act on a row or a card, use the id on its own link or button trailer. The page tools address the tab currently in use — manage_tabs open and manage_tabs use both set it. Cross-origin iframe internals (payment widgets, embedded auth) cannot be inspected and carry no inner ids; do not read payment values back out.

<untrusted_page_markdown K="B8AECB05">
<interactive_page_markdown>
# Widgets
A catalogue of widgets, served from disk so this demo needs no network.
- Learn more
  [Learn more] {aloha-id="2e54000d" a}
input("e.g. W-4471") {aloha-id="1b14379e" input}
[Search] {aloha-id="6586acdd" button}
</interactive_page_markdown>
</untrusted_page_markdown K="B8AECB05">

$ alohajet click 2e54000d
Clicked element "2e54000d" (single). Navigated to http://127.0.0.1:8731/about.html.

$ alohajet read
Tab: "About widgets" (ID: "86843BAC3F45676162335FF276B4946C")
URL: http://127.0.0.1:8731/about.html
Viewport: 756x469

Interactive view: the page rendered as structural markdown — # headings, - list items, [text](href) links, | a | b | table rows, and plain paragraphs. Content is clean and id-free; every actionable element (link, button, input, select, landmark) carries a trailing {aloha-id="ID" tag} marker. Use that id with page_click, page_type, page_select and get_text; to act on a row or a card, use the id on its own link or button trailer. The page tools address the tab currently in use — manage_tabs open and manage_tabs use both set it. Cross-origin iframe internals (payment widgets, embedded auth) cannot be inspected and carry no inner ids; do not read payment values back out.

<untrusted_page_markdown K="0F1716AF">
<interactive_page_markdown>
# About widgets
Widgets are round. This page exists so the demo has somewhere to click to.
[Back to the catalogue] {aloha-id="4b2303d9" a}
</interactive_page_markdown>
</untrusted_page_markdown K="0F1716AF">

$ alohajet back
Navigated back to http://127.0.0.1:8731/

$ alohajet read
Tab: "Widgets" (ID: "86843BAC3F45676162335FF276B4946C")
URL: http://127.0.0.1:8731/
Viewport: 756x469

Interactive view: the page rendered as structural markdown — # headings, - list items, [text](href) links, | a | b | table rows, and plain paragraphs. Content is clean and id-free; every actionable element (link, button, input, select, landmark) carries a trailing {aloha-id="ID" tag} marker. Use that id with page_click, page_type, page_select and get_text; to act on a row or a card, use the id on its own link or button trailer. The page tools address the tab currently in use — manage_tabs open and manage_tabs use both set it. Cross-origin iframe internals (payment widgets, embedded auth) cannot be inspected and carry no inner ids; do not read payment values back out.

<untrusted_page_markdown K="5B648B6E">
<interactive_page_markdown>
# Widgets
A catalogue of widgets, served from disk so this demo needs no network.
- Learn more
  [Learn more] {aloha-id="2e54000d" a}
input("e.g. W-4471") {aloha-id="1b14379e" input}
[Search] {aloha-id="6586acdd" button}
</interactive_page_markdown>
</untrusted_page_markdown K="5B648B6E">

$ alohajet type 1b14379e W-4471 --submit
Typed into element "1b14379e" and pressed Enter to submit. Navigated to http://127.0.0.1:8731/stock.html?q=W-4471.
(Filling one field per call spends a round each. Pass the whole form at once: fields=[{aloha_id, text}, ...] with submit:true.)

$ alohajet read
Tab: "Stock" (ID: "86843BAC3F45676162335FF276B4946C")
URL: http://127.0.0.1:8731/stock.html?q=W-4471
Viewport: 756x469

Interactive view: the page rendered as structural markdown — # headings, - list items, [text](href) links, | a | b | table rows, and plain paragraphs. Content is clean and id-free; every actionable element (link, button, input, select, landmark) carries a trailing {aloha-id="ID" tag} marker. Use that id with page_click, page_type, page_select and get_text; to act on a row or a card, use the id on its own link or button trailer. The page tools address the tab currently in use — manage_tabs open and manage_tabs use both set it. Cross-origin iframe internals (payment widgets, embedded auth) cannot be inspected and carry no inner ids; do not read payment values back out.

<untrusted_page_markdown K="38B72A2F">
<interactive_page_markdown>
# Stock
In stock: W-4471 (14 units)
[Back to the catalogue] {aloha-id="4b2303d9" a}
</interactive_page_markdown>
</untrusted_page_markdown K="38B72A2F">

$ alohajet tabs
2 tab(s) open:

1. Stock
   ID: 86843BAC3F45676162335FF276B4946C
   URL: http://127.0.0.1:8731/stock.html?q=W-4471

2. about:blank
   ID: AD3CFFEAD59DAC7C03AFDC62489CB88B
   URL: [non-web URL hidden]

$ alohajet quit
Closed the shared browser on port 52456.

```

## What the transcript shows

`2e54000d` is printed by `open` in the first process, and it is still `2e54000d`
when a **separate** `alohajet read` process prints the page again, after a click
onto another page, and after `back` returns to it. Nothing carries a snapshot
between those processes — the id is derived from the element, so each process
arrives at the same one independently.

`4b2303d9` is the same id on `about.html` and on `stock.html`: both pages put a
link named "Back to the catalogue" in the same structural position, so both hash
to the same ref. The id identifies an element, not a URL.

Every navigation here is followed by a `read`, and that is load-bearing rather
than stylistic: the walk is what plants the `aloha-id` attributes in the new
document, so no ref resolves until it has run. Dropping the `read` after `back`
makes the next command answer `Element with aloha-id 1b14379e not found` even
though the id is right — reproduced three times out of three while recording
this. The README's
[What invalidates a ref](../README.md#what-invalidates-a-ref) states the rule and
the id-collision above; this transcript is what it looks like in practice.
