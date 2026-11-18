#!/usr/bin/env bash
# Build the single-file installer: dist/hushface-<ver>-macos-arm64.sh
#
#   tools/build-payload.sh [--from-local]
#
# It assembles a runtime (Node + pi + llama.cpp, everything the CLI needs) plus
# the hushface tree, then wraps the whole thing in one self-extracting file.
# The 22 GB of weights are *not* in here — they are downloaded on first run,
# from a mirror near the user, with progress and checksum verification.
#
# Needs network on the *build* machine (nodejs.org, GitHub releases, npm) and
# `shasum`, `tar`, `unzip`, `node`, `npm`. The artifact itself needs nothing
# but /bin/sh, tar and gunzip — all present on a stock macOS.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

HUSHFACE_VERSION="$(sed -n 's/^HUSHFACE_VERSION="\(.*\)"/\1/p' bin/hushface)"
NODE_VERSION="${NODE_VERSION:-26.7.0}"
PI_VERSION="${PI_VERSION:-}"
LLAMA_URL="${LLAMA_URL:-}"
FROM_LOCAL=0
for arg in "$@"; do
  case "$arg" in
    --from-local) FROM_LOCAL=1 ;;
    *) printf 'build: unknown option %s\n' "$arg" >&2; exit 2 ;;
  esac
done

BUILD="$ROOT/build"
CACHE="$BUILD/cache"
PAYLOAD="$BUILD/payload/hushface"
DIST="$ROOT/dist"
rm -rf "$BUILD/payload"
mkdir -p "$CACHE" "$PAYLOAD/runtime" "$DIST"

say() { printf '\033[1m%s\033[0m\n' "$*"; }
step() { printf '  → %s\n' "$*"; }
die() { printf 'build: %s\n' "$*" >&2; exit 1; }

sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
fetch() { # url dest
  [[ -s "$2" ]] && { step "cached $(basename "$2")"; return 0; }
  step "downloading $(basename "$2")"
  curl -fL --retry 3 --progress-bar "$1" -o "$2.part" && mv "$2.part" "$2"
}

# ---------------------------------------------------------------- runtime -----
say "node $NODE_VERSION"
NODE_TGZ="$CACHE/node-v$NODE_VERSION-darwin-arm64.tar.gz"
fetch "https://nodejs.org/dist/v$NODE_VERSION/node-v$NODE_VERSION-darwin-arm64.tar.gz" "$NODE_TGZ"
rm -rf "$CACHE/node" && mkdir -p "$CACHE/node"
tar -xzf "$NODE_TGZ" -C "$CACHE/node" --strip-components=1
mkdir -p "$PAYLOAD/runtime/node/bin"
cp "$CACHE/node/bin/node" "$PAYLOAD/runtime/node/bin/node"
cp "$CACHE/node/LICENSE" "$PAYLOAD/runtime/node/LICENSE" 2>/dev/null || true
"$PAYLOAD/runtime/node/bin/node" -v

say "llama.cpp"
[[ -z "$LLAMA_URL" ]] && LLAMA_URL="$(node lib/hub.mjs llama-release)"
LLAMA_ARCHIVE="$CACHE/$(basename "$LLAMA_URL")"
fetch "$LLAMA_URL" "$LLAMA_ARCHIVE"
rm -rf "$CACHE/llama" && mkdir -p "$CACHE/llama"
case "$LLAMA_URL" in
  *.tar.gz|*.tgz) tar -xzf "$LLAMA_ARCHIVE" -C "$CACHE/llama" ;;
  *)              unzip -q -o "$LLAMA_ARCHIVE" -d "$CACHE/llama" ;;
esac
SERVER_BIN="$(find "$CACHE/llama" -name llama-server -type f | head -1)"
[[ -n "$SERVER_BIN" ]] || die "llama-server not found in $LLAMA_ARCHIVE"
mkdir -p "$PAYLOAD/runtime/llama/bin"
cp "$SERVER_BIN" "$PAYLOAD/runtime/llama/bin/"
# dylibs sit next to the binary in the release zip; keep them together
for lib in "$(dirname "$SERVER_BIN")"/*.dylib; do
  [[ -f "$lib" ]] && cp "$lib" "$PAYLOAD/runtime/llama/bin/"
done
chmod +x "$PAYLOAD/runtime/llama/bin/llama-server"
LLAMA_TAG="$(basename "$LLAMA_URL" | sed -e 's/\.tar\.gz$//' -e 's/\.zip$//' -e 's/^llama-//')"

say "pi"
if [[ -z "$PI_VERSION" ]]; then
  PI_VERSION="$(curl -sf https://registry.npmjs.org/@earendil-works/pi-coding-agent/latest \
    | node -e 'let s="";process.stdin.on("data",c=>s+=c).on("end",()=>process.stdout.write(JSON.parse(s).version))')"
fi
step "pi $PI_VERSION"
LOCAL_PI="$(npm root -g 2>/dev/null)/@earendil-works/pi-coding-agent"
mkdir -p "$PAYLOAD/runtime/pi"
if [[ "$FROM_LOCAL" == "1" && -d "$LOCAL_PI" ]]; then
  step "using local npm install at $LOCAL_PI"
  cp -R "$LOCAL_PI/dist" "$PAYLOAD/runtime/pi/dist"
  cp "$LOCAL_PI/package.json" "$PAYLOAD/runtime/pi/"
  PI_VERSION="$(node -e "process.stdout.write(require('$LOCAL_PI/package.json').version)")"
else
  TGZ="$CACHE/pi-$PI_VERSION.tgz"
  fetch "https://registry.npmjs.org/@earendil-works/pi-coding-agent/-/pi-coding-agent-$PI_VERSION.tgz" "$TGZ"
  rm -rf "$CACHE/pi" && mkdir -p "$CACHE/pi"
  tar -xzf "$TGZ" -C "$CACHE/pi"
  cp -R "$CACHE/pi/package/dist" "$PAYLOAD/runtime/pi/dist"
  cp "$CACHE/pi/package/package.json" "$PAYLOAD/runtime/pi/"
fi
# the bundled cli.js has no node_modules dependency
[[ -f "$PAYLOAD/runtime/pi/dist/bundle/cli.js" ]] || die "pi bundle missing"

mkdir -p "$PAYLOAD/runtime/bin"
cat >"$PAYLOAD/runtime/bin/pi" <<'EOF'
#!/bin/sh
# pi, backed by the Node.js in this runtime
self="$0"
while [ -L "$self" ]; do
  dir=$(CDPATH= cd -- "$(dirname -- "$self")" && pwd)
  self=$(readlink "$self")
  case $self in /*) ;; *) self="$dir/$self" ;; esac
done
here=$(CDPATH= cd -- "$(dirname -- "$self")/.." && pwd)
exec "$here/node/bin/node" "$here/pi/dist/bundle/cli.js" "$@"
EOF
chmod +x "$PAYLOAD/runtime/bin/pi" "$PAYLOAD/runtime/node/bin/node"

# ------------------------------------------------------------------- app ------
say "hushface $HUSHFACE_VERSION"
cp -R "$ROOT/bin" "$ROOT/lib" "$PAYLOAD/"
cp "$ROOT/README.md" "$PAYLOAD/" 2>/dev/null || true
chmod +x "$PAYLOAD/bin/hushface"
: >"$PAYLOAD/.bundled"

node - "$PAYLOAD/runtime/manifest.json" "$HUSHFACE_VERSION" "$NODE_VERSION" "$PI_VERSION" "$LLAMA_TAG" <<'EOF'
const fs = require("node:fs");
const [file, hushface, node, pi, llama] = process.argv.slice(2);
fs.writeFileSync(file, JSON.stringify({
  hushface,
  node,
  pi,
  llama: { server: llama },
  platform: "darwin-arm64",
  built: new Date().toISOString(),
}, null, 2) + "\n");
EOF

# ------------------------------------------------------------------ wrap ------
say "packing"
TARBALL="$BUILD/payload.tar.gz"
tar --no-xattrs -czf "$TARBALL" -C "$BUILD/payload" hushface
PAYLOAD_SHA="$(sha "$TARBALL")"
PAYLOAD_SIZE="$(stat -f%z "$TARBALL")"

printf '%s' "$PAYLOAD_SHA" >"$BUILD/payload.sha256"
cat >"$BUILD/versions.env" <<EOF
HUSHFACE_VERSION=$HUSHFACE_VERSION
NODE_VERSION=$NODE_VERSION
PI_VERSION=$PI_VERSION
LLAMA_TAG=$LLAMA_TAG
PAYLOAD_SHA=$PAYLOAD_SHA
PAYLOAD_SIZE=$PAYLOAD_SIZE
EOF

OUT="$DIST/hushface-$HUSHFACE_VERSION-macos-arm64.sh"

{
  cat "$ROOT/tools/installer-header.sh"
} >"$OUT.tmp"

sed \
  -e "s|@VERSION@|$HUSHFACE_VERSION|g" \
  -e "s|@PAYLOAD_SHA256@|$PAYLOAD_SHA|g" \
  -e "s|@PAYLOAD_BYTES@|$PAYLOAD_SIZE|g" \
  -e "s|@NODE@|$NODE_VERSION|g" \
  -e "s|@PI@|$PI_VERSION|g" \
  -e "s|@LLAMA@|$LLAMA_TAG|g" \
  "$ROOT/tools/installer-header.sh" >"$OUT.tmp"
printf '__HUSHFACE_PAYLOAD_BELOW__\n' >>"$OUT.tmp"
cat "$TARBALL" >>"$OUT.tmp"
mv "$OUT.tmp" "$OUT"
chmod +x "$OUT"

say "done"
printf '  %s\n' "$OUT"
printf '  %s (%s payload, node %s, pi %s, %s)\n\n' \
  "$(du -h "$OUT" | cut -f1)" "$(printf '%s' "$PAYLOAD_SIZE" | awk '{printf "%.0f MB", $1/1048576}')" \
  "$NODE_VERSION" "$PI_VERSION" "$LLAMA_TAG"
printf '  test: HOME=$(mktemp -d) %s --dry-run --yes\n\n' "$OUT"
