#!/usr/bin/env bash
# Upload a built release to the hushface.com R2 bucket.
#
#   tools/publish-cf.sh              # upload dist/release/ to v<ver>/ and latest/
#   tools/publish-cf.sh --dry-run    # print the commands only, needs nothing installed
#   tools/publish-cf.sh --verify     # extra HTTP check after uploading (default on)
#
# Works with wrangler installed globally or not: it uses `wrangler` when it is on
# PATH, otherwise `npx --yes wrangler`. Override with WRANGLER="npx wrangler".
#
# With more than one account membership, export CLOUDFLARE_ACCOUNT_ID for the
# account that owns hushface.com (see `wrangler whoami`).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BUCKET="${HUSHFACE_R2_BUCKET:-hushface-releases}"
BASE="${HUSHFACE_BASE:-https://hushface.com}"
DRY_RUN=0
VERIFY=1
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --no-verify) VERIFY=0 ;;
    *) printf 'publish-cf: unknown option %s\n' "$arg" >&2; exit 2 ;;
  esac
done

VERSION="$(sed -n 's/^HUSHFACE_VERSION="\(.*\)"/\1/p' bin/hushface)"
SRC="$ROOT/dist/release"
[[ -d "$SRC" ]] || { printf 'no %s — run tools/release.sh first\n' "$SRC" >&2; exit 1; }

# --- find wrangler ------------------------------------------------------------
# shellcheck disable=SC2206
if [[ -n "${WRANGLER:-}" ]]; then
  WR=( $WRANGLER )
elif command -v wrangler >/dev/null 2>&1; then
  WR=( wrangler )
elif command -v npx >/dev/null 2>&1; then
  WR=( npx --yes wrangler )
else
  printf 'neither wrangler nor npx found — npm i -g wrangler\n' >&2
  exit 1
fi

content_type() {
  case "$1" in
    *.sha256) printf 'text/plain' ;;
    *.sh)     printf 'text/x-shellscript' ;;
    *)        printf 'application/octet-stream' ;;
  esac
}

# `r2 object put` writes remotely by default in wrangler 4+; --remote keeps
# wrangler 3 honest and is harmless in 4.
put() { # file key
  local file="$1" key="$2" ct
  ct="$(content_type "$file")"
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '%s r2 object put %s/%s --file %s --content-type %s --remote\n' \
      "${WR[*]}" "$BUCKET" "$key" "${file#"$ROOT"/}" "$ct"
    return 0
  fi
  printf '  → %s\n' "$key"
  if ! "${WR[@]}" r2 object put "$BUCKET/$key" --file "$file" --content-type "$ct" --remote 2>&1 \
      | grep -vE '^\s*$' | tail -1 | sed 's/^/    /'; then
    printf 'upload failed for %s\n' "$key" >&2
    return 1
  fi
  # wrangler prints errors to stdout with exit code 0 in some versions
  "${WR[@]}" r2 object get "$BUCKET/$key" --remote --pipe >/dev/null 2>&1 || {
    printf '  ! %s is not readable from the bucket\n' "$key" >&2
    return 1
  }
}

echo "publishing hushface $VERSION to r2://$BUCKET using ${WR[*]}"
files=("$SRC"/*)
for file in "${files[@]}"; do
  name="$(basename "$file")"
  put "$file" "v$VERSION/$name"
  put "$file" "latest/$name"
done

if [[ "$DRY_RUN" == "1" ]]; then
  echo
  echo "(dry run — nothing uploaded)"
  exit 0
fi

if [[ "$VERIFY" == "1" ]]; then
  echo
  echo "verifying $BASE"
  code="$(curl -s -o /dev/null -m 20 -w '%{http_code}' "$BASE/hushface-macos-arm64.sh" || true)"
  if [[ "$code" == "200" ]]; then
    echo "  ✓ $BASE/hushface-macos-arm64.sh serves 200"
    want="$(curl -sf -m 20 "$BASE/hushface-macos-arm64.sh.sha256" | cut -d' ' -f1 || true)"
    got="$(shasum -a 256 "dist/release/hushface-macos-arm64.sh" | cut -d' ' -f1)"
    if [[ -n "$want" && "$want" == "$got" ]]; then
      echo "  ✓ published checksum matches the local build"
    else
      echo "  ! checksum served at $BASE does not match the local build" >&2
    fi
    echo "  ✓ try it: curl -LsSf $BASE/install.sh | sh -- --no-run"
  else
    echo "  ! $BASE/hushface-macos-arm64.sh → ${code:-no response}" >&2
    echo "    DNS/route problem, not an upload problem: tools/check-site.sh" >&2
    echo "    the workers.dev host still works:" >&2
    echo "    HUSHFACE_RELEASES=https://hushface.timqian.workers.dev/releases/latest" >&2
  fi
fi
