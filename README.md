# alohajet

**Drive a real browser from the command line and from MCP. Stable element refs, nine
tools, and four libraries with no SwiftPM dependencies — the CLI is the one target that
links one, the official MCP SDK, and only for `alohajet mcp --endpoint`.**

[Tool reference](docs/tools.md) · [A real session](docs/demo.md) · [Security](SECURITY.md)
· [Releasing](RELEASING.md) · [Working on it](docs/development.md)

Playwright was built to script a browser you control. alohajet is built to hand a browser
to a model: it attaches to a Chromium that already exists — one it launched, or one you
were already using — and exposes nine verbs that can finish a task on a web page.

The reason to pick it over the alternatives is that **element references are derived from
the page, not minted per snapshot**. Competing tools hand out `[ref=e1]`, `[ref=e2]` over
one snapshot and tell you to re-snapshot before you act. alohajet's ref is a hash of the
element's authored name or its frame-scoped xpath, so it is the same string in the next
process, against a different browser, tomorrow:

```console
$ alohajet open https://example.com
Opened: https://example.com
Tab ID: 100389FC9132CC3E52AEAC2C4CFE76CB
...
[Learn more] {aloha-id="719a97a0" a}

$ alohajet click 719a97a0                 # a separate process; nothing was carried over
Clicked element "719a97a0" (single). Navigated to https://www.iana.org/help/example-domains.
```

That is the whole pitch, and [it is proved below](#the-proof) rather than asserted — same
page, three different browsers, same ref. You can reproduce the proof yourself in about a
minute; it needs Python 3 and nothing else.

**What it is not**, before you spend the minute: not a Playwright replacement — no
assertions, no test runner, no trace viewer. Not a general CDP console — nine tools,
deliberately, against chrome-devtools-mcp's ~57. No coordinate clicking, so a `<canvas>`
game or a WebGL viewport is unreachable. No extraction verb, no readability pass. Every one
of those is expanded, with the reproduction, under [Limitations](#limitations).

---

## Requirements

| | |
|---|---|
| Swift | 6.2 or newer |
| OS | macOS 14+. Everything on this page was run on macOS 26.2 (arm64), Swift 6.2.3, Google Chrome 152.0.7977.77. |
| Linux | builds and tests in CI (Ubuntu 24.04, Swift 6.2.3); every measurement on this page is from macOS. |
| Browser | Google Chrome or Chromium — no minimum version is checked or established; everything here was run against 152.0.7977.77. With none installed, a 145 MB Chrome for Testing 126 is downloaded on first use ([Configuration](#configuration)). `--cdp` takes any CDP endpoint; `--browser aloha` takes the Aloha browser. |
| Python 3 | only to serve the fixture pages in [The proof](#the-proof) and [docs/demo.md](docs/demo.md). |
| Dependencies | none in the four library products (`BrowserTools`, `AgentDriver`, `CDP`, `ToolABI`) — Foundation only, no vendored tree. One in the `alohajet` executable: the official [MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk) (`from: "0.12.1"`), which `mcp --endpoint` relays over and nothing else uses. A consumer linking the libraries resolves it and compiles none of it. |

## Install

The repository is private, so this needs an account with access.

```sh
git clone https://github.com/AlohaBrowser/alohajet-cli.git
cd alohajet-cli
swift build -c release --product alohajet
mkdir -p ~/.local/bin
install -m 755 .build/release/alohajet ~/.local/bin/alohajet   # or anywhere on PATH
```

```console
$ swift build -c release --product alohajet
Build of product 'alohajet' complete! (19.94s)
```

If `~/.local/bin` is not on your `PATH`, every command on this page answers `command not
found`. Check the install landed before going further — this is the only command that
touches no browser:

```console
$ alohajet --help | head -1
alohajet — drive a real Chromium from the command line.
```

There is no `--version`, and no `doctor`. `alohajet --version` falls through to unknown-flag
handling: 84 lines of help, exit 2. The MCP `initialize` handshake is the only surface that
reports one (`"version": "0.1.0"`).

There is **no prebuilt binary**. `v0.1.0` is tagged and its release build failed, so no
release exists and no `curl | sh` line works today. [RELEASING.md](RELEASING.md) has the
detail.

To remove it: `rm ~/.local/bin/alohajet`, then `rm -rf "$TMPDIR/alohajet-$(id -u)"` and
`rm -rf ~/Library/Application Support/AlohaJet` — the latter only exists if it downloaded a
Chrome, and it is the 145 MB one. The throwaway `$TMPDIR/alohajet-cdp-<uuid>` profiles and
`$TMPDIR/alohajet-chrome-stderr-*.log` files clean themselves up: `reapStaleProfiles` in
`Sources/CDP/CDP.swift` deletes a profile once it can prove the owning pid is gone, and a
stderr log once it is a day old.

As a library, add it to your `Package.swift` and depend on the `BrowserTools` product:

```swift
.package(url: "https://github.com/AlohaBrowser/alohajet-cli.git", branch: "main")
```

## A real session

Each line is its own process. The browser is launched by the first command and outlives
every one of them until `quit` — that is deliberate, because refs printed by one command
have to still work in the next.

```console
$ alohajet open https://example.com
Opened: https://example.com
Tab ID: 100389FC9132CC3E52AEAC2C4CFE76CB
This tab is now the one page_click, page_type, page_select, page_navigate, page_press_keys, page_wait_for and get_text address. The page below is a snapshot taken at open; nothing refreshes it for you. After any click, type or navigation, call manage_tabs read with this tab_id to see the current page. Pass use: false on open to skip taking it.
Tab: "Example Domain" (ID: "100389FC9132CC3E52AEAC2C4CFE76CB")
URL: https://example.com/
Viewport: 756x469

Interactive view: the page rendered as structural markdown — # headings, - list items, [text](href) links, | a | b | table rows, and plain paragraphs. Content is clean and id-free; every actionable element (link, button, input, select, landmark) carries a trailing {aloha-id="ID" tag} marker. ...

<untrusted_page_markdown K="BA0AFD9D">
<interactive_page_markdown>
# Example Domain
This domain is for use in documentation examples without needing permission. Avoid use in operations.
[Learn more] {aloha-id="719a97a0" a}
</interactive_page_markdown>
</untrusted_page_markdown K="BA0AFD9D">

$ alohajet click 719a97a0
Clicked element "719a97a0" (single). Navigated to https://www.iana.org/help/example-domains.

$ alohajet quit
Closed the shared browser on port 55697.
```

Two things there are not decoration. The `<untrusted_page_markdown K="BA0AFD9D">` wrapper is
a keyed fence around everything the page said, so a model can tell page text from
instructions; the key is fresh per read, so a page cannot close the fence and write outside
it. It is a **delimiter, not a defence** — nothing detects prompt injection, and a model
that ignores the fence is on its own ([SECURITY.md](SECURITY.md)). The paragraph above it is
the tool's own preamble to the model, sent on every read — verbose on purpose, and the one
thing this page shortens. Every cut on this page is marked `...`; nothing else is edited.

A longer transcript — click, `back`, form fill, tab list, against a page served from disk
so it does not depend on anyone's website staying the same — is in
[docs/demo.md](docs/demo.md).

## The two surfaces

### CLI

`alohajet --help` for the full text, `alohajet <command> --help` for one command.

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
| `upload <ref> <path>...` | `page_upload` |
| `quit` | — closes the shared browser |
| `mcp` | — serves all nine over stdio |

`--tab <id>` is global, not a flag on `read`: it goes before the verb on any command that
touches a page — `alohajet --tab <id> click <ref>`. The table names it only where you are
most likely to need it.

`--json` on any command prints the raw tool result instead of prose. Exit codes, each one
run to confirm it:

```console
$ alohajet --launch open https://example.com   ; echo $?   # 0  ok
$ alohajet --launch open example.com           ; echo $?   # 1  tool error
$ alohajet frobnicate                          ; echo $?   # 2  usage
$ alohajet --cdp 9999 read                     ; echo $?   # 3  browser unreachable
```

One command is not a tool call. `alohajet -p "<prompt>"` hands one turn to an agent loop
that is already running behind an HTTP endpoint (`POST /agent/task`). **No loop ships in
this package**: the endpoint defaults to `http://127.0.0.1:8765`, the Aloha browser's own
automation server on this machine, and `--endpoint <url>` names a different one.

The local app is launched — or activated — for you, and the launches that cannot work are
refused by name instead of by timeout:

```console
$ alohajet -p "book me a table" --headless
alohajet: app already running with a visible window — quit it, or drop --headless
```

### MCP

`alohajet mcp` speaks Model Context Protocol over stdio: newline-delimited JSON-RPC 2.0,
protocol versions `2024-11-05`, `2025-03-26` and `2025-06-18`. Only protocol traffic goes
to stdout; diagnostics go to stderr. No browser is launched until the first `tools/call`,
so a host that only lists tools pays nothing.

The block below goes wherever your host keeps `mcpServers` — for Claude Code that is
`.mcp.json` beside the project, and `claude mcp list` then answers
`alohajet: /Users/you/.local/bin/alohajet mcp - ⏸ Pending approval`. Use the absolute path;
the host does not run it through your login shell, so `~/.local/bin` on your `PATH` does
not help it.

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

To drive the browser you already have open instead of a fresh headless one, add the
connection flag — and read [SECURITY.md](SECURITY.md) first, because that config hands the
agent every tab and every logged-in session in that browser:

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

A live `initialize` answers `serverInfo: {"name": "alohajet", "version": "0.1.0"}`, and
`tools/list` returns the nine tools below with `readOnlyHint=true` on exactly two,
`get_text` and `page_wait_for`. The hint is per tool, not per call, so `manage_tabs` is
false even though its `list` and `read` actions only observe. `manage_tabs` with
`include_screenshot: true` returns a second content block of type `image` next to the text;
the CLI has no equivalent and drops the pixels.

#### `mcp --endpoint <url>` — the other product behind the same verb

With `--endpoint`, `alohajet mcp` serves nothing of its own and launches no browser. It is
a pipe: stdin/stdout on one side, `POST <url>/mcp` on the other — the MCP server a running
Aloha browser mounts on its automation port. The tools you get are the browser's, not the
nine above.

It exists for one client. Claude Desktop's config parser takes `{command, args, env}` and
drops any entry carrying `type`/`url`/`headers` with a "not valid MCP server
configurations" dialog, so a browser that already speaks MCP over HTTP is unreachable from
it without a stdio front end. Hosts that speak HTTP (Claude Code:
`claude mcp add --transport http …`) should talk to that endpoint directly instead — this
lane adds a process and buys them nothing.

```json
{
  "mcpServers": {
    "aloha-browser": {
      "command": "/Users/you/.local/bin/alohajet",
      "args": ["mcp", "--endpoint", "http://127.0.0.1:8765"]
    }
  }
}
```

The bearer token is read per run, not pasted: `ALOHAJET_AGENT_TOKEN`, else the browser's
own `~/Library/Application Support/Aloha/automation-token` — and that ambient file is sent
to a loopback endpoint only, which is the same rule `-p` follows. Plaintext `http` to
anywhere but this machine is refused outright (exit 2), since every frame on this pipe
drives the browser. Both halves use the official MCP SDK's own transports, because the
server end validates `Accept: application/json, text/event-stream`, answers over SSE and
issues a session id that has to be replayed as `Mcp-Session-Id`.

## The two browser lanes

`--browser chromium` (the default) drives a Chromium. `--browser aloha` attaches to the
Aloha browser's own CDP listener on `127.0.0.1:9222` (or `ALOHA_CDP_PORT`), starting the
app if it is not running. It is the user's browser: never terminated, and its pre-existing
tabs are theirs.

```console
$ alohajet --browser aloha tabs
2 tab(s) open:

1. [Current tab — the page you are looking at]  [the user's tab — cannot be closed]
   ID: 786347A9-F916-41CF-A23E-78B28AA03961
   URL: [non-web URL hidden]

2. Error [the user's tab — cannot be closed]
   ID: A3A286AD-D796-4FED-9AD7-895845AFB4EB
   URL: http://localhost:6555/errors/error.html?...
```

Within the chromium lane there are three connection modes:

| mode | what it does | whose browser |
|---|---|---|
| *(default)* | launches **one** headless Chromium on first use, records it in `<tmp>/alohajet-<uid>/browser.json`, and every later invocation attaches to it | ours — `close` works on tabs it opened, `quit` ends it |
| `--launch` | a throwaway Chromium for **this command only**, terminated on exit. Refs it prints die with it, so single commands only | ours, briefly |
| `--cdp <ws-url\|port\|host:port>` | attaches to a browser already listening on a debugging port. Never launched, never terminated | **the user's**, and everything in it is reachable |

`--headless` / `--no-headless` and `--port <n>` are read only when a browser is actually
launched, not when one is reused. SIGINT and SIGTERM terminate a browser this process
launched and delete its throwaway profile; a `--cdp` or `aloha` browser is left alone.

## Stable element refs

Every actionable element in a `read` carries a ref:

```
input("query") {aloha-id="4d399647" input}
select "alpha" [options: [49699f13.0] *alpha, [49699f13.1] beta] {aloha-id="49699f13" select}
[Go] {aloha-id="6586acdd" button}
```

### How a ref is derived

There is exactly one place a ref comes from — `alohaIdFor` in
[`Sources/BrowserTools/Runtime/DomTreeScript.swift`](Sources/BrowserTools/Runtime/DomTreeScript.swift).
It hashes a string built from two parts:

1. **The scope** — which document the element lives in: the chain of iframe selectors and
   shadow-root indices down to it. Without it, an iframe's children and the top document's
   children collide, because both are walked from the same root path.
2. **The identity** — the first of these that answers:
   - an **authored name** the page's own developers wrote: `#id`, else
     `[data-testid]` / `[data-test]`;
   - otherwise the element's **xpath** within that scope.

An authored name that looks framework-generated is refused and the xpath used instead — a
name renumbered on every remount would make the ref *less* stable than the position it
replaced. The predicate is one line of `looksGenerated`, and it is stricter than the
`#ember1234` example suggests: a name is refused if it does not match `^[A-Za-z][\w-]*$`,
or ends in three or more digits, or ends in `-<digits>` or `_<digits>`. So `id="item-1"`,
`id="row_2"` and `id="step-3"` all fall back to xpath, silently.

The hash is 32-bit folded to hex; a collision within one walk gets a `-2` suffix. The ref
is written back onto the element as an `aloha-id` attribute, which is how `page_click` and
friends find it again: `document.querySelector('[aloha-id="4d399647"]')`.

### The proof

Because the ref is **derived, not allocated**, nothing has to remember it. Same page, same
element, same input string, same hash — for anyone, in any process.

Run it yourself. Two fixtures, one server, four commands; the ids you get back are the ids
printed here, because they are a function of the markup and nothing else. In one terminal:

```sh
mkdir -p /tmp/refs && cd /tmp/refs

cat > rerender.html <<'EOF'
<!doctype html>
<meta charset="utf-8">
<title>Rerender</title>
<div id="panel">
  <button id="save">Save</button>
  <button>Cancel</button>
</div>
<script>
  setTimeout(function () {
    document.getElementById("panel").innerHTML =
      '<button id="save">Save</button><button>Cancel</button>';
  }, 300);
</script>
EOF

cat > insert.html <<'EOF'
<!doctype html>
<meta charset="utf-8">
<title>Insert</title>
<div id="panel">
  <button id="save">Save</button>
  <button>Cancel</button>
</div>
<script>
  setTimeout(function () {
    document.getElementById("panel").innerHTML =
      '<button>Extra</button><button id="save">Save</button><button>Cancel</button>';
  }, 300);
</script>
EOF

python3 -m http.server 8877 --bind 127.0.0.1
```

`rerender.html` throws away both buttons 300ms after load and builds new ones. `open` sees
the originals; `read`, a separate process, sees the replacements. Both `aloha-id` lines
below are captured output — only the preamble paragraph is cut, marked `...`:

```console
$ alohajet open http://127.0.0.1:8877/rerender.html
Opened: http://127.0.0.1:8877/rerender.html
Tab ID: 75EA0FE245FFF2887BAFA7C5C81E8B7F
...
[Save] {aloha-id="2a441adc" button}
[Cancel] {aloha-id="a359a5c" button}

$ alohajet read
...
[Save] {aloha-id="2a441adc" button}
[Cancel] {aloha-id="a359a5c" button}
```

`Save` keeps its ref because it has `id="save"`. `Cancel` has no authored name, so its ref
is the hash of its xpath — and the replacement lands at the same xpath, so it survives too.
The next section shows what happens when it does not.

The same argument across *browsers*, which needs your own second Chrome
(`--remote-debugging-port=9787`) and, for the third line, the Aloha browser installed:

```console
$ alohajet open https://example.com
[Learn more] {aloha-id="719a97a0" a}

$ alohajet --cdp 9787 open https://example.com
[Learn more] {aloha-id="719a97a0" a}

$ alohajet --browser aloha open https://example.com
[Learn more] {aloha-id="719a97a0" a}
```

### What invalidates a ref

The guarantee is narrower than "forever", and the narrowness is what makes it believable.
`insert.html`, the second fixture above, re-renders the same panel with one extra button
**before** the other two:

```console
$ alohajet open http://127.0.0.1:8877/insert.html
...
[Save] {aloha-id="2a441adc" button}
[Cancel] {aloha-id="a359a5c" button}

$ alohajet read
...
[Extra] {aloha-id="a359a3d" button}
[Save] {aloha-id="2a441adc" button}
[Cancel] {aloha-id="a359a7b" button}
```

`Save` is unchanged — it has `#save`. `Cancel` went `a359a5c` → `a359a7b`, because its
xpath moved. That is the bound on the whole claim, and it is why the table below is worth
reading before you build a loop on top of this.

| what happens | the ref |
|---|---|
| the page re-renders, element keeps its `#id` or `[data-testid]` | **survives** |
| the page re-renders, element without an authored name stays in the same position | **survives** |
| an element without an authored name **moves** — a sibling inserted before it, a list reorders | **changes** |
| the element's `#id` changes, or the page starts minting generated ids | **changes** |
| a navigation, reload, or `goto` | the ref *string* is unchanged for the same page, but **no ref resolves until you `read` again** — the walk is what plants the `aloha-id` attribute in the new document |
| the element is removed, or stops being visible | **gone** — the next walk does not emit it |

Two consequences worth internalising:

- **`goto` does not give you refs. Read after navigating.** A `goto` followed straight by
  a `click` answers `Execution error (Error): Element with aloha-id 2a441adc not found`,
  even when the ref is correct for the page it just landed on — and drops a JavaScript
  stack trace under it.
- **A ref is only meaningful on the page it came from.** Refs are unique within a walk, not
  across the web: the same link text in the same structural position on two unrelated pages
  hashes to the same string. [docs/demo.md](docs/demo.md) shows exactly that happening.

The scheme costs roughly 9% more observation tokens than a plain per-walk counter, because
a hex hash is longer than `e7`. That figure comes from the private history this package was
cut out of and **is not reproducible from this repository** — every other number on this
page is. Treat it as an order of magnitude, not a measurement.

## The nine tools

Full descriptions, defaults and constraints: **[docs/tools.md](docs/tools.md)** — generated
from `Sources/BrowserTools/Tools/Schemas.swift`, with a test
(`ToolsDoc/checkedInDocMatchesTheSchemas()`) that fails if the two drift. The arguments
below were read back off a live `tools/list`, so they are the schema, not a paraphrase.

| tool | arguments | required |
|---|---|---|
| `manage_tabs` | `action` (`list`/`read`/`open`/`close`/`use`/`unuse`), `tab_id`, `url`, `use` (default `true`), `controlled_by` (`agent`/`user`, default `agent`), `include_screenshot` | `action` |
| `page_click` | `aloha_id`, `click_type` (`single`/`double`/`triple`/`right`, default `single`) | `aloha_id` |
| `page_type` | `aloha_id`, `text`, `fields` (array of `{aloha_id, text, replace}`, 1–20), `replace` (default `true`), `submit` (default `false`) | either `aloha_id`+`text`, or `fields` |
| `page_select` | `aloha_id`, `text`, `index` (integer ≥ 0) | `aloha_id`, plus either `text` or `index` |
| `get_text` | `aloha_id` (one, or up to 20 comma-separated), `max_chars` (default `20000`, minimum `1`) | `aloha_id` |
| `page_navigate` | `action` (`goto`/`back`), `url` | `action` |
| `page_press_keys` | `keys` — e.g. `Enter`, `Escape`, `Control+a` | `keys` |
| `page_wait_for` | `selector`, `timeout_ms` (default `10000`, clamped to `30000`) | `selector` |
| `page_upload` | `aloha_id`, `paths` (array of absolute paths, 1+) | `aloha_id`, `paths` |

`page_type` and `get_text` are the two batch tools, and the batching is the point: filling
a five-field form is one call, not five rounds. Both caps are 20 and both are declared in
the schema (`maxItems`), not merely enforced at runtime, so a validating provider can see
them.

Only `http` and `https` URLs are accepted, and **the scheme is not optional**:

```console
$ alohajet --launch open example.com
URL not allowed: malformed or oversized URL.
```

That message is wrong about what is wrong. Write `https://example.com`.

## Configuration

Every variable the sources actually read, checked with
`grep -rhoE 'ALOHAJET_[A-Z_]+|ALOHA_[A-Z_]+' Sources/`.

| variable | default | effect |
|---|---|---|
| `ALOHAJET_BROWSER` | a system Chrome | path to the Chromium executable the default and `--launch` lanes run. Unset and with no system Chrome, **Chrome for Testing 126.0.6478.126 is downloaded on first use** — a 145 MB zip, unpacked into `~/Library/Application Support/AlohaJet/chrome-for-testing`. There is no pre-warm command and nothing cleans it up; `rm -rf` that directory. |
| `ALOHAJET_NETWORK_LOG` | off | a directory (or `1` for a temp dir) to record each agent-opened tab's requests as JSONL, `0600` in a `0700` directory. Read the limitation below before trusting it. |
| `ALOHAJET_CREDENTIAL_GUARD` | off | `1` makes `page_type` refuse to type into a field it classifies as a credential field. Password-field *masking on read* is always on and is not controlled by this. |
| `ALOHAJET_MARKDOWN_URLS` | off | `1` includes each link's `href`: `[Learn more](https://iana.org/domains/example) {aloha-id="719a97a0" a}` |
| `ALOHAJET_HIGHLIGHTS` | on | `0` skips the in-page click flourish. Cosmetic; the synthetic input event is sent either way. |
| `ALOHAJET_MAX_OBS_TOKENS` | off | cap one observation's estimated tokens, so a single huge page cannot blow the context |
| `ALOHAJET_COMPACT_TOOLS` | off | tighter default caps, for a small model |
| `ALOHAJET_CHROME_USER_AGENT` | Chrome's own | override the user agent of a browser alohajet launches. See the HeadlessChrome limitation below. |
| `ALOHAJET_DEBUG` | off | protocol chatter to stderr |
| `ALOHA_CDP_PORT` | `9222` | where `--browser aloha` looks for the Aloha browser's CDP listener |
| `ALOHA_BROWSER_APP` | registered install | path to the Aloha `.app` that `--browser aloha` launches |
| `ALOHAJET_AGENT_TOKEN` | read from disk | the bearer token `-p` sends to `--endpoint`. Unset, it is read from `~/Library/Application Support/Aloha/automation-token`. Absent entirely, no `Authorization` header is sent and the endpoint answers 401 — never a silent unauthenticated retry. |

## Limitations

Not a disclaimer. These are the things that will cost you a round trip, and each one was
reproduced on this machine before it was written down.

**Linux is built and tested, but nothing on this page was measured there.** Every number,
every transcript and the ref-stability proof were produced on macOS. The Linux job builds
and runs the suite; it does not re-run the proof.

**`close` refuses tabs alohajet itself opened, under `--cdp` and `--browser aloha`.** Each
CLI command is a new process, and the "we opened this" bookkeeping does not survive it:

```console
$ alohajet --cdp 9787 open https://example.com
Tab ID: 4FA9185C1D3265C7DA3AB09AD3A7879F

$ alohajet --cdp 9787 close 4FA9185C1D3265C7DA3AB09AD3A7879F
Cannot close "Example Domain": it is the user's tab, not one you opened.
You may only close tabs opened by manage_tabs.
```

`close` works across processes on the default shared lane, where the bookkeeping lives in
`browser.json`. On the other two lanes it is effectively dead.

**"The tab in use" does not survive a process on those lanes either.** After the `open`
above, a later bare `alohajet --cdp 9787 read` reads the browser's *first* http(s) tab, not
the one `open` just took. Pass `--tab <id>` explicitly outside the default lane.

**No coordinate clicking, and that is a real gap.** Everything is addressed by ref, so
anything the DOM walk does not emit is unreachable: a `<canvas>` game, a WebGL viewport, a
map widget, a PDF in the browser's own viewer.
[chrome-devtools-mcp](https://github.com/ChromeDevTools/chrome-devtools-mcp) has `click_at`;
[chrome-agent](https://github.com/captivus/chrome-agent) is built entirely on coordinates.
alohajet has nothing for it. This is the trade that buys stable refs — a trade, not a free
win.

**No extraction verb.** There is no `web_extract`, no readability pass, no site-JSON
extractor, no "give me the article". `nativeAgentToolNames` in
`Sources/BrowserTools/Tools/Tools.swift` is exactly the nine tools above and none of them
is an extractor. What you get is the rendered DOM serialized to markdown.

**Whole capability areas are simply absent.** No performance traces or Lighthouse audits.
No console messages. No network-request inspection a model can query. No heap snapshots. No
device emulation, throttling, or viewport resize. No extension or PWA tools. No
`evaluate_script`. No `hover`, `drag`, or dialog handling. No screencast.
chrome-devtools-mcp has all of those across ~57 tools; this has nine, deliberately.

**`ALOHAJET_NETWORK_LOG` is a debugging aid, and a rough one.** The file is named from an
internal id you cannot correlate to anything the CLI prints — a tab printed as
`915E5DE332A24AF2218E6A9717ED027E` logged to `tab-914C8BAA-7A1.jsonl` — and the main
document request is never recorded, only subresources, so a page whose only request is its
own HTML produces an empty file. Response bodies are **not** masked, and nothing deletes
these files.

**The launched Chromium advertises itself as HeadlessChrome.** Its User-Agent is
`...HeadlessChrome/152.0.0.0 Safari/537.36`, so a site that gates on it will refuse the
default lane. `ALOHAJET_CHROME_USER_AGENT` is one workaround; `--cdp` against a normal
browser is the other.

**Screenshots are MCP-only and opt-in.** `include_screenshot: true` costs a capture
round-trip and image tokens on every read, so it is off by default. The CLI cannot show you
one at all.

**Two sessions as the same user share one browser.** The default lane records its browser
in `$TMPDIR/alohajet-<uid>/browser.json`, so a second alohajet driving the "same" tab from
another terminal is not hypothetical — see the trap in
[docs/development.md](docs/development.md). Give the second one its own `TMPDIR`, or its
own `--cdp`.

**Chrome/Chromium only.** It speaks CDP. Firefox and Safari are out.

**Rough edges you will meet.** A JavaScript stack trace leaks into tool output when a ref
is not found. `manage_tabs list` sources its "in use" marker from the browser's own active
tab rather than the session's, so in practice it marks nothing, while `alohajet tabs
--help` still claims it does. `page_type`'s result nudges CLI users toward
`fields=[{aloha_id, text}, ...]`, a shape the CLI has no flag for — that text is written
for the MCP surface and emitted on both.

## Security

Read [SECURITY.md](SECURITY.md) before pointing this at a browser you are logged into. The
short version: URL validation refuses everything that is not `http(s)` — `file:`, `data:`,
`javascript:` — on both the destination and the tab a tool is standing on; password fields
are masked in the page before their values cross the wire; the network log is off by
default. There is no host allow-list, no sandbox, and no prompt-injection detection.
`--cdp` and `--browser aloha` against your everyday browser hand an agent your logged-in
sessions, by design.

## Using it as a library

`BrowserToolSession` is the whole API: connect, `run` a tool by name, shut down. The
snippet below was compiled and run as written, and it leaves no browser behind.

```swift
import BrowserTools

let session = try await BrowserToolSession.launch(headless: true)

let page = await session.run("manage_tabs", arguments: [
    "action": "open", "url": "https://example.com"
])
print(page.output)   // markdown with {aloha-id="..."} refs

let click = await session.run("page_click", arguments: ["aloha_id": "719a97a0"])
print(click.isError == true ? "failed: \(click.output)" : click.output)

await session.shutdown()
```

`shutdown()` must be awaited on every path. `defer { Task { await session.shutdown() } }`
schedules work the process exits before running, which leaks a headless Chromium and its
temp profile on every run.

`BrowserToolSession.attach(port:)`, `.attach(host:port:)` and `.attach(webSocketURL:)`
connect to a browser you did not launch. `run` never throws; failures come back as a
`RawToolResult` with `isError == true`, which is what the model has to read anyway. The
package also exports an `AgentDriver` product — the seam behind `-p`, not documented here
because `-p` needs an endpoint this package does not provide.

## License

Apache 2.0 — see [LICENSE](LICENSE).

This package carries no third-party source and vendors no tree: the CDP client, the
WebSocket transport, the page-side runtime scripts, the DOM serializer and the tool layer
were written for it. It declares one SwiftPM dependency, the official
[MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk), and it hangs on the
`alohajet` executable target alone — `mcp --endpoint` relays onto a running browser's own
MCP server over that SDK's transports rather than re-implementing Streamable HTTP. The
four library products link nothing.
