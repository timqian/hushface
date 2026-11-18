#!/bin/sh
# hushface — one-line install.
#
#   curl -LsSf https://hushface.com/install.sh | sh
#
# Downloads the released single-file build (app + Node + pi + llama.cpp, ~73 MB),
# verifies its checksum, installs it into ~/.local/share/hushface, links
# ~/.local/bin/hushface, and then hands over to `hushface`, which checks the
# machine and downloads the model on first run.
#
#   ... | sh -s -- --no-run     install only, do not start
#   ... | sh -s -- --yes        do not ask for confirmation (scripts, CI)
#
# Env: HUSHFACE_RELEASES (base URL, default https://hushface.com/releases/latest),
#      HUSHFACE_NO_RUN=1,
#      HUSHFACE_DIR (install location), HUSHFACE_BIN_DIR, HUSHFACE_ASSET.
set -eu

RELEASES="${HUSHFACE_RELEASES:-https://hushface.com/releases/latest}"
ASSET="${HUSHFACE_ASSET:-hushface-macos-arm64.sh}"
DEST="${HUSHFACE_DIR:-$HOME/.local/share/hushface}"
NO_RUN="${HUSHFACE_NO_RUN:-0}"

for arg in "$@"; do
  case "$arg" in
    --no-run) NO_RUN=1 ;;
    -h|--help)
      sed -n '2,15p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//' || true
      exit 0 ;;
    *) : ;;
  esac
done

say() { printf '%s\n' "$*"; }
err() { printf '\033[31m✗\033[0m %s\n' "$*" >&2; }
die() { err "$1"; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "hushface runs on macOS only (for now)"
[ "$(uname -m)" = "arm64" ] || die "hushface needs Apple Silicon (M1 or newer)"
command -v curl >/dev/null 2>&1 || die "curl is required"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/hushface.XXXXXX")"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT INT TERM

say "downloading hushface…"
curl -fL --retry 3 --connect-timeout 20 --progress-bar \
  "$RELEASES/$ASSET" -o "$tmp/$ASSET" || die "download failed: $RELEASES/$ASSET"

if curl -fsL --connect-timeout 20 "$RELEASES/$ASSET.sha256" -o "$tmp/$ASSET.sha256" 2>/dev/null; then
  want="$(cut -d' ' -f1 <"$tmp/$ASSET.sha256")"
  got="$(shasum -a 256 "$tmp/$ASSET" | cut -d' ' -f1)"
  [ "$want" = "$got" ] || die "checksum mismatch — download again"
  say "checksum ok"
else
  say "no published checksum, skipping verification"
fi

say "installing into $DEST"
sh "$tmp/$ASSET" --no-run "$@" || die "installer failed"

if [ "$NO_RUN" = "1" ]; then
  say ""
  say "installed. start it with:  hushface"
  say "  (first run downloads the ~22 GB model, resumably)"
  exit 0
fi

# `curl | sh` feeds this script on stdin, so stdin must not be re-pointed here —
# that would make the shell read the rest of the script from the terminal.
# Redirect it for the child process only, and only if a terminal exists.
if (exec </dev/tty) 2>/dev/null; then
  exec "$DEST/bin/hushface" "$@" </dev/tty
fi

exec "$DEST/bin/hushface" "$@"
