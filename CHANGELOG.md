# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `THIRD-PARTY-NOTICES`, covering the seven packages the executable links statically, is
  shipped inside every release tarball.
- Release tarballs carry a `BUILD-TOOLCHAIN` file naming the Swift toolchain that built
  the binary, and release assets carry a build-provenance attestation that
  `gh attestation verify` can check.

### Changed

- The provisioned Chrome for Testing moved from 126.0.6478.126 to 153.0.8010.52.
- `LICENSE` now asserts the copyright owner instead of carrying the Apache-2.0 template
  placeholder.

### Fixed

- The network log's fallback write creates the file at 0600 rather than at the umask
  default, matching the permission the primary path already enforced.
- Every entry in the `docs/tools.md` table of contents was a dead anchor; the links now
  match the headings they point at.
- `workflow_dispatch` on the release workflow reached an unsatisfiable version assertion
  and could never publish; it now builds the version it was given.

### Removed

- `scripts/install.sh`, which pointed at a repository that does not hold this project, and
  `RELEASING.md`, `SECURITY.md` and `docs/development.md`, which described a state the
  code left behind.
- The unused `SdkTabResult` surface and its mapping functions.

## [0.4.3] - 2026-09-20

### Changed

- A page tool now addresses a tab alohajet owns, or none. Called before `manage_tabs use`
  or `open`, or after `unuse`, it fails instead of silently driving whatever tab the
  browser listed first — which, when attached to a browser you were already using, was the
  page you were reading.
- Tab ownership is recorded per browser lane, so `close` reaches a tab an earlier
  `alohajet` process opened and `read` with no `--tab` lands on it. A browser restart
  expires the record and `close` refuses again.
- `manage_tabs list` and `alohajet tabs` mark with ● the tab the page tools address.
- `alohajet mcp` connects through the same shared browser `alohajet open` uses, honouring
  `ALOHAJET_BROWSER` and the Chrome-for-Testing download, and ended by `alohajet quit`.
- `--browser aloha` launches the app this executable ships inside rather than whichever
  copy LaunchServices prefers, so a stale CDP port can no longer start a second instance
  on the same profile.
- `ALOHAJET_BROWSER` naming a path that is not an executable is an error (exit 3) naming
  the variable and the path, instead of silently falling through to another Chrome.
- A non-loopback `--endpoint` given without an explicit `ALOHAJET_AGENT_TOKEN` says on
  stderr that the browser's own token file is not sent to it. The help and README state
  that a remote endpoint is allowed, which they previously denied.

### Fixed

- `page_upload` refuses a stale or unknown `aloha_id` and an element that neither is nor
  contains a file input, instead of resolving any unrecognised target to the page's last
  file input and reporting success against the id it was given. The receipt names the
  input the bytes landed on.
- One upload fires one `change` event rather than three.
- `page_type` with `fields[]` and `submit: true` settles the URL before reporting, so a
  form that did navigate is no longer described as not having navigated.
- A `contenteditable` host receives an `aloha-id`, making `page_type`'s documented support
  for it reachable.
- The MCP relay uses the MCP host's own 600 s deadline, so a tool call the browser takes
  more than a minute over no longer ends the whole session while the work completes. A
  refused connection still fails instantly.
- An `/agent/result` poll that overran a single deadline failed the turn with thousands of
  polls of budget left; the poll now has its own 10 s timeout and is retried, and only 20
  consecutive failures end the wait.
- A failed `-p` turn prints its chat id and says the turn may still be running in the app.

## [0.4.2] - 2026-09-19

### Changed

- `-p` answers the app's Terms of Service and Privacy Policy question instead of polling
  past it: on a terminal it prompts, on a pipe it declines when the app has no window to
  ask in and otherwise points at the app window. A turn that ends unaccepted says so and
  exits 1.
- Waiting on that question no longer counts against the turn's poll budget, so a slow
  acceptance cannot time out a long agent turn.
- `alohajet --help` fits an 80-column terminal, leads with the agent, and covers
  `--resume`, `--continue`, `--headless`, `--endpoint`, `--json` and the terms question.
- `--continue`'s help says what it does: it continues the last `-p` chat, not the chat on
  screen.

### Fixed

- `alohajet -p --help` prints the help and exits 0 instead of sending `--help` to the app
  as a prompt and running a real turn.
- The executable target no longer shares a build folder with the `AlohaJet` library on a
  case-insensitive disk, which broke linking for any package depending on both.

## [0.4.1] - 2026-09-18

### Fixed

- `page_type` and `page_select` advertised `anyOf` at the top level of their `parameters`,
  which OpenAI rejects with HTTP 400 for the whole tool array — every turn of every session
  reaching that provider failed before a token was generated. The constraint is stated in
  each tool's description and enforced by each executor instead.
- `manage_tabs open` accepts the legacy `focus: false` again; a resumed or compacted
  session replaying the recorded call silently made the new tab the one every later
  `page_click`, `page_type` and `get_text` addressed.

## [0.4.0] - 2026-09-17

### Added

- `alohajet mcp --endpoint <url>` is a stdio pipe to a running app's `POST /mcp`, for
  clients whose config parser accepts only `{command, args, env}`. Without the flag,
  `alohajet mcp` serves this package's own tools against its own browser, unchanged.
- The browser launcher, with refusals that name the problem — `--headless` against a
  visible window, no `--headless` against a headless instance, an app too old to report
  its state, LaunchServices refusing — in place of a twenty-second timeout.

### Changed

- `-p` no longer requires `--endpoint`; it defaults to `http://127.0.0.1:8765`. An empty
  `--endpoint=` is a usage error rather than a silent fall-through.
- The package takes its first dependency, the official MCP Swift SDK. It hangs on the
  executable target alone: a consumer linking only the libraries compiles none of it.
- `Package.resolved` is committed, so this repository's own builds are pinned.

## [0.3.1] - 2026-09-17

### Fixed

- Three model-supplied numbers on the pointer path took the whole process down rather than
  returning an error: a coordinate of `1e300` trapped on rounding, a `steps` count trapped
  or hung for `Int.max` CDP round-trips, and a delay of `NaN` trapped on conversion. All
  three are bounded, and an ordinary drag still dispatches its events.
- A refusal no longer names a tool the host does not advertise, which sent models to spend
  a round on an unknown verb.

## [0.3.0] - 2026-09-17

### Added

- `page_upload`, with the file-input mechanics behind it — chooser interception,
  `DOM.setFileInputFiles` with a DataTransfer fallback, and a read-back that gates success
  so a bare dispatch cannot report one. The staging sandbox is a protocol the CLI
  implements.
- `ToolABI` and `CDP` are products, so a consumer may import them by name instead of
  relying on SwiftPM leaking a transitive target onto the search path.
- `NativeToolServices` is `open`, and `ToolExecutionContext` carries `sessionKey` and
  `chatSessionId`, so a host can subclass rather than fork.
- `makeCDPBrowserTabsService` takes `navigationPacer` and `onTabCreated`.
- `canonicalToolWireSurface` publishes the tool names and enum values, so a consumer can
  pin the wire format in a test.

### Changed

- `manage_tabs` is the single tab implementation and gains `controlled_by`. The older
  spelling (`tabId`, `focus`/`unfocus`) is accepted but not advertised, and counted so it
  can be retired on evidence.

### Removed

- `PacingGate`/`NoPacing`, which had one no-op implementation and dropped the key a rate
  limiter would charge against.

## [0.2.1] - 2026-09-16

### Added

- `CDPClient.subscribeEvents(id:)` and `endEventSubscription(_:)`, additive to 0.2.0.

### Fixed

- Console capture delivers every event the page emitted rather than whatever arrived
  inside a fixed 20 ms sleep, which on a loaded machine silently truncated what the model
  was shown. The 20 ms also leave the end of every `tab_execute`.

## [0.2.0] - 2026-09-15

### Added

- `alohajet`: drive a real browser from the command line and from MCP, against a Chromium
  it launches or one already running, with element refs derived from the page rather than
  minted per snapshot.
- `--version`, backed by a single declaration that `--version` and the MCP `serverInfo`
  both read. Previously `--version` was not a flag at all: it fell through to the help
  text and exited 0, and the MCP server reported a hardcoded `0.1.0`.
- `-p` runs each turn in its own conversation and prints its id, with `--resume <chat-id>`
  for a named one and `--continue` for the one the agent is already on. Before this, two
  turns from two terminals landed in one transcript.
- Release tarballs for macOS (universal) and Linux x86_64, with a single `SHA256SUMS`.

### Fixed

- The package compiles and its tests run on Linux, where `stdout` is a mutable global and
  the signal reaper's flush could not build.
- `--resume` refuses a host that cannot confirm the conversation it resumed, and
  `--resume ""` — an unset shell variable — exits 2 instead of starting a new conversation
  and reporting success.
- `-p` no longer sends the ambient browser token to a non-loopback endpoint, and refuses
  plaintext http to a non-loopback host.
- The release workflow selects a toolchain that can read the manifest and skips Swift
  6.2.4, whose frontend crashes compiling this package for a universal binary. No tag had
  produced a macOS asset before.

[Unreleased]: https://github.com/AlohaBrowser/alohajet-cli/compare/v0.4.3...HEAD
[0.4.3]: https://github.com/AlohaBrowser/alohajet-cli/compare/v0.4.2...v0.4.3
[0.4.2]: https://github.com/AlohaBrowser/alohajet-cli/compare/v0.4.1...v0.4.2
[0.4.1]: https://github.com/AlohaBrowser/alohajet-cli/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/AlohaBrowser/alohajet-cli/compare/v0.3.1...v0.4.0
[0.3.1]: https://github.com/AlohaBrowser/alohajet-cli/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/AlohaBrowser/alohajet-cli/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/AlohaBrowser/alohajet-cli/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/AlohaBrowser/alohajet-cli/releases/tag/v0.2.0
