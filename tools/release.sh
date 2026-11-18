#!/usr/bin/env bash
# Cut a release: build the single-file artifact, give it the stable name the
# one-line installer expects, and write the checksum.
#
#   tools/release.sh                 # current HUSHFACE_VERSION
#   tools/release.sh --version 0.1.1 # bump, build, and tag-ready
#   tools/release.sh --from-local    # take pi from the local npm install
#
# Output in dist/release/:
#   hushface-macos-arm64.sh            stable alias (what install.sh fetches)
#   hushface-macos-arm64.sh.sha256     checksum consumed by install.sh
#   hushface-<ver>-macos-arm64.sh      versioned copy for the release page
#   install.sh                         the bootstrap users pipe into sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

FROM_LOCAL=""
BUMP=""
while (( $# )); do
  case "$1" in
    --from-local) FROM_LOCAL="--from-local"; shift ;;
    --version) BUMP="$2"; shift 2 ;;
    *) printf 'release: unknown option %s\n' "$1" >&2; exit 2 ;;
  esac
done

if [[ -n "$BUMP" ]]; then
  /usr/bin/sed -i '' "s/^HUSHFACE_VERSION=\".*\"/HUSHFACE_VERSION=\"$BUMP\"/" bin/hushface
  printf 'version → %s\n' "$BUMP"
fi

VERSION="$(sed -n 's/^HUSHFACE_VERSION="\(.*\)"/\1/p' bin/hushface)"
echo "== building hushface $VERSION"
./tools/build-payload.sh $FROM_LOCAL

RELDIR="$ROOT/dist/release"
rm -rf "$RELDIR"
mkdir -p "$RELDIR"
cp "dist/hushface-$VERSION-macos-arm64.sh" "$RELDIR/hushface-macos-arm64.sh"
cp "dist/hushface-$VERSION-macos-arm64.sh" "$RELDIR/hushface-$VERSION-macos-arm64.sh"
cp install.sh "$RELDIR/install.sh"
(cd "$RELDIR" && shasum -a 256 hushface-macos-arm64.sh >hushface-macos-arm64.sh.sha256 \
  && shasum -a 256 "hushface-$VERSION-macos-arm64.sh" >"hushface-$VERSION-macos-arm64.sh.sha256")

echo
echo "== release dir: $RELDIR"
ls -1sh "$RELDIR" | sed 's/^/   /'
echo
echo "== publish (edit the repo slug first):"
cat <<CMD
   gh release create v$VERSION \\
     --title "hushface $VERSION" \\
     --notes "Local coding agent: pi + Qwen3.8-27B + pi adapter, one file." \\
     "$RELDIR"/hushface-macos-arm64.sh \\
     "$RELDIR"/hushface-macos-arm64.sh.sha256 \\
     "$RELDIR"/hushface-$VERSION-macos-arm64.sh \\
     "$RELDIR"/install.sh
CMD
