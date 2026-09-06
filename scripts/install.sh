#!/bin/sh
# alohajet installer.
#
#   curl -fsSL https://raw.githubusercontent.com/AlohaBrowser/alohajet/main/scripts/install.sh | sh
#
# Downloads the release tarball for this machine, VERIFIES it against the release's
# SHA256SUMS, and puts `alohajet` in ~/.local/bin. Not /usr/local/bin: that is
# root-owned on a clean macOS, and an installer that needs a password to drop one
# binary is an installer people abandon halfway.
#
# Override with: ALOHAJET_VERSION=v0.2.0 ALOHAJET_PREFIX=/usr/local/bin sh install.sh
set -eu

REPO="${ALOHAJET_REPO:-AlohaBrowser/alohajet}"
PREFIX="${ALOHAJET_PREFIX:-$HOME/.local/bin}"
VERSION="${ALOHAJET_VERSION:-latest}"

case "$(uname -s)" in
    Darwin) os=macos ;;
    Linux)  os=linux ;;
    *) echo "alohajet: unsupported OS $(uname -s). Build from source: swift build -c release" >&2; exit 1 ;;
esac
case "$(uname -m)" in
    arm64|aarch64) arch=arm64 ;;
    x86_64|amd64)  arch=x86_64 ;;
    *) echo "alohajet: unsupported architecture $(uname -m)." >&2; exit 1 ;;
esac

if [ "$os" = macos ]; then
    # One universal Mach-O covers both Apple architectures.
    asset="alohajet-macos-universal.tar.gz"
elif [ "$arch" = x86_64 ]; then
    asset="alohajet-linux-x86_64.tar.gz"
else
    # No linux-arm64 runner, so no linux-arm64 asset. Say so instead of 404ing.
    echo "alohajet: no linux-$arch release yet." >&2
    echo "  git clone https://github.com/$REPO && cd alohajet && swift build -c release" >&2
    exit 1
fi
if [ "$VERSION" = latest ]; then
    base="https://github.com/$REPO/releases/latest/download"
else
    base="https://github.com/$REPO/releases/download/$VERSION"
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

echo "alohajet: downloading $asset"
curl -fsSL "$base/$asset"     -o "$tmp/$asset"
curl -fsSL "$base/SHA256SUMS" -o "$tmp/SHA256SUMS"

# Verify BEFORE unpacking. `sha256sum` on Linux, `shasum -a 256` on macOS; the
# SHA256SUMS format is the same for both. A release whose checksum does not match is
# the one case where stopping loudly is the whole point of the script.
echo "alohajet: verifying checksum"
( cd "$tmp" && grep " \*\{0,1\}$asset\$" SHA256SUMS > expected.txt \
  && { command -v sha256sum >/dev/null 2>&1 \
        && sha256sum -c expected.txt \
        || shasum -a 256 -c expected.txt; } ) \
  || { echo "alohajet: CHECKSUM MISMATCH for $asset — not installing." >&2; exit 1; }

tar -xzf "$tmp/$asset" -C "$tmp"
binary="$(find "$tmp" -type f -name alohajet -perm -u+x | head -n 1)"
[ -n "$binary" ] || { echo "alohajet: the tarball contained no alohajet binary." >&2; exit 1; }

mkdir -p "$PREFIX"
install -m 0755 "$binary" "$PREFIX/alohajet" 2>/dev/null || {
    cp "$binary" "$PREFIX/alohajet" && chmod 0755 "$PREFIX/alohajet"
}

echo "alohajet: installed $PREFIX/alohajet"
"$PREFIX/alohajet" --help > /dev/null && echo "alohajet: it runs."

case ":$PATH:" in
    *":$PREFIX:"*) ;;
    *) echo "alohajet: $PREFIX is not on your PATH. Add it:"
       echo "    export PATH=\"$PREFIX:\$PATH\"" ;;
esac
