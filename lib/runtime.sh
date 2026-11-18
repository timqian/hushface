#!/usr/bin/env bash
# Locate the interpreters and binaries we should use: a bundled runtime wins
# over whatever happens to be on PATH. bash 3.2 compatible.
# shellcheck shell=bash

# Layout of a bundled runtime (see tools/build-payload.sh):
#   $RUNTIME_DIR/node/bin/node        Node (runs pi and our helpers)
#   $RUNTIME_DIR/pi/dist/bundle/cli.js  pi, as a single bundled file
#   $RUNTIME_DIR/bin/pi               wrapper: node cli.js "$@"
#   $RUNTIME_DIR/llama/bin/llama-server
#   $RUNTIME_DIR/manifest.json
if [[ -z "${RUNTIME_DIR:-}" ]]; then
  # a bundled install keeps the runtime next to the app; a source install can
  # still point at $HUSHFACE_HOME/runtime
  if [[ -n "${HUSHFACE_ROOT:-}" && -d "${HUSHFACE_ROOT}/runtime" ]]; then
    RUNTIME_DIR="$HUSHFACE_ROOT/runtime"
  else
    RUNTIME_DIR="${HUSHFACE_HOME:-$HOME/.hushface}/runtime"
  fi
fi

NODE="${NODE:-node}"
PI_BIN="${PI_BIN:-pi}"
BUNDLED_LLAMA="${BUNDLED_LLAMA:-}"

bundled_runtime() { [[ -f "$RUNTIME_DIR/manifest.json" ]]; }

resolve_tools() {
  if [[ -x "$RUNTIME_DIR/node/bin/node" ]]; then NODE="$RUNTIME_DIR/node/bin/node"; fi
  if [[ -x "$RUNTIME_DIR/bin/pi" ]]; then PI_BIN="$RUNTIME_DIR/bin/pi"; fi
  if [[ -x "$RUNTIME_DIR/llama/bin/llama-server" ]]; then
    BUNDLED_LLAMA="$RUNTIME_DIR/llama/bin/llama-server"
  fi
  export NODE PI_BIN BUNDLED_LLAMA RUNTIME_DIR
}

runtime_version() { # key from manifest.json
  [[ -f "$RUNTIME_DIR/manifest.json" ]] || return 1
  "$NODE" -e '
    const fs = require("node:fs");
    const m = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const v = process.argv[2].split(".").reduce((o, k) => (o == null ? o : o[k]), m);
    if (v != null) process.stdout.write(String(v));
  ' "$RUNTIME_DIR/manifest.json" "$1" 2>/dev/null
}

node_available() { [[ -x "$NODE" ]] || command -v "$NODE" >/dev/null 2>&1; }
node_version()   { "$NODE" -v 2>/dev/null | sed 's/^v//'; }

pi_available() { [[ -x "$PI_BIN" ]] || command -v "$PI_BIN" >/dev/null 2>&1; }
pi_version()   { "$PI_BIN" --version 2>/dev/null | head -1; }

# run one of our node helpers: hf_node <script.mjs> [args...]
hf_node() {
  local script="$1" root="${HUSHFACE_ROOT:-$(dirname "$(dirname "${BASH_SOURCE[0]}")")}"
  shift
  "$NODE" "$root/lib/$script" "$@"
}
