# Releasing

What a stranger types:

```sh
curl -fsSL https://raw.githubusercontent.com/AlohaBrowser/alohajet/main/scripts/install.sh | sh
alohajet --help
```

Or, with a toolchain already installed and no trust in install scripts:

```sh
git clone https://github.com/AlohaBrowser/alohajet && cd alohajet
swift build -c release --product alohajet
.build/release/alohajet --help
```

Both are one command. There is no third option and no package manager to add — see
"Why no Homebrew formula" below.

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

Each tarball holds the binary plus `LICENSE`, `NOTICE`, `README.md` and
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
curl -fsSLO https://github.com/AlohaBrowser/alohajet/releases/latest/download/alohajet-macos-arm64.tar.gz
curl -fsSLO https://github.com/AlohaBrowser/alohajet/releases/latest/download/SHA256SUMS
shasum -a 256 -c SHA256SUMS --ignore-missing
```
