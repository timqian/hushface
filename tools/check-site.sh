#!/usr/bin/env bash
# Diagnose the public install endpoint, host by host.
#
#   tools/check-site.sh                          # checks https://hushface.com
#   tools/check-site.sh https://hushface.timqian.workers.dev
#
# Answers one question: is it DNS, the certificate, the worker route, or the
# bucket that is broken?
set -uo pipefail

BASE="${1:-https://hushface.com}"
HOST="${BASE#*://}"; HOST="${HOST%%/*}"

FAILED=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad()  { FAILED=1; printf '  \033[31m✗\033[0m %s\n' "$*"; }
note() { printf '    \033[2m%s\033[0m\n' "$*"; }
hint() { printf '  \033[33m→\033[0m %s\n' "$*"; }

printf '\033[1mchecking %s\033[0m\n\n' "$BASE"

# 1. DNS ----------------------------------------------------------------------
ips="$(dig +short "$HOST" A 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')"
if [[ -z "${ips// /}" ]]; then
  bad "no A record for $HOST"
  hint "the custom domain was never attached: cd cloudflare && npx wrangler deploy"
  hint "(a route with zone_name does not create DNS; use custom_domain = true)"
  exit 1
fi
ok "DNS $HOST → $ips"
case "$HOST" in
  *.workers.dev) : ;;                      # not in your DNS, nothing to judge
  *)
    if printf '%s' "$ips" | grep -qE '^(198\.1[89]\.)'; then
      note "resolved through a local proxy — the address says nothing about Cloudflare"
    elif printf '%s' "$ips" | grep -qE '^(104\.|172\.6[4-9]\.|172\.7[0-1]\.|188\.114\.|197\.234\.|198\.41\.|162\.158\.|173\.245\.|103\.21\.|103\.22\.|103\.31\.)'; then
      ok "resolves to Cloudflare (proxied)"
    else
      bad "resolves outside Cloudflare — an old A/page record is winning"
      hint "delete the existing $HOST record in the Cloudflare DNS tab, then redeploy"
    fi ;;
esac

# 2. TLS + worker -------------------------------------------------------------
hdr="$(curl -sS -o /dev/null -D - -m 15 "$BASE/" 2>&1)"
code="$(printf '%s' "$hdr" | awk '/^HTTP/{c=$2} END{print c}')"
body="$(curl -sS -m 15 "$BASE/" 2>/dev/null | head -c 400 | tr '\n' ' ')"

case "$code" in
  200) ok "https://$HOST/ → 200" ;;
  "")
    bad "no HTTP response from $HOST"
    if printf '%s' "$hdr" | grep -qi "SSL\|certificate"; then
      hint "TLS failed: the custom domain has no certificate yet, or the DNS record does not exist"
      hint "cd cloudflare && npx wrangler deploy   (custom_domain = true creates both)"
    else
      hint "nothing is answering: check the DNS record and the worker route"
    fi ;;
  502|520|521|525|526)
    bad "https://$HOST/ → $code"
    note "server: $(printf '%s' "$hdr" | tr -d '\r' | awk 'tolower($1)=="server:"{print $2}')  cf-ray: $(printf '%s' "$hdr" | tr -d '\r' | awk 'tolower($1)=="cf-ray:"{print $2}')"
    note "body: ${body:-<empty>}"
    printf '\n'
    printf '  a 502 on a worker hostname means one of two things:\n\n'
    printf '    a) the request never reached the worker — Cloudflare proxied it to an\n'
    printf '       origin (Pages project, tunnel, an old A record, a Page Rule)\n'
    printf '       → Workers & Pages → hushface → Settings → Domains & Routes:\n'
    printf '         hushface.com must be listed there as an active custom domain\n'
    printf '       → DNS tab: remove any hushface.com A/AAAA/CNAME pointing at an origin\n'
    printf '       → delete a Pages custom domain / Redirect or Page Rule on the apex\n\n'
    printf '    b) the worker threw — Cloudflare shows "Error 1101 / Worker threw exception".\n'
    printf '       The current worker catches everything, so this means an old deployment:\n'
    printf '         cd cloudflare && npx wrangler deploy\n'
    printf '         npx wrangler tail        # while reloading the URL\n\n'
    printf '  quick check: does the workers.dev host answer on the same path?\n'
    printf '    curl -sI https://hushface.timqian.workers.dev/ | head -1\n'
    printf '  if yes, it is (a): the apex is not wired to the worker.\n' ;;
  522|523|524) bad "https://$HOST/ → $code (Cloudflare cannot reach the worker)"; hint "npx wrangler deployments list" ;;
  1016|404) bad "https://$HOST/ → $code"; hint "worker is not routed to this hostname (cd cloudflare && npx wrangler deploy)" ;;
  *) bad "https://$HOST/ → $code"; note "body: ${body:-<empty>}" ;;
esac

# 3. the landing page should carry the one-liner ------------------------------
if curl -sf -m 15 "$BASE/" | grep -q "install.sh"; then
  ok "landing page carries the install command"
else
  bad "landing page missing (worker not serving / yet)"
fi

# 4. install.sh ---------------------------------------------------------------
sh_code="$(curl -s -o /dev/null -m 15 -w '%{http_code}' "$BASE/install.sh")"
if [[ "$sh_code" == "200" ]]; then
  if curl -sf -m 20 "$BASE/install.sh" | head -1 | grep -q '^#!/bin/sh'; then
    ok "/install.sh serves the script"
  else
    bad "/install.sh returns something that is not the script"
  fi
elif [[ "$sh_code" == 5* ]]; then
  bad "/install.sh → $sh_code"
  hint "server side, not the bucket — see the diagnosis above"
else
  bad "/install.sh → $sh_code"
  hint "the bucket is empty or the key is wrong: tools/publish-cf.sh"
fi

# 5. artifact: HEAD, a byte range, and the published checksum ------------------
art="$BASE/hushface-macos-arm64.sh"
size="$(curl -sI -m 20 "$art" | tr -d '\r' | awk 'tolower($1)=="content-length:"{print $2}')"
if [[ -n "${size:-}" && "$size" -gt 1000000 ]]; then
  ok "artifact present ($((size / 1048576)) MB)"
else
  bad "artifact missing or implausibly small (${size:-none} bytes)"
  hint "tools/release.sh && tools/publish-cf.sh"
fi
range_code="$(curl -s -o /dev/null -m 20 -r 0-99 -w '%{http_code}' "$art")"
[[ "$range_code" == "206" ]] && ok "range requests work (206)" || bad "range request → $range_code (needs to be 206)"

want="$(curl -sf -m 20 "$BASE/hushface-macos-arm64.sh.sha256" 2>/dev/null | cut -d' ' -f1)"
if [[ -n "${want:-}" ]]; then
  got="$(curl -sf -m 300 "$art" | shasum -a 256 | cut -d' ' -f1)"
  [[ "$got" == "$want" ]] && ok "checksum matches the served bytes" || bad "checksum mismatch"
else
  bad "no .sha256 published"
fi

if [[ "$FAILED" == "1" ]]; then
  printf '\n'
  if [[ "$HOST" == "hushface.com" ]]; then
    printf 'if the workers.dev host works but this one does not, the apex is not wired:\n'
    printf '  cd cloudflare && npx wrangler deploy    (routes must sit above [[r2_buckets]])\n\n'
    printf 'this always works as a drop-in base URL:\n'
    printf '  HUSHFACE_RELEASES=https://hushface.timqian.workers.dev/releases/latest sh install.sh\n'
  fi
fi
