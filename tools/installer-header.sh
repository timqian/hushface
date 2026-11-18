#!/bin/sh
# hushface @VERSION@ — a local coding agent in one file.
#
#   sh hushface-@VERSION@-macos-arm64.sh              install, then start hushface
#   sh hushface-@VERSION@-macos-arm64.sh -p "hi"      install, then pass args to pi
#   sh hushface-@VERSION@-macos-arm64.sh --no-run     install only
#   sh hushface-@VERSION@-macos-arm64.sh --uninstall  remove the app and runtime
#
# Installs the app + runtime (Node @NODE@, pi @PI@, @LLAMA@) into
#   ${HUSHFACE_DIR:-$HOME/.local/share/hushface}
# and links $HOME/.local/bin/hushface. The model weights (~22 GB) are downloaded
# by hushface itself on first run, resumably and checksum-verified.
set -eu

VERSION="@VERSION@"
PAYLOAD_SHA256="@PAYLOAD_SHA256@"
PAYLOAD_BYTES="@PAYLOAD_BYTES@"
MARKER="__HUSHFACE_PAYLOAD_BELOW__"
DEST="${HUSHFACE_DIR:-$HOME/.local/share/hushface}"
BIN_DIR="${HUSHFACE_BIN_DIR:-$HOME/.local/bin}"

say()  { printf '%s\n' "$*"; }
err()  { printf 'hushface: %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "macOS only"
[ "$(uname -m)" = "arm64" ] || die "Apple Silicon only (this build is darwin-arm64)"

if [ "${1:-}" = "--uninstall" ]; then
  rm -rf "$DEST"
  rm -f "$BIN_DIR/hushface"
  say "removed $DEST and $BIN_DIR/hushface"
  say "model weights and config stay in ~/.hushface (hushface uninstall removes them)"
  exit 0
fi

# --- locate the payload inside this file -------------------------------------
skip=$(awk "/^$MARKER\$/{print NR+1; exit}" "$0" 2>/dev/null || true)
[ -n "${skip:-}" ] || die "this file looks truncated (payload marker missing)"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/hushface.XXXXXX")"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT INT TERM

tail -n "+$skip" "$0" >"$tmp/payload.tar.gz" || die "cannot read the payload"
got="$(shasum -a 256 "$tmp/payload.tar.gz" | cut -d' ' -f1)"
[ "$got" = "$PAYLOAD_SHA256" ] || die "payload checksum mismatch (download again)"

if [ "${1:-}" = "--check" ]; then
  say "hushface $VERSION: payload ok ($((PAYLOAD_BYTES / 1048576)) MB)"
  exit 0
fi

# --- install -----------------------------------------------------------------
if [ -f "$DEST/runtime/manifest.json" ] && [ -f "$DEST/.bundled" ]; then
  have="$(sed -n 's/.*"hushface": "\([^"]*\)".*/\1/p' "$DEST/runtime/manifest.json" | head -1)"
  if [ "$have" = "$VERSION" ]; then
    say "hushface $VERSION already installed in $DEST"
  else
    say "updating hushface $have → $VERSION"
  fi
fi

tar -xzf "$tmp/payload.tar.gz" -C "$tmp" || die "cannot unpack the payload"

mkdir -p "$(dirname "$DEST")"
rm -rf "$DEST.old"
[ -d "$DEST" ] && mv "$DEST" "$DEST.old"
mv "$tmp/hushface" "$DEST"
rm -rf "$DEST.old"

# anything unpacked from a download carries a quarantine flag; the bundled
# binaries are ad-hoc signed, so clear it or Gatekeeper refuses to run them
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

mkdir -p "$BIN_DIR"
ln -sf "$DEST/bin/hushface" "$BIN_DIR/hushface"
say "installed hushface $VERSION → $DEST"
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) say ""
     say "add this to ~/.zshrc, then open a new terminal:"
     say "  export PATH=\"$BIN_DIR:\$PATH\"" ;;
esac
say ""

if [ "${1:-}" = "--no-run" ]; then
  say "next: hushface"
  exit 0
fi

exec "$DEST/bin/hushface" "$@"
