# alohajet

**A zero-dependency Swift package that drives a real Chromium over the Chrome DevTools
Protocol and hands eight page tools to an LLM — as a command-line tool and as an MCP
stdio server.**

alohajet is not a browser. It does not render, it does not fetch, it has no engine of its
own. It attaches to a Chromium that already exists — one it launched, or one you were
already using — and gives a model the smallest set of verbs that can actually finish a
task on a web page: read the page, click, type, select, read text back, navigate, press
keys, wait.

The thing that makes it worth choosing is [stable element refs](#stable-element-refs).
A `read` prints `[Learn more] {aloha-id="719a97a0" a}`, and `719a97a0` is not a handle
minted for that snapshot — it is derived from the page. Read the same page tomorrow, from
a different process, against a different browser, and it is still `719a97a0`.

---

## What it is not

- **Not a browser.** It needs Google Chrome or Chromium installed.
- **Not a sandbox and not a security boundary.** It does what a person at that browser
  could do. Read [SECURITY.md](SECURITY.md) before pointing it at a browser you are
  logged into.
- **Not a test framework.** No assertions, no fixtures, no retry semantics. Use
  Playwright for tests.
- **Not a scraper.** There is no HTTP client, no extraction service, no readability
  backend. `manage_tabs read` serializes the DOM of a page the browser already rendered.
- **Not a general CDP console.** Eight tools, deliberately. There is no `evaluate_script`
  and no coordinate clicking — see [Limitations](#limitations-honestly).

## Requirements

| | |
|---|---|
| Swift | 6.2 or newer |
| OS | macOS 14+ — that is what every command on this page was run on. The sources target Linux too (`Sources/CDP/LinuxWebSocketChannel.swift` is the raw-POSIX WebSocket transport Foundation lacks off Apple), but **no Linux build or run is verified here** and there is no CI. Windows is not supported. |
| Browser | Google Chrome or Chromium on the machine. `--cdp` also accepts any CDP endpoint. |
| Dependencies | none. Foundation only. |

## Install

```sh
git clone https://github.com/AlohaBrowser/alohajet-cli.git
cd alohajet
swift build -c release
mkdir -p ~/.local/bin
install -m 755 .build/release/alohajet ~/.local/bin/alohajet   # or anywhere on PATH
```

As a library, add it to your `Package.swift`:

```swift
.package(url: "https://github.com/AlohaBrowser/alohajet-cli.git", branch: "main")
```

and depend on the `BrowserTools` product. There are no tagged releases yet.

## Quickstart

```sh
alohajet open https://example.com   # opens a tab, prints the page with refs
alohajet click 719a97a0             # the ref printed next to [Learn more]
alohajet read                       # the page it landed on
alohajet back
alohajet tabs
alohajet quit                       # the ONLY thing that closes the browser
```

That first command prints, among the page markdown:

```
Opened: https://example.com
Tab ID: D5940F3D894EBFA6032525D62B193519
...
<interactive_page_markdown>
# Example Domain
This domain is for use in documentation examples without needing permission. Avoid use in operations.
[Learn more] {aloha-id="719a97a0" a}
</interactive_page_markdown>
```

Every command is its own process, and the browser outlives all of them on purpose: refs
printed by one command have to still work in the next. `alohajet quit` ends it and deletes
the throwaway profile.

Full command list: `alohajet --help`, or `alohajet <command> --help` for one of them.

| command | tool it calls |
|---|---|
| `open <url>` | `manage_tabs` open |
| `read [--tab <id>]` | `manage_tabs` read |
| `tabs` | `manage_tabs` list |
| `close <id>` | `manage_tabs` close |
| `click <ref> [--double\|--right]` | `page_click` |
| `type <ref> <text> [--submit] [--no-replace]` | `page_type` |
| `select <ref> --text <t>\|--index <n>` | `page_select` |
| `text <ref>[,<ref>...] [--max-chars <n>]` | `get_text` |
| `goto <url>` / `back` | `page_navigate` |
| `keys <chord>` | `page_press_keys` |
| `wait <css> [--timeout-ms <n>]` | `page_wait_for` |
| `quit` | — closes the shared browser |
| `mcp` | — serves all eight over stdio |

`--json` on any command prints the raw tool result instead of prose. Exit codes: `0` ok,
`1` tool error, `2` usage, `3` browser unreachable.

## MCP server

`alohajet mcp` speaks Model Context Protocol over stdio: newline-delimited JSON-RPC 2.0 on
stdin/stdout, protocol versions `2024-11-05`, `2025-03-26` and `2025-06-18`. Nothing but
protocol traffic goes to stdout; diagnostics go to stderr. No browser is launched until the
first `tools/call`, so a host that only lists tools pays nothing.

```json
{
  "mcpServers": {
    "alohajet": {
      "command": "/Users/you/.local/bin/alohajet",
      "args": ["mcp"]
    }
  }
}
```

To drive a browser you already have open instead of a fresh headless one, add the
connection flag:

```json
{
  "mcpServers": {
    "alohajet": {
      "command": "/Users/you/.local/bin/alohajet",
      "args": ["mcp", "--cdp", "9222"]
    }
  }
}
```

Read [SECURITY.md](SECURITY.md) first — that second config hands the agent every tab and
every logged-in session in that browser.

Each tool carries MCP annotations (`readOnlyHint`, `destructiveHint`, `openWorldHint`);
`get_text` and `page_wait_for` are the two read-only ones. `manage_tabs` with
`include_screenshot: true` returns a second content block of type `image` next to the
text; the CLI has no equivalent and drops the pixels.

## Stable element refs

**This is the reason to use this tool rather than a coordinate-based one.**

Every actionable element in a `read` carries a ref:

```
input("query") {aloha-id="1d62a" input}
select "alpha" [options: [1d62c.0] *alpha, [1d62c.1] beta] {aloha-id="1d62c" select}
[Go] {aloha-id="38ee4f" button}
```

### How a ref is derived

There is exactly one place a ref comes from — `alohaIdFor` in
`Sources/BrowserTools/Runtime/DomTreeScript.swift`. It hashes a string built from two
parts:

1. **The scope.** Which document the element lives in: the chain of iframe selectors and
   shadow-root indices down to it. Without it, an iframe's children and the top document's
   children collide, because both are walked with the same root path.
2. **The identity.** The first of these that answers:
   - an **authored name** the page's own developers wrote — `#id`, or
     `[data-testid]` / `[data-test]`;
   - otherwise the element's **xpath** within that scope.

A name that looks framework-generated (`#ember1234`, `#mui-5`, `#radix-:r1:`) is refused
and the xpath is used instead — a name that is renumbered on every remount would make the
ref *less* stable than the position it replaced.

The hash is 32-bit, folded to hex; a collision within one walk gets a `-2` suffix. The ref
is also written back onto the element as an `aloha-id` attribute, which is how
`page_click` and friends find it again: `document.querySelector('[aloha-id="1d62a"]')`.

### Why it survives a re-render and a new process

Because it is **derived, not allocated**. Nothing hands out a number and remembers it.
Same page, same element, same input string, same hash — every time, for anyone.

A page that replaces its whole DOM subtree on every render keeps its refs, as long as the
element still has its authored name or is still in the same position:

```
$ alohajet open http://127.0.0.1:8877/          # before the re-render
[Save]   {aloha-id="2a441adc" button}           # <button id="save">
[Cancel] {aloha-id="a359a5c"  button}           # no authored name — xpath

$ alohajet read                                 # after innerHTML replaced both nodes
[Save]   {aloha-id="2a441adc" button}           # same
[Cancel] {aloha-id="a359a5c"  button}           # same
```

And a *different* process against a *different browser instance* computes the same refs
for the same page, because the computation happens in the page:

```
$ alohajet open http://127.0.0.1:8877/form.html          # alohajet's own Chromium
input("query")  {aloha-id="1d62a"  input}
select "alpha"  {aloha-id="1d62c"  select}
[Go]            {aloha-id="38ee4f" button}

$ alohajet --cdp 9787 read                                # a Chrome someone else launched
input("query")  {aloha-id="1d62a"  input}
select "alpha"  {aloha-id="1d62c"  select}
[Go]            {aloha-id="38ee4f" button}
```

That is what a `uid` tied to a snapshot, or a `backendNodeId` tied to a live node, cannot
do. A ref you wrote into a script last week still names the same button today.

### What invalidates a ref

Be exact about this; the guarantee is narrower than "forever".

| what happens | the ref |
|---|---|
| the page re-renders, element keeps its `#id` or `[data-testid]` | **survives** |
| the page re-renders, element without an authored name stays in the same position | **survives** |
| an element without an authored name **moves** — a sibling is inserted before it, a list reorders | **changes** (its xpath changed) |
| the element's `#id` changes, or the page starts minting generated ids | **changes** |
| a navigation, reload, or `goto` | ref string is unchanged for the same page, but **no ref resolves until you `read` again** — the walk is what plants the `aloha-id` attribute in the new document |
| the element is removed, or stops being visible/interactive | **gone** — the next walk does not emit it |

Two consequences worth internalising:

- **`goto` does not give you refs. Read after navigating.**
  `alohajet goto <url>` then `alohajet click <ref>` fails with
  `Element with aloha-id ... not found`, because nothing has walked the new document yet.
- **A ref is only meaningful on the page it came from.** Refs need to be unique within a
  walk, not across the web: `#save` on two unrelated pages hashes to the same string.

The measured cost of this scheme, from the commit that introduced it: about +9% observation
tokens versus a plain per-walk counter. A loop that ends at round three has already paid
that back by not re-reading the page.

## Connection modes

| mode | what it does | whose browser |
|---|---|---|
| *(default)* | launches **one** headless Chromium on first use, records it in `<tmp>/alohajet-<uid>/browser.json`, and every later invocation attaches to it | ours — `close` may close any tab, `quit` ends it |
| `--launch` | a throwaway Chromium for **this command only**, terminated on exit | ours, briefly. Refs it prints die with it, so single commands only |
| `--cdp <ws-url\|port\|host:port>` | attaches to a browser already listening on a debugging port. Never launched, never terminated | **the user's.** Tabs that were already open are refused by `close`, and everything in that browser is reachable |

`--no-headless` and `--port <n>` apply when a browser is actually launched. `--cdp` needs
only a CDP endpoint that publishes `/json/version`; Chrome, Chromium and Chrome for Testing
are what has been run against it.

Signals are handled: SIGINT/SIGTERM terminate a browser this process launched and delete
its temp profile. A `--cdp` browser is left alone.

## Environment

| variable | default | effect |
|---|---|---|
| `ALOHAJET_NETWORK_LOG` | off | set to a directory (or `1` for a temp dir) to record each agent-opened tab's requests to `<dir>/<tabId>.jsonl`, `0600` in a `0700` directory. Credential headers and credential-named body fields are masked; **response bodies are not**. Nothing deletes these files. |
| `ALOHAJET_CREDENTIAL_GUARD` | off | `1` makes `page_type` refuse to type into a field it classifies as a credential field and hand entry back to the human. Password-field *masking* on read is always on and is not controlled by this. |
| `ALOHAJET_MARKDOWN_URLS` | off | `1` includes each link's `href` in the markdown: `[Learn more](https://iana.org/domains/example) {aloha-id="719a97a0" a}` |
| `ALOHAJET_HIGHLIGHTS` | on | `0` skips the in-page click flourish. Purely cosmetic; the synthetic input event is sent either way. |
| `ALOHAJET_MAX_OBS_TOKENS` | off | cap one observation's estimated tokens, so a single huge page cannot blow the context |
| `ALOHAJET_COMPACT_TOOLS` | off | tighter default caps, for a small model |
| `ALOHAJET_CHROME_USER_AGENT` | Chrome's own | override the user agent of a browser alohajet launches |
| `ALOHAJET_DEBUG` | off | protocol chatter to stderr |

## Use it as a Swift library

`BrowserToolSession` is the whole API: connect, `run` a tool by name, shut down.

```swift
import BrowserTools

@main struct Demo {
    static func main() async throws {
        let session = try await BrowserToolSession.launch(headless: true)
        defer { Task { await session.shutdown() } }

        let page = await session.run("manage_tabs", arguments: [
            "action": "open", "url": "https://example.com"
        ])
        print(page.output)   // markdown with {aloha-id="..."} refs

        let click = await session.run("page_click", arguments: ["aloha_id": "719a97a0"])
        print(click.isError == true ? "failed: \(click.output)" : click.output)
    }
}
```

`BrowserToolSession.attach(port:)`, `.attach(host:port:)` and `.attach(webSocketURL:)`
connect to a browser you did not launch. `run` never throws; failures come back as a
`RawToolResult` with `isError == true`, which is what the model has to read anyway.

## The eight tools

Full arguments, defaults and constraints: **[docs/tools.md](docs/tools.md)** — generated
from `Sources/BrowserTools/Tools/Schemas.swift`, with a test that fails if the two drift.

| tool | what it does |
|---|---|
| `manage_tabs` | `list` / `read` / `open` / `close` / `use` / `unuse`. `read` and `open` return the page as interactive markdown with refs |
| `page_click` | click a ref — `single`, `double`, `triple` or `right` |
| `page_type` | type into a ref, or fill **up to 20 fields in one call** with `fields:` and `submit: true` |
| `page_select` | pick a `<select>` option by visible text or zero-based index |
| `get_text` | read the text or input value of **up to 20 refs in one call**, comma-separated |
| `page_navigate` | `goto` a URL, or `back` — in place, never a new tab |
| `page_press_keys` | send a key or chord to whatever has focus: `Enter`, `Escape`, `Control+a` |
| `page_wait_for` | poll for a CSS selector, up to 30s |

Only `http` and `https` URLs are accepted, and **the scheme is not optional**:
`alohajet open example.com` is refused (with a poor message — `URL not allowed: malformed
or oversized URL`). Write `https://example.com`.

## Limitations, honestly

Compared with [chrome-devtools-mcp](https://github.com/ChromeDevTools/chrome-devtools-mcp)
(~57 tools) and [chrome-agent](https://github.com/sderosiaux/chrome-agent), this is a
narrow tool, and here is where that costs you.

**Whole capability areas that are simply absent.** No performance traces or Lighthouse
audits. No console messages. No network-request inspection tools — the network *log* is a
debug file on disk, not something a model can query. No heap snapshots. No device
emulation, no CPU or network throttling, no viewport resize. No extension or PWA tools. No
`evaluate_script`. No `hover`, `drag`, `upload_file`, or dialog handling. No screencast.
chrome-devtools-mcp has all of those.

**No coordinate clicking, and that is a real gap.** Everything is addressed by ref, so
anything the DOM walk does not emit is unreachable: a `<canvas>` game, a WebGL viewport, a
map widget, a PDF rendered by the browser's own viewer. chrome-devtools-mcp has
`click_at`; [captivus/chrome-agent](https://github.com/captivus/chrome-agent) is built
entirely on coordinates. alohajet has nothing for it. That is the deliberate trade that
buys stable refs — but it is a trade, not a free win.

**Screenshots are MCP-only and opt-in.** `include_screenshot: true` on `manage_tabs`
`read`/`open` returns an `image` content block; it is off by default because it costs a
capture round-trip and image tokens on every read. The CLI cannot show you one at all.

**No extraction backend.** There is no readability pass, no site-JSON extraction turned on,
no "give me the article" verb. What you get is the rendered DOM serialized to markdown.

**Chrome/Chromium only.** It speaks CDP. Firefox and Safari are out.

**No releases, no CI, no version.** No `.github/`, nothing runs `swift build` on a push, no
prebuilt binaries, and the MCP `serverInfo.version` is a hardcoded `0.1.0`. `main` is what
there is.

**Rough edges you will meet.** JavaScript stack traces leak into tool output when a ref is
not found. `manage_tabs list` prints a `●` for the tab in use, but sources it from the
browser's own notion of the active tab rather than the session's, so in practice it marks
nothing (`--help` claims otherwise). The "no scheme" error message is wrong about what is
wrong.

## Security

Read [SECURITY.md](SECURITY.md). The short version: URL validation refuses everything that
is not `http(s)` — including `file:`, `data:` and `javascript:` — on both the destination
and the tab a tool is standing on; password fields are masked in the page before their
values cross the wire; the network log is off by default. There is no host allow-list, no
sandbox, and no prompt-injection defence. `--cdp` against your everyday browser hands an
agent your logged-in sessions, by design.

## License

Apache 2.0 — see [LICENSE](LICENSE). The in-page document walker is derived from
[browser-use](https://github.com/browser-use/browser-use) (MIT); the notice and verbatim
license text are in [NOTICE](NOTICE).
