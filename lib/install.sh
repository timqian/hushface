#!/usr/bin/env bash
# Dependency installation, model download and config management.
# bash 3.2 compatible.
# shellcheck shell=bash

: "${HUSHFACE_CONFIG_VERSION:=2}"
# usable on their own (tests, doctor) without the full CLI context
: "${HUSHFACE_HOME:=$HOME/.hushface}"
: "${PORT:=9931}"
: "${CTX:=65536}"
: "${SOURCE:=auto}"
: "${EPHEMERAL:=0}"
LORA_FILE="Qwen3.8-27B-pi-lora-F16.gguf"
BASE_REPO="${BASE_REPO:-unsloth/Qwen3.8-27B-GGUF}"
LORA_REPO="${LORA_REPO:-harness-hub/Qwen3.8-27B-pi-adapted-GGUF}"

# http_ok <url> — 2xx/3xx counts as reachable
http_ok() {
  local code
  code="$(curl -s -o /dev/null -m 6 -w '%{http_code}' "$1" 2>/dev/null)"
  case "$code" in 2??|3??) return 0 ;; *) return 1 ;; esac
}

source_url() { # auto|modelscope|hf -> host to probe
  case "$1" in
    hf) printf 'https://huggingface.co' ;;
    *)  printf 'https://modelscope.cn' ;;
  esac
}

hub() { hf_node hub.mjs "$@"; }
dl() { hf_node dl.mjs "$@"; }

# --------------------------------------------------------------- llama.cpp ---
find_llama() {
  if [[ -n "${LLAMA_BIN:-}" && -x "${LLAMA_BIN:-}" ]]; then printf '%s' "$LLAMA_BIN"; return 0; fi
  local c
  if [[ -n "${BUNDLED_LLAMA:-}" && -x "$BUNDLED_LLAMA" ]]; then
    printf '%s' "$BUNDLED_LLAMA"; return 0
  fi
  for c in llama-server \
           "$HUSHFACE_HOME/bin/llama-server" \
           "$HOME/.llama/bin/llama-server" \
           /opt/homebrew/bin/llama-server \
           /usr/local/bin/llama-server; do
    if [[ "$c" == */* ]]; then
      [[ -x "$c" ]] && { printf '%s' "$c"; return 0; }
    elif have "$c"; then
      command -v "$c"; return 0
    fi
  done
  return 1
}

# llama-server prints its version on stderr
llama_version() {
  local b
  b="$(find_llama)" || return 1
  ("$b" --version 2>&1 | head -1) | sed 's/^version: *//'
}

ensure_llama() {
  if find_llama >/dev/null; then
    ui_ok "llama.cpp: $(llama_version)"
    return 0
  fi
  if bundled_runtime && [[ -x "$BUNDLED_LLAMA" ]]; then
    ui_ok "llama.cpp: $(llama_version) (bundled)"
    return 0
  fi
  ui_step "Installing llama.cpp"

  if have brew; then
    if ui_run "brew install llama.cpp" "$INSTALL_LOG" brew install llama.cpp; then
      find_llama >/dev/null && { ui_ok "llama.cpp: $(llama_version)"; return 0; }
    fi
  fi

  # prebuilt macOS arm64 release: no brew, no admin, nothing compiled
  local url zip="$HUSHFACE_HOME/.cache/llama-archive" out="$HUSHFACE_HOME/.cache/llama"
  if url="$(hub llama-release 2>/dev/null)" && [[ -n "$url" ]]; then
    ui_info "downloading prebuilt llama.cpp"
    if dl "$url" "$zip" --label "llama.cpp" --jobs 2 --quiet; then
      mkdir -p "$HUSHFACE_HOME/bin"
      rm -rf "$out" && mkdir -p "$out"
      case "$url" in
        *.tar.gz|*.tgz) tar -xzf "$zip" -C "$out" >>"$INSTALL_LOG" 2>&1 || true ;;
        *)              unzip -q -o "$zip" -d "$out" >>"$INSTALL_LOG" 2>&1 || true ;;
      esac
      local found
      found="$(find "$out" -name 'llama-server' -type f | head -1)"
      if [[ -n "$found" ]]; then
        cp -f "$found" "$HUSHFACE_HOME/bin/llama-server"
        chmod +x "$HUSHFACE_HOME/bin/llama-server"
        # unsigned binary from a download: drop the quarantine flag or macOS kills it
        xattr -dr com.apple.quarantine "$HUSHFACE_HOME/bin/llama-server" 2>/dev/null || true
        for lib in "$(dirname "$found")"/*.dylib; do
          [[ -f "$lib" ]] || continue
          cp -f "$lib" "$HUSHFACE_HOME/bin/"
          xattr -dr com.apple.quarantine "$HUSHFACE_HOME/bin/$(basename "$lib")" 2>/dev/null || true
        done
        find_llama >/dev/null && { ui_ok "llama.cpp: $(llama_version)"; return 0; }
      fi
    fi
  fi

  ui_info "trying the llama.app installer"
  if ui_run "llama.app installer" "$INSTALL_LOG" \
       bash -c 'curl -LsSf https://llama.app/install.sh | bash'; then
    find_llama >/dev/null && { ui_ok "llama.cpp: $(llama_version)"; return 0; }
  fi

  ui_err "could not install llama.cpp"
  ui_info "install it yourself, then re-run: brew install llama.cpp"
  ui_info "  https://llama.app/docs/installation"
  return 1
}

# ---------------------------------------------------------------------- pi ---
ensure_node() {
  local nv
  nv="$(node_version)"
  if [[ -n "$nv" ]] && ver_ge "$nv" "$MIN_NODE"; then return 0; fi
  if bundled_runtime; then
    ui_ok "node $(node_version) (bundled)"
    return 0
  fi
  if [[ -n "$nv" ]]; then
    ui_warn "node $nv is older than $MIN_NODE"
  fi
  have brew || { ui_err "node >= $MIN_NODE required; install node and re-run"; return 1; }
  ui_run "brew install node" "$INSTALL_LOG" brew install node || return 1
  nv="$(node_version)"
  [[ -n "$nv" ]] && ver_ge "$nv" "$MIN_NODE"
}

ensure_pi() {
  if pi_available; then
    ui_ok "pi $(pi_version)"
    return 0
  fi
  ui_step "Installing pi"
  ensure_node || return 1
  # --ignore-scripts as documented by pi
  if ui_run "npm install -g @earendil-works/pi-coding-agent" "$INSTALL_LOG" \
       npm install -g --ignore-scripts @earendil-works/pi-coding-agent; then
    if pi_available; then ui_ok "pi $(pi_version)"; return 0; fi
    ui_warn "npm finished but pi is not on PATH"
    ui_info "check: npm bin -g   (then add it to PATH and re-run)"
    return 1
  fi
  return 1
}

# ------------------------------------------------------------------ models ---
base_gguf_file() {
  local q
  q="${PLAT_QUANT:-${QUANT:-}}"
  [[ -z "$q" ]] && q="$(pick_quant_for_ram "$(plat_ram_gb)")"
  [[ -z "$q" ]] && q=Q4_K_XL
  case "$q" in
    UD-*) printf 'Qwen3.8-27B-%s.gguf' "$q" ;;
    Q8_0) printf 'Qwen3.8-27B-Q8_0.gguf' ;;
    *)    printf 'Qwen3.8-27B-UD-%s.gguf' "$q" ;;
  esac
}

quant_valid() {
  case "$1" in
    Q8_0|Q6_K_L|Q6_K|Q5_K_M|Q4_K_XL|UD-*) return 0 ;;
    *) return 1 ;;
  esac
}

# A previous run (or an interrupted `modelscope download`) may leave a
# sequential prefix of the file. dl.mjs resumes from it byte-for-byte.
adopt_partial() { # file dest
  local file="$1" dest="$2" cand
  [[ -s "$dest.part" ]] && return 0
  for cand in "$HUSHFACE_HOME"/.downloads/*/"$file" \
              "$HUSHFACE_HOME"/.downloads/*/"$file".incomplete \
              "$HUSHFACE_HOME"/.cache/*/"$file".incomplete; do
    if [[ -f "$cand" ]]; then
      mv -f "$cand" "$dest.part"
      ui_info "resuming from $(human_bytes "$(stat -f%z "$dest.part")") already on disk"
      return 0
    fi
  done
  return 0
}

# Verify a file we did not download ourselves (e.g. left by an earlier run).
# Returns 1 only when the checksum proves it is corrupt.
verify_existing() { # repo file dest
  local repo="$1" file="$2" dest="$3" line sha marker
  [[ -s "$dest" ]] || return 1
  marker="$HUSHFACE_HOME/verified/$(basename "$dest").$(stat -f%z "$dest")"
  [[ -f "$marker" ]] && return 0
  local src
  for src in ${SOURCE:-auto} hf modelscope; do
    [[ "$src" == auto ]] && continue
    line="$(hub resolve --source "$src" --repo "$repo" --file "$file" 2>/dev/null)" || continue
    sha="$(printf '%s' "$line" | cut -f3)"
    break
  done
  if [[ -z "${sha:-}" ]]; then
    ui_info "$(basename "$dest"): no checksum published, trusting local size"
    return 0
  fi
  ui_info "$(basename "$dest"): verifying existing download (one-time)"
  if ! dl --verify-only "$dest" --sha256 "$sha"; then
    return 1
  fi
  mkdir -p "$HUSHFACE_HOME/verified"
  : >"$marker"
  return 0
}

# fetch_one <repo> <file> <dest> — resolve on each source, then download
fetch_one() {
  local repo="$1" file="$2" dest="$3" src line url size sha
  if [[ -s "$dest" ]]; then
    if verify_existing "$repo" "$file" "$dest"; then
      ui_ok "$(basename "$dest") ($(human_bytes "$(stat -f%z "$dest")"))"
      return 0
    fi
    ui_warn "$(basename "$dest") is corrupt — downloading again"
    rm -f "$dest"
  fi
  local -a sources
  case "${SOURCE:-auto}" in
    modelscope) sources=(modelscope) ;;
    hf)         sources=(hf) ;;
    *)          sources=(hf modelscope) ;;
  esac
  adopt_partial "$file" "$dest"
  for src in "${sources[@]}"; do
    local token=""
    [[ "$src" == hf ]] && token="${HF_TOKEN:-}"
    [[ "$src" == modelscope ]] && token="${MS_TOKEN:-}"
    if line="$(hub resolve --source "$src" --repo "$repo" --file "$file" ${token:+--token "$token"} 2>/dev/null)"; then
      url="$(printf '%s' "$line" | cut -f1)"
      size="$(printf '%s' "$line" | cut -f2)"
      sha="$(printf '%s' "$line" | cut -f3)"
      local tag=""
      [[ "$src" == modelscope ]] && tag=" · modelscope.cn"
      ui_info "$file  $(human_bytes "$size")$tag"
      local args
      args=("$url" "$dest" --label "$(basename "$dest")" --jobs "${JOBS:-4}")
      [[ -n "$sha" && "${NO_VERIFY:-0}" != "1" ]] && args+=(--sha256 "$sha")
      if dl "${args[@]}"; then
        return 0
      fi
      rm -f "$dest.part.state"
      ui_warn "$src download failed"
    fi
    [[ "${SOURCE:-auto}" != "auto" ]] && break
  done
  ui_err "could not download $repo/$file"
  return 1
}

# bytes of the base model + adapter already on disk
model_bytes_present() {
  local total=0 f
  for f in "$MODELS_DIR/$(base_gguf_file)" "$MODELS_DIR/$LORA_FILE"; do
    if [[ -s "$f" ]]; then total=$(( total + $(stat -f%z "$f" 2>/dev/null || echo 0) )); fi
  done
  printf '%s' "$total"
}

# bytes we would still have to download for the chosen quant
model_bytes_missing() {
  local want have
  want=$(( $(quant_size_gb "$(base_quant)") * 1024 * 1024 * 1024 + 318802304 ))
  have="$(model_bytes_present)"
  if (( have >= want )); then printf '0'; else printf '%s' $(( want - have )); fi
}

model_ready() {
  [[ -s "$MODELS_DIR/$(base_gguf_file)" && -s "$MODELS_DIR/$LORA_FILE" ]]
}

ensure_models() {
  ui_step "Downloading model weights"
  local base
  base="$(base_gguf_file)"
  if [[ "${FORCE:-0}" == "1" ]]; then
    ui_info "forced re-download"
    rm -f "$MODELS_DIR/$base" "$MODELS_DIR/$LORA_FILE"
  fi
  ui_info "into $MODELS_DIR"
  fetch_one "$LORA_REPO" "$LORA_FILE" "$MODELS_DIR/$LORA_FILE" || return 1
  fetch_one "$BASE_REPO" "$base" "$MODELS_DIR/$base" || return 1
  return 0
}

# ------------------------------------------------------------------ config ---
config_get() { # key -> value
  local k="$1"
  [[ -f "$CONFIG" ]] || return 1
  sed -n "s/^${k}=//p" "$CONFIG" | tail -1
}

config_set() { # key value — replace or append, keep comments intact
  local k="$1" v="$2" tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/hushface.XXXXXX")"
  if [[ -f "$CONFIG" ]] && grep -q "^${k}=" "$CONFIG"; then
    awk -v k="$k" -v v="$v" '
      $0 ~ "^"k"=" { print k"="v; next } { print }' "$CONFIG" >"$tmp"
  else
    { [[ -f "$CONFIG" ]] && cat "$CONFIG"; echo "${k}=${v}"; } >"$tmp"
  fi
  mv "$tmp" "$CONFIG"
}

write_config() {
  mkdir -p "$HUSHFACE_HOME"
  if [[ -f "$CONFIG" ]]; then
    # existing install: only fill in what is missing, never clobber user edits
    config_set HUSHFACE_CONFIG_VERSION "$HUSHFACE_CONFIG_VERSION"
    [[ -z "$(config_get PORT)" ]] && config_set PORT "$PORT"
    [[ -z "$(config_get CTX)" ]] && config_set CTX "$CTX"
    [[ -z "$(config_get QUANT)" ]] && config_set QUANT "$(base_quant)"
    [[ -z "$(config_get SOURCE)" ]] && config_set SOURCE "${SOURCE:-auto}"
    return 0
  fi
  cat >"$CONFIG" <<EOF
# hushface config — edit freely, or delete this file to re-run the wizard.
HUSHFACE_CONFIG_VERSION=$HUSHFACE_CONFIG_VERSION
PORT=$PORT
CTX=$CTX
QUANT=$(base_quant)
SOURCE=${SOURCE:-auto}
EPHEMERAL=$EPHEMERAL
EOF
}

base_quant() {
  local q="${PLAT_QUANT:-${QUANT:-}}"
  if [[ -z "$q" ]]; then q="$(pick_quant_for_ram "$(plat_ram_gb)")"; fi
  printf '%s' "${q:-Q4_K_XL}"
}
