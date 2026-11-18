#!/usr/bin/env bash
# pi integration: provider block in ~/.pi/agent/models.json, uninstall. bash 3.2.
# shellcheck shell=bash

models_json_path() { printf '%s/.pi/agent/models.json' "$HOME"; }

pi_provider_present() {
  local p
  p="$(models_json_path)"
  [[ -f "$p" ]] || return 1
  hf_node modelsjson.mjs has "$p" "$PROVIDER" >/dev/null 2>&1
}

ensure_pi_provider() {
  local p
  p="$(models_json_path)"
  mkdir -p "$(dirname "$p")"
  hf_node modelsjson.mjs merge "$p" "$PROVIDER" "$(base_url)/v1" "$ALIAS" "$CTX"
}

remove_pi_provider() {
  local p
  p="$(models_json_path)"
  [[ -f "$p" ]] || return 0
  hf_node modelsjson.mjs remove "$p" "$PROVIDER"
}
