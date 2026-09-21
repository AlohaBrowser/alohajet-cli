# Contributing

## The gate

```sh
swift build --build-tests
ALOHAJET_REQUIRE_BROWSER=1 swift test
```

`ALOHAJET_REQUIRE_BROWSER=1` is not optional. The end-to-end suites skip themselves when
no browser is reachable, so that someone without one still gets a green `swift test` — and
a silent skip is how a real-browser path goes untested behind a green badge. The flag
turns the skip back into a failure. CI sets it on both jobs; run it the same way or you
will open a pull request against a path you never exercised.

CI runs the same two commands on macOS 15 and on Ubuntu 24.04. On **Linux only** it adds
`--no-parallel`: that is a workaround for a corelibs `FileHandle.write` trap, not a
preference, and the reason is written out in full above the Test step in
[`.github/workflows/ci.yml`](../.github/workflows/ci.yml). Read it there before removing
the flag.

Install a real Chromium first, or the flag fails the run by design.

## Docs that are generated

[`docs/tools.md`](tools.md) is rendered from `Sources/BrowserTools/Tools/Schemas.swift` and
must not be hand-edited. Change the schema, then regenerate:

```sh
ALOHAJET_REGEN_DOCS=1 swift test --filter ToolsDoc
```

## Versioning

`Sources/alohajet/Version.swift` is the one place this package states its version. The
release workflow asserts the tag matches it, so bump it in the commit you tag, and keep
the `exact:` pin in the README's library snippet on the same value.

## Security

Do not report a vulnerability through a pull request or a public issue. Use the
repository's private advisory form.
