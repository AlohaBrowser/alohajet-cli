# Releasing

## Current state, before anything below is believed

`v0.1.0` is tagged. **There is no release attached to it**: the `release` workflow ran
on that tag and both build jobs failed, so no tarball and no `SHA256SUMS` exist. Every
`releases/latest/download/...` URL on this page 404s today, and so does the install
script, which fetches from exactly those URLs.

The two failures, from the run's own log:

- **macOS** — `error: 'alohajet': package 'alohajet' is using Swift tools version 6.2.0
  but the installed version is 6.1.0`. `release.yml` builds with whatever toolchain the
  runner image defaults to; `ci.yml` has a "Select a toolchain that can build this
  package" step and `release.yml` does not.
- **Linux** — `Sources/BrowserTools/Session.swift:460:24: error: reference to var
  'stdout' is not concurrency-safe because it involves shared mutable state`. Glibc
  declares `stdout` as a mutable global where Darwin declares a `let`, so `fflush(stdout)`
  compiles on macOS and is rejected on Linux under Swift 6. The same error fails the
  `linux` job of every CI run to date.

Until both are fixed and a tag builds green, the source build is the only install path
that works. It is first below for that reason.

## Building it yourself

Verified from a fresh clone: 19 seconds, no dependencies to resolve.

```sh
git clone https://github.com/AlohaBrowser/alohajet-cli.git
cd alohajet-cli
swift build -c release --product alohajet
.build/release/alohajet --help
```

The repository is **private**, so this needs an account with access and git credentials
that carry it.

## The install script, once there is something to install

```sh
curl -fsSL https://raw.githubusercontent.com/AlohaBrowser/alohajet-cli/main/scripts/install.sh | sh
alohajet --help
```

Three things have to be true before that line works, and none is true now:

1. The repository has to be public. `raw.githubusercontent.com` serves no private
   content, so the command 404s before it ever reaches the script — verified today,
   with the correct repository name.
2. A tag has to have produced a release carrying the assets below. There are none.
3. `scripts/install.sh` has to name this repository. Its line 14 reads
   `REPO="${ALOHAJET_REPO:-AlohaBrowser/alohajet}"`, and this package is
   **`AlohaBrowser/alohajet-cli`** — `AlohaBrowser/alohajet` is a different, existing
   repository. Until that default is corrected, the script fetches from the wrong
   place; `ALOHAJET_REPO=AlohaBrowser/alohajet-cli` overrides it in the meantime.
   (A one-line fix in `scripts/`, not a document fix.)

## What a release is

A git tag `v*` starts `.github/workflows/release.yml`, which produces exactly three
files on a GitHub Release:

| asset | built on | covers |
| --- | --- | --- |
| `alohajet-macos-universal.tar.gz` | `macos-15` | Apple Silicon and Intel |
| `alohajet-linux-x86_64.tar.gz` | `swift:6.2.3-noble` on `ubuntu-24.04` | x86_64 |
| `SHA256SUMS` | the publish job | both, in `sha256sum -c` format |

One universal Mach-O rather than two macOS assets: `swift build -c release --arch
arm64 --arch x86_64` produces a binary carrying both slices (verified —
`Mach-O universal binary with 2 architectures`), which costs one runner instead of
two and does not depend on GitHub keeping an Intel macOS image around.

Each tarball holds the binary plus `LICENSE`, `README.md` and
`SECURITY.md` — the binary drives a browser holding the user's logged-in sessions,
and the disclosure belongs next to it, not two links away.

Every job smoke-tests the binary it just built (`alohajet --help`) before packing it.
A tarball whose binary cannot start is worse than no release.

`linux-arm64` is not built — there is no ARM Linux runner in the matrix. The
installer says so and points at the source build rather than 404ing. Add it when a
runner exists.

## Cutting one

```sh
git tag v0.2.0 && git push origin v0.2.0
```

or Actions → **release** → Run workflow with an explicit version.

## Signing: what is not done, and what that costs

**Nothing is signed and nothing is notarized.** A shipped desktop app does both
— it ships a GUI app bundle from a self-hosted macOS runner holding a Developer ID,
and `scripts/package.sh` there imports a `.p12` into a throwaway keychain and calls
`notarytool`. This package is a single command-line binary with no bundle, so it runs
on GitHub-hosted runners with no secrets at all.

The consequence is precise and worth stating rather than discovering:

- A binary fetched with **curl** carries no `com.apple.quarantine` attribute, so
  Gatekeeper does not gate it. This is why the install script uses curl and why it is
  the documented path.
- A tarball downloaded through a **browser** is quarantined, and macOS will refuse
  it. The user's escape is `xattr -dr com.apple.quarantine ./alohajet`, which is a
  bad thing to teach and a good reason to prefer the script.

Adding signing later means a Developer ID secret and a notarization step in
`release.yml`, which is where both would be added.

## Why no Homebrew formula

A formula needs a tap repository to live in, one that has to be updated on every
release with the new version and both macOS checksums, and it covers only macOS —
which is half of what this package supports. The install script is one file in this
repository, verifies its download against the release's own `SHA256SUMS`, and works
on both platforms. Write the formula when someone asks for `brew install`; until
then it is a second release channel to keep in sync for no new capability.

## Verifying a download by hand

```sh
curl -fsSLO https://github.com/AlohaBrowser/alohajet-cli/releases/latest/download/alohajet-macos-universal.tar.gz
curl -fsSLO https://github.com/AlohaBrowser/alohajet-cli/releases/latest/download/SHA256SUMS
shasum -a 256 -c SHA256SUMS --ignore-missing
```
