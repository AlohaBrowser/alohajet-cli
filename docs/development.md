# Working on alohajet

Everything here was run on macOS 26.2 (arm64) with Swift 6.2.3 and Google Chrome
152.0.7977.77, at commit `b43cd28`. Output is quoted as it came back.

## Build

```console
$ swift build -c release --product alohajet
Build of product 'alohajet' complete! (19.94s)
```

From a fresh clone there is one thing to resolve — the official MCP SDK, which
only the `alohajet` executable links — so the first build fetches it and its four
transitive packages. Building a library product (`swift build --product BrowserTools`)
compiles none of them: the plan creates their build directories and leaves them empty.

The build is not warning-free. Two are live, both harmless and both worth fixing:

```
Sources/ToolABI/AbortSignal.swift:213:13: warning: no calls to throwing functions occur within 'try' expression
Sources/BrowserTools/Tabs/CDPBrowserBacking.swift:223:27: warning: no 'async' operations occur within 'await' expression
```

An incremental build will not re-emit them; `touch` those two files, or build clean.

## Test

```console
$ swift test
✔ Test run with 404 tests in 64 suites passed after 17.542 seconds.
```

Part of that is a real browser: the `end to end, real browser` suite drives a
Chromium it launches. With no Chrome on the machine that suite skips itself, so a
green `swift test` locally does not by itself prove the browser paths ran. CI sets
`ALOHAJET_REQUIRE_BROWSER=1` to turn that skip back into a failure — see the
comments in `.github/workflows/ci.yml`, which are the authority on why.

## Regenerating the tool reference

`docs/tools.md` is generated from `Sources/BrowserTools/Tools/Schemas.swift` and is
**test-gated**: `ToolsDoc/checkedInDocMatchesTheSchemas()` fails if the checked-in
file drifts from the schema registry. Change a tool description and the suite goes
red until you regenerate.

```console
$ ALOHAJET_REGEN_DOCS=1 swift test --filter ToolsDoc
✔ Test checkedInDocMatchesTheSchemas() passed after 0.001 seconds.
```

Do not hand-edit `docs/tools.md`.

## Recording the demo transcript

[`docs/demo.md`](demo.md) is a captured session, not a written one. It carries its
own setup; re-run it whenever the CLI's output changes, and paste what comes back.

## A trap worth knowing

The default connection lane shares **one** browser per user, recorded in
`$TMPDIR/alohajet-<uid>/browser.json`. Two alohajet sessions running as the same
user drive the same browser and the same "tab in use": a `back` in one turns up in
the other, and either one's `quit` closes it under the other. This bit while
recording the transcript, and the symptom was a `back` that landed on a page the
session had never opened. Give a second session its own `TMPDIR`, or point it at
its own browser with `--cdp`.
