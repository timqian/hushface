#!/usr/bin/env bash
# hushface test suite. Runs offline: no model downloads, no network required.
#
#   tests/run.sh            # everything
#   tests/run.sh download   # only tests whose name matches "download"
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HF="$ROOT/bin/hushface"
FIX="$ROOT/tests/fixtures"
FILTER="${1:-}"

PASS=0
FAIL=0
FAILED=""
TMP="$(mktemp -d "${TMPDIR:-/tmp}/hushface-test.XXXXXX")"
kill_fixtures() {
  pkill -f "fake-llama-server.mjs" 2>/dev/null
  pkill -f "fixtures/fileserver.mjs" 2>/dev/null
  pkill -f "fixtures/r2stub.mjs" 2>/dev/null
  for p in "$TEST_PORT" 20001 20002 20031 20091; do
    lsof -nP -iTCP:"$p" -sTCP:LISTEN -t 2>/dev/null | xargs kill 2>/dev/null
  done
}
cleanup() {
  [[ -n "${SERVER_PID:-}" ]] && kill "$SERVER_PID" 2>/dev/null
  kill_fixtures
  rm -rf "$TMP"
}
trap cleanup EXIT

NODE_BIN="$(command -v node)"
export NODE_BIN "NODE_BIN"
export NODE="$NODE_BIN"
export NO_COLOR=1
export HUSHFACE_SKIP_BANNER=1
export HOME="$TMP/home"
export HUSHFACE_HOME="$TMP/home/.hushface"
export TEST_PORT="${TEST_PORT:-19931}"

# a previous run that was interrupted leaves servers behind on the test ports;
# they serve stale temp dirs and make downloads look corrupt
kill_fixtures
sleep 0.2
mkdir -p "$HOME" "$TMP/bin"

# stub pi: records the arguments it was called with
cat >"$TMP/bin/pi" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >"$TMP/pi-args"
[[ "\${PI_STUB_EXIT:-0}" != "0" ]] && exit "\$PI_STUB_EXIT"
exit 0
EOF
chmod +x "$TMP/bin/pi"

# stub llama-server: our fake HTTP server
cat >"$TMP/bin/llama-server" <<EOF
#!/usr/bin/env bash
exec "$(command -v node)" "$FIX/fake-llama-server.mjs" "\$@"
EOF
chmod +x "$TMP/bin/llama-server"

# keep system tools, prepend our stubs
PATH="$TMP/bin:$PATH"
export PATH
export FAKE_ARGS_FILE="$TMP/llama-args"
export LLAMA_BIN="$TMP/bin/llama-server"

ok()   { PASS=$((PASS + 1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); FAILED="$FAILED
  - $1"; printf '  \033[31mFAIL\033[0m %s\n' "$1"; [[ -n "${2:-}" ]] && printf '         %s\n' "$2"; }
run_test() {
  local name="$1"
  [[ -n "$FILTER" && "$name" != *"$FILTER"* ]] && return 0
  printf '\n\033[1m%s\033[0m\n' "$name"
  "$name"
}

assert_eq()     { if [[ "$1" == "$2" ]]; then ok "$3"; else bad "$3" "expected [$2], got [$1]"; fi; }
assert_ok()     { if "$@" >/dev/null 2>&1; then ok "exit 0: ${*:1:3}"; else bad "expected exit 0: $*"; fi; }
assert_fails()  { if "$@" >/dev/null 2>&1; then bad "expected non-zero: $*"; else ok "fails as expected: ${*:1:3}"; fi; }
assert_has()    { if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3" "[$2] not in [$1]"; fi; }
assert_lacks()  { if printf '%s' "$1" | grep -qF -- "$2"; then bad "$3" "unexpected [$2] in [$1]"; else ok "$3"; fi; }

# source the libraries in a subshell with the same env
lib() { bash -c "set -uo pipefail; . '$ROOT/lib/ui.sh'; . '$ROOT/lib/platform.sh'; . '$ROOT/lib/install.sh'; $1"; }

wait_port() {
  local port="$1" i=0
  while (( i < 100 )); do
    curl -sf -m 1 "http://127.0.0.1:$port/health" >/dev/null 2>&1 && return 0
    sleep 0.1; i=$((i + 1))
  done
  return 1
}

make_fake_install() { # pretend a previous run finished
  mkdir -p "$HUSHFACE_HOME/models"
  head -c 4096 /dev/urandom >"$HUSHFACE_HOME/models/Qwen3.8-27B-UD-Q6_K.gguf"
  head -c 1024 /dev/urandom >"$HUSHFACE_HOME/models/Qwen3.8-27B-pi-lora-F16.gguf"
  cat >"$HUSHFACE_HOME/config.env" <<EOF
HUSHFACE_CONFIG_VERSION=2
PORT=$TEST_PORT
CTX=8192
QUANT=Q6_K
SOURCE=auto
EPHEMERAL=0
EOF
}

# ---------------------------------------------------------------- test cases --
t_cli_basics() {
  assert_eq "$("$HF" --version)" "hushface 0.1.0" "--version"
  assert_has "$("$HF" help)" "uninstall" "help lists commands"
  assert_has "$("$HF" help)" "--dry-run" "help lists options"
}

t_quant_choice() {
  assert_eq "$(lib 'pick_quant_for_ram 96')" "Q8_0" "96 GB -> Q8_0"
  assert_eq "$(lib 'pick_quant_for_ram 48')" "Q6_K" "48 GB -> Q6_K"
  assert_eq "$(lib 'pick_quant_for_ram 36')" "Q5_K_M" "36 GB -> Q5_K_M"
  assert_eq "$(lib 'pick_quant_for_ram 24')" "Q4_K_XL" "24 GB -> Q4_K_XL"
  assert_eq "$(lib 'pick_quant_for_ram 16')" "" "16 GB -> unsupported"
  assert_eq "$(lib 'QUANT=Q6_K; unset PLAT_QUANT; base_gguf_file')" \
    "Qwen3.8-27B-UD-Q6_K.gguf" "Q6_K file name"
  assert_eq "$(lib 'QUANT=Q8_0; unset PLAT_QUANT; base_gguf_file')" \
    "Qwen3.8-27B-Q8_0.gguf" "Q8_0 file name"
  assert_eq "$(lib 'QUANT=Q4_K_XL; unset PLAT_QUANT; base_gguf_file')" \
    "Qwen3.8-27B-UD-Q4_K_XL.gguf" "Q4_K_XL file name"
  assert_ok lib 'quant_valid Q6_K'
  assert_fails lib 'quant_valid Q3_K_S'
}

t_format_helpers() {
  assert_eq "$(lib 'human_bytes 0')" "0 B" "human_bytes 0"
  assert_eq "$(lib 'human_bytes 21980441504')" "20.5 GB" "human_bytes 22 GB"
  assert_eq "$(lib 'human_dur 45')" "45s" "human_dur seconds"
  assert_eq "$(lib 'human_dur 305')" "5m05s" "human_dur minutes"
  assert_eq "$(lib 'human_dur 7325')" "2h02m" "human_dur hours"
  assert_ok lib 'ver_ge 22.19.0 22.19.0'
  assert_ok lib 'ver_ge 26.7.0 22.19.0'
  assert_fails lib 'ver_ge 20.9.0 22.19.0'
  assert_ok lib 'ver_ge 13.6 13.0'
}

t_config_management() {
  local cfg="$TMP/cfg.env"
  rm -f "$cfg"
  lib "CONFIG='$cfg'; write_config" >/dev/null
  assert_has "$(cat "$cfg")" "HUSHFACE_CONFIG_VERSION=2" "writes version"
  assert_has "$(cat "$cfg")" "PORT=" "writes port"
  lib "CONFIG='$cfg'; PORT=9999; config_set PORT 9999" >/dev/null
  assert_eq "$(lib "CONFIG='$cfg'; config_get PORT")" "9999" "config_set updates in place"
  # a user edit must survive a re-run
  printf '# my comment\nPORT=9999\n' >"$cfg"
  lib "CONFIG='$cfg'; PORT=9931; CTX=65536; write_config" >/dev/null
  assert_has "$(cat "$cfg")" "PORT=9999" "existing value kept"
  assert_has "$(cat "$cfg")" "CTX=65536" "missing key added"
  assert_has "$(cat "$cfg")" "# my comment" "comments kept"
}

t_pi_provider() {
  local mj="$HOME/.pi/agent/models.json"
  mkdir -p "$(dirname "$mj")"
  printf '{"providers":{"deepseek":{"apiKey":"secret"}}}\n' >"$mj"
  # shellcheck disable=SC2034  # consumed by the sourced libraries
  ( HUSHFACE_ROOT="$ROOT"; PORT="$TEST_PORT"; ALIAS=qwen3.8-pi; CTX=65536; PROVIDER=hushface
    . "$ROOT/lib/ui.sh"; . "$ROOT/lib/runtime.sh"; . "$ROOT/lib/server.sh"; . "$ROOT/lib/pi.sh"
    base_url() { echo "http://127.0.0.1:$PORT"; }
    ensure_pi_provider >/dev/null ) 
  local body
  body="$(cat "$mj")"
  assert_has "$body" '"api": "openai-completions"' "uses chat completions api"
  assert_has "$body" '"deepseek"' "keeps other providers"
  assert_has "$body" '"id": "qwen3.8-pi"' "adds the model id"
  assert_has "$body" '"top_p": 1' "sets training sampling"
  # second run must not rewrite the file
  # shellcheck disable=SC2034  # consumed by the sourced libraries
  ( HUSHFACE_ROOT="$ROOT"; PORT="$TEST_PORT"; ALIAS=qwen3.8-pi; CTX=65536; PROVIDER=hushface
    . "$ROOT/lib/runtime.sh"; . "$ROOT/lib/pi.sh"; base_url() { echo "http://127.0.0.1:$PORT"; }
    out="$(ensure_pi_provider)"; [[ -z "$out" ]] ) \
    && ok "idempotent (no rewrite)" || bad "idempotent (no rewrite)"
  # shellcheck disable=SC2034  # consumed by the sourced libraries
  ( HUSHFACE_ROOT="$ROOT"; PROVIDER=hushface; . "$ROOT/lib/runtime.sh"; . "$ROOT/lib/pi.sh"
    remove_pi_provider >/dev/null )
  assert_lacks "$(cat "$mj")" '"hushface"' "uninstall removes the provider"
  assert_has "$(cat "$mj")" '"deepseek"' "uninstall keeps other providers"
}

t_downloader() {
  local src="$TMP/serve" dst="$TMP/dl"
  mkdir -p "$src" "$dst"
  head -c 12582912 /dev/urandom >"$src/payload.bin"
  local want; want="$(shasum -a 256 "$src/payload.bin" | awk '{print $1}')"
  "$NODE_BIN" "$FIX/fileserver.mjs" "$src" 20001 &
  SERVER_PID=$!
  sleep 0.6

  HUSHFACE_DL_CHUNK=1048576 "$NODE_BIN" "$ROOT/lib/dl.mjs" \
    "http://127.0.0.1:20001/payload.bin" "$dst/payload.bin" --jobs 4 --quiet
  assert_eq "$?" "0" "download with range support exits 0"
  assert_eq "$(shasum -a 256 "$dst/payload.bin" | awk '{print $1}')" "$want" "content matches"

  # checksum verification: good, then bad
  assert_ok "$NODE_BIN" "$ROOT/lib/dl.mjs" "http://127.0.0.1:20001/payload.bin" \
    "$dst/ok.bin" --sha256 "$want" --quiet
  assert_fails "$NODE_BIN" "$ROOT/lib/dl.mjs" "http://127.0.0.1:20001/payload.bin" \
    "$dst/bad.bin" --sha256 "deadbeef" --quiet
  assert_eq "$([[ -f "$dst/bad.bin" ]] && echo kept || echo removed)" "removed" \
    "bad checksum deletes the file"

  # resume: pretend the first chunk landed, then continue
  "$NODE_BIN" -e '
    const fs = require("node:fs");
    const [part, src] = process.argv.slice(1);
    const size = fs.statSync(src).size, chunk = 1048576;
    const fd = fs.openSync(part + ".part", "w");
    fs.ftruncateSync(fd, size);
    fs.writeSync(fd, fs.readFileSync(src).subarray(0, chunk), 0, chunk, 0);
    fs.closeSync(fd);
    fs.writeFileSync(part + ".part.state", JSON.stringify({ size, chunk }) + "\n0\n");
  ' "$dst/resume.bin" "$src/payload.bin"
  local out
  out="$(HUSHFACE_DL_CHUNK=1048576 "$NODE_BIN" "$ROOT/lib/dl.mjs" \
    "http://127.0.0.1:20001/payload.bin" "$dst/resume.bin" --jobs 2 2>&1)"
  assert_eq "$(shasum -a 256 "$dst/resume.bin" | awk '{print $1}')" "$want" "resumed file is correct"
  assert_has "$out" "resuming at" "reports that it resumed"

  # servers without range support must still work
  "$NODE_BIN" "$FIX/fileserver.mjs" "$src" 20002 --no-range &
  local npid=$!
  sleep 0.6
  assert_ok "$NODE_BIN" "$ROOT/lib/dl.mjs" "http://127.0.0.1:20002/payload.bin" \
    "$dst/norange.bin" --quiet
  assert_eq "$(shasum -a 256 "$dst/norange.bin" | awk '{print $1}')" "$want" \
    "no-range fallback is correct"
  kill "$npid" 2>/dev/null

  # a sequential prefix (what a modelscope/hf CLI leaves) must be adopted
  "$NODE_BIN" -e '
    const fs = require("node:fs");
    const [part, src] = process.argv.slice(1);
    fs.writeFileSync(part + ".part", fs.readFileSync(src).subarray(0, 3 * 1048576));
  ' "$dst/prefix.bin" "$src/payload.bin"
  out="$(HUSHFACE_DL_CHUNK=1048576 "$NODE_BIN" "$ROOT/lib/dl.mjs" \
    "http://127.0.0.1:20001/payload.bin" "$dst/prefix.bin" --jobs 2 2>&1)"
  assert_eq "$(shasum -a 256 "$dst/prefix.bin" | awk '{print $1}')" "$want" \
    "prefix adoption produces the right file"
  assert_has "$out" "adopting" "reports adopting existing bytes"

  # 404 must fail cleanly
  assert_fails "$NODE_BIN" "$ROOT/lib/dl.mjs" "http://127.0.0.1:20001/missing.bin" \
    "$dst/missing.bin" --quiet
  kill "$SERVER_PID" 2>/dev/null; SERVER_PID=""
}

t_fetch_one() {
  local src="$TMP/serve" home="$TMP/f1"
  mkdir -p "$src" "$home/models" "$home/.downloads/ms-old"
  head -c 2097152 /dev/urandom >"$src/model.gguf"
  local want; want="$(shasum -a 256 "$src/model.gguf" | awk '{print $1}')"
  "$NODE_BIN" "$FIX/fileserver.mjs" "$src" 20031 >/dev/null 2>&1 &
  local spid=$!
  sleep 0.6

  # fake hub: ModelScope is "reachable" and serves our local file
  fetch() {
    bash -c "set -uo pipefail
      . '$ROOT/lib/ui.sh'; . '$ROOT/lib/runtime.sh'; . '$ROOT/lib/platform.sh'; . '$ROOT/lib/install.sh'
      HUSHFACE_HOME='$home'; HUSHFACE_ROOT='$ROOT'
      hub() { printf 'http://127.0.0.1:20031/model.gguf\t2097152\t$want\n'; }
      $1" 2>&1
  }

  local out
  out="$(fetch "fetch_one x/y model.gguf $home/models/model.gguf")"
  assert_eq "$(shasum -a 256 "$home/models/model.gguf" | awk '{print $1}')" "$want" \
    "fetch_one downloads and verifies"
  assert_has "$out" "modelscope" "fetch_one reports the source"

  # an interrupted modelscope CLI download must be adopted, not re-fetched
  rm -f "$home/models/model.gguf"
  head -c 1048576 "$src/model.gguf" >"$home/.downloads/ms-old/model.gguf.incomplete"
  out="$(HUSHFACE_DL_CHUNK=524288 fetch "fetch_one x/y model.gguf $home/models/model.gguf")"
  assert_has "$out" "resuming from" "adopts a partial file from .downloads"
  assert_eq "$(shasum -a 256 "$home/models/model.gguf" | awk '{print $1}')" "$want" \
    "adopted download is complete and correct"

  # a checksum that does not match must fail the whole fetch
  printf '{"size":2097152}' >/dev/null
  ( bash -c "set -uo pipefail
      . '$ROOT/lib/ui.sh'; . '$ROOT/lib/runtime.sh'; . '$ROOT/lib/platform.sh'; . '$ROOT/lib/install.sh'
      HUSHFACE_HOME='$home'; HUSHFACE_ROOT='$ROOT'
      hub() { printf 'http://127.0.0.1:20031/model.gguf\t2097152\t0000\n'; }
      fetch_one x/y model.gguf $home/models/bad.gguf" >/dev/null 2>&1 )
  assert_eq "$([[ -f "$home/models/bad.gguf" ]] && echo kept || echo removed)" "removed" \
    "a bad checksum leaves no file behind"
  kill $spid 2>/dev/null
}

t_wrangler_config() {
  local toml="$ROOT/cloudflare/wrangler.toml"
  assert_ok test -f "$toml"
  # everything after [[r2_buckets]] belongs to that table: routes must be above it
  local routes_line r2_line
  routes_line="$(grep -n '^routes *= *\[' "$toml" | cut -d: -f1)"
  r2_line="$(grep -n '^\[\[r2_buckets\]\]' "$toml" | cut -d: -f1)"
  assert_eq "$([[ -n "$routes_line" && -n "$r2_line" && "$routes_line" -lt "$r2_line" ]] && echo ok || echo bad)" \
    "ok" "routes is declared before [[r2_buckets]] (else wrangler silently drops it)"
  assert_has "$(cat "$toml")" "custom_domain = true" "uses a custom domain (creates DNS + cert)"
  assert_has "$(cat "$toml")" "workers_dev = true" "keeps the workers.dev fallback"
  assert_has "$(cat "$toml")" "binding = \"RELEASES\"" "binds the R2 bucket"
  assert_lacks "$(grep -v '^[[:space:]]*#' "$toml")" "zone_name" \
    "does not use the DNS-less zone_name route (comments aside)"
}

t_cf_worker() {
  # the worker that serves hushface.com, run against a fake R2 bucket
  local bucket="$TMP/bucket" port=20091
  mkdir -p "$bucket/latest" "$bucket/v0.1.0"
  printf '#!/bin/sh\necho install\n' >"$bucket/latest/install.sh"
  head -c 300000 /dev/urandom >"$bucket/latest/hushface-macos-arm64.sh"
  cp "$bucket/latest/hushface-macos-arm64.sh" "$bucket/v0.1.0/hushface-macos-arm64.sh"
  shasum -a 256 "$bucket/latest/hushface-macos-arm64.sh" \
    | sed "s|$bucket/latest/||" >"$bucket/latest/hushface-macos-arm64.sh.sha256"
  cp "$bucket/latest/hushface-macos-arm64.sh.sha256" "$bucket/v0.1.0/"
  cp "$bucket/latest/install.sh" "$bucket/v0.1.0/"

  "$NODE_BIN" "$FIX/r2stub.mjs" "$ROOT/cloudflare" "$bucket" "$port" >/dev/null 2>&1 &
  local wpid=$!
  sleep 0.8

  assert_eq "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/hushface-macos-arm64.sh")" \
    "200" "worker serves /hushface-macos-arm64.sh"
  assert_has "$(curl -s "http://127.0.0.1:$port/releases/latest/install.sh")" "echo install" \
    "worker maps /releases/latest/<file>"
  assert_has "$(curl -s "http://127.0.0.1:$port/releases/v0.1.0/install.sh")" "echo install" \
    "worker maps versioned paths"
  assert_eq "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/nope.sh")" "404" \
    "worker 404s unknown keys"
  local page
  page="$(curl -s "http://127.0.0.1:$port/")"
  assert_has "$page" "curl -LsSf https://hushface.com/install.sh" "landing page carries the one-liner"
  assert_has "$page" "https://github.com/timqian/hushface" "landing page links the GitHub repo"
  assert_has "$page" "Apple Silicon" "landing page states the requirements"
  assert_has "$page" "/hushface-macos-arm64.sh.sha256" "landing page links the checksum"

  # ranged requests are what resumable downloads depend on
  local hdr
  hdr="$(curl -s -o /dev/null -D - -r 0-99 "http://127.0.0.1:$port/hushface-macos-arm64.sh" | tr -d '\r')"
  assert_has "$hdr" "206" "worker returns 206 for a range"
  assert_has "$(printf '%s' "$hdr" | grep -i '^content-length:' | awk '{print $2}')" "100" \
    "range length is exact"
  assert_has "$(printf '%s' "$hdr" | grep -i '^content-range:' | awk '{print $3}')" "0-99/300000" \
    "content-range reports the object size"

  # a range past the end must not silently succeed
  assert_eq "$(curl -s -o /dev/null -w '%{http_code}' -r 400000- "http://127.0.0.1:$port/hushface-macos-arm64.sh")" \
    "416" "worker rejects unsatisfiable ranges"

  # the published checksum verifies the artifact byte for byte
  local want got
  want="$(cut -d' ' -f1 <"$bucket/latest/hushface-macos-arm64.sh.sha256")"
  got="$(curl -s "http://127.0.0.1:$port/hushface-macos-arm64.sh" | shasum -a 256 | cut -d' ' -f1)"
  assert_eq "$got" "$want" "artifact served intact (checksum matches)"

  kill $wpid 2>/dev/null

  # a broken binding or a throwing bucket must never look like an opaque 502
  local wr
  wr="$("$NODE_BIN" --input-type=module -e "
    const w = await import('file://$ROOT/cloudflare/worker.js');
    const call = async (env, path = '/') => {
      const r = await w.default.fetch(new Request('https://hushface.com' + path), env);
      return r.status + ' ' + (await r.text()).split('\n')[0].slice(0, 40);
    };
    console.log(await call({}, '/'));
    const boom = { get: async () => { throw new Error('boom'); }, head: async () => null };
    console.log(await call({ RELEASES: boom }, '/install.sh'));
  " 2>/dev/null)"
  assert_has "$wr" "503 hushface.com is misconfigured" "missing R2 binding explains itself"
  assert_has "$wr" "500 hushface.com: the worker hit an error" "worker errors are readable, not 502"
}

t_port_selection() {
  local busy="$TEST_PORT"
  "$NODE_BIN" "$FIX/fileserver.mjs" "$TMP" "$busy" >/dev/null 2>&1 &
  local p=$!
  sleep 0.5
  local got
  got="$(lib "pick_port $busy")"
  assert_eq "$got" "$((busy + 1))" "picks the next free port when taken"
  kill $p 2>/dev/null
  assert_eq "$(lib "pick_port $((busy + 3))")" "$((busy + 3))" "keeps a free port"
}

t_preflight() {
  local out rc
  out="$(lib 'platform_preflight' 2>&1)"
  rc=$?
  assert_eq "$rc" "0" "this machine passes preflight"
  assert_has "$out" "Apple Silicon" "detects Apple Silicon"
  assert_has "$out" "RAM" "reports RAM"
}

t_no_setup_command() {
  # a bare `hushface` on a clean home must go straight into the install flow
  local out
  out="$(HUSHFACE_HOME="$TMP/fresh1" HOME="$TMP/home-dry" "$HF" --dry-run --yes </dev/null 2>&1)"
  assert_has "$out" "not set up" "first run detects it is not set up"
  assert_has "$out" "dry run" "dry run stops before downloading"
  assert_has "$out" "install llama.cpp" "dry run lists llama.cpp"
  assert_has "$out" "download" "dry run lists the download"
  assert_eq "$([[ -d "$TMP/fresh1/models" ]] && echo yes || echo no)" "no" \
    "dry run creates nothing"
  assert_eq "$([[ -f "$TMP/home-dry/.pi/agent/models.json" ]] && echo yes || echo no)" "no" \
    "dry run does not touch the pi config"

  # non-interactive without --yes must refuse instead of hanging
  HUSHFACE_HOME="$TMP/fresh2" "$HF" </dev/null >"$TMP/o" 2>&1
  assert_eq "$?" "1" "non-TTY first run exits non-zero"
  assert_has "$(cat "$TMP/o")" "--yes" "and says to pass --yes"
}

t_server_lifecycle() {
  make_fake_install
  local out
  out="$("$HF" start 2>&1)"
  assert_has "$out" "ready" "start reports ready"
  assert_eq "$(curl -s -m 2 "http://127.0.0.1:$TEST_PORT/health" | head -c 4)" '{"st' "server is healthy"
  assert_has "$("$HF" status 2>&1)" "up on" "status reports up"
  assert_has "$(cat "$FAKE_ARGS_FILE")" "--lora" "passes the adapter to llama-server"
  assert_has "$(cat "$FAKE_ARGS_FILE")" "enable_thinking" "thinking off via template kwargs"
  assert_has "$(cat "$FAKE_ARGS_FILE")" "--jinja" "tool calling enabled"
  assert_has "$("$HF" doctor 2>&1)" "tool_call: bash" "doctor sees working tool calls"
  assert_has "$("$HF" stop 2>&1)" "stopped" "stop works"
  wait_port "$TEST_PORT" && bad "server really stopped" || ok "server really stopped"
}

t_pi_passthrough() {
  make_fake_install
  "$HF" -p "explain the repo" >/dev/null 2>&1
  assert_has "$(cat "$TMP/pi-args" 2>/dev/null)" "--provider hushface --model qwen3.8-pi" \
    "launches pi on the local provider"
  assert_has "$(cat "$TMP/pi-args")" "--thinking off" "thinking off"
  assert_has "$(cat "$TMP/pi-args")" "-p explain the repo" "passes pi args through"
  "$HF" stop >/dev/null 2>&1

  "$HF" --resume >/dev/null 2>&1
  assert_has "$(cat "$TMP/pi-args")" "--resume" "passes unknown flags through"
  "$HF" stop >/dev/null 2>&1
}

t_ephemeral() {
  make_fake_install
  "$HF" --ephemeral -p hi >/dev/null 2>&1
  assert_has "$(cat "$TMP/pi-args")" "-p hi" "ephemeral run reaches pi"
  sleep 0.3
  if wait_port "$TEST_PORT"; then bad "ephemeral stops the server on exit"; else ok "ephemeral stops the server on exit"; fi
}

t_model_source() {
  make_fake_install
  assert_has "$("$HF" source 2>&1)" "source: auto" "shows the current source"
  "$HF" source hf >/dev/null 2>&1
  assert_eq "$(sed -n 's/^SOURCE=//p' "$HUSHFACE_HOME/config.env")" "hf" "source hf persists"
  assert_has "$("$HF" source 2>&1)" "source: hf" "shows the new source"
  "$HF" source modelscope >/dev/null 2>&1
  assert_eq "$(sed -n 's/^SOURCE=//p' "$HUSHFACE_HOME/config.env")" "modelscope" \
    "source modelscope persists"
  assert_fails "$HF" source nonsense
  # a terminal-less first run must not block on the question
  rm -f "$HUSHFACE_HOME/config.env"
  local out
  out="$(HUSHFACE_SKIP_BANNER=1 "$HF" --dry-run --yes </dev/null 2>&1)"
  assert_has "$out" "source" "dry run still reports a source"
}

t_info_and_clean() {
  make_fake_install
  assert_has "$("$HF" info 2>&1)" "Qwen3.8-27B-UD-Q6_K.gguf" "info shows the model"
  mkdir -p "$HUSHFACE_HOME/.downloads/x"
  head -c 100000 /dev/urandom >"$HUSHFACE_HOME/.downloads/x/blob"
  "$HF" clean >/dev/null 2>&1
  assert_eq "$([[ -d "$HUSHFACE_HOME/.downloads" ]] && echo yes || echo no)" "no" "clean removes caches"
  assert_eq "$([[ -f "$HUSHFACE_HOME/models/Qwen3.8-27B-UD-Q6_K.gguf" ]] && echo yes || echo no)" \
    "yes" "clean keeps the weights"
}

# --------------------------------------------------------------------- run ----
printf '\033[1mhushface tests\033[0m  (%s)\n' "$ROOT"
run_test t_cli_basics
run_test t_quant_choice
run_test t_format_helpers
run_test t_config_management
run_test t_pi_provider
run_test t_downloader
run_test t_fetch_one
run_test t_wrangler_config
run_test t_cf_worker
run_test t_port_selection
run_test t_preflight
run_test t_no_setup_command
run_test t_server_lifecycle
run_test t_pi_passthrough
run_test t_ephemeral
run_test t_model_source
run_test t_info_and_clean

printf '\n\033[1m%d passed, %d failed\033[0m' "$PASS" "$FAIL"
if (( FAIL )); then printf '\n%s\n' "$FAILED"; printf '\n'; exit 1; fi
printf '\n'
