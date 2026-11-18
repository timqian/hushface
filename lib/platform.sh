#!/usr/bin/env bash
# Machine support checks and plan computation. bash 3.2 compatible.
# shellcheck shell=bash

export MIN_MACOS="13.0"
export MIN_NODE="22.19.0"
export MIN_FREE_AFTER_GB=10          # working room on top of the weights

# sysctl lives in /usr/sbin; fall back to the absolute path in case PATH is odd
sysctl_get() {
  local v
  v="$(sysctl -n "$1" 2>/dev/null)" || v=""
  [[ -z "$v" ]] && v="$(/usr/sbin/sysctl -n "$1" 2>/dev/null)" || true
  printf '%s' "$v"
}

plat_ram_gb()  { echo $(( $(sysctl_get hw.memsize || echo 0) / 1073741824 )); }
plat_arch()    { uname -m; }
plat_macos()   { sw_vers -productVersion 2>/dev/null || echo "0" ; }
plat_cores()   { local c; c="$(sysctl_get hw.ncpu)"; echo "${c:-4}"; }

# free space in GB for the filesystem holding $1 (or /)
plat_free_gb() {
  df -g "${1:-/}" 2>/dev/null | awk 'NR==2{print $4}' || echo 0
}

# weights only, in GB — keep in sync with the quant table in README
quant_size_gb() {
  case "$1" in
    Q8_0)     echo 29 ;;
    Q6_K_L)   echo 25 ;;
    Q6_K)     echo 22 ;;
    Q5_K_M)   echo 20 ;;
    Q4_K_XL)  echo 18 ;;
    *)        echo 22 ;;
  esac
}

# Uniform memory, so the GPU wired limit is the real ceiling.
# Apple defaults iogpu.wired_limit_mb to ~75% of RAM; llama.cpp needs the
# weights resident, so pick a quant that leaves room for KV cache + the OS.
pick_quant_for_ram() {
  local gb="$1"
  if   (( gb >= 60 )); then echo Q8_0
  elif (( gb >= 40 )); then echo Q6_K
  elif (( gb >= 30 )); then echo Q5_K_M
  elif (( gb >= 22 )); then echo Q4_K_XL
  else echo ""
  fi
}

quant_is_supported() { [[ -n "$(pick_quant_for_ram "$1")" ]]; }

port_free() { ! lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; }

pick_port() { # preferred
  local p="${1:-9931}" i=0
  while (( i < 50 )); do
    port_free "$p" && { echo "$p"; return 0; }
    p=$((p + 1)); i=$((i + 1))
  done
  echo "$1"
}

have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------- preflight --
# Prints a check table; sets PLAT_OK=1/0 and PLAT_QUANT.
platform_preflight() {
  PLAT_OK=1
  PLAT_QUANT="${QUANT:-}"

  ui_step "Checking this machine"

  local arch macos ram free_gb
  arch="$(plat_arch)"
  macos="$(plat_macos)"
  ram="$(plat_ram_gb)"
  free_gb="$(plat_free_gb "$HUSHFACE_HOME")"

  # 1. architecture
  if [[ "$arch" == "arm64" ]]; then
    ui_ok "Apple Silicon ($arch), $(plat_cores) cores"
  elif [[ "$arch" == "x86_64" ]]; then
    ui_err "Intel Mac ($arch) — not supported: 27B on CPU-only Metal is unusably slow"
    PLAT_OK=0
  else
    ui_err "unknown architecture: $arch"
    PLAT_OK=0
  fi

  # 2. macOS version
  if ver_ge "$macos" "$MIN_MACOS"; then
    ui_ok "macOS $macos"
  else
    ui_err "macOS $macos is too old (need >= $MIN_MACOS)"
    PLAT_OK=0
  fi

  # 3. memory -> quant
  if [[ -n "$PLAT_QUANT" ]]; then
    local need
    need="$(quant_size_gb "$PLAT_QUANT")"
    if (( ram >= need + 6 )); then
      ui_ok "${ram} GB RAM, quant $PLAT_QUANT (${need} GB in memory)"
    else
      ui_err "${ram} GB RAM is too little for $PLAT_QUANT (${need} GB weights); try --quant Q4_K_XL"
      PLAT_QUANT=""
      PLAT_OK=0
    fi
  else
    PLAT_QUANT="$(pick_quant_for_ram "$ram")"
    if [[ -n "$PLAT_QUANT" ]]; then
      ui_ok "${ram} GB RAM -> auto-picked quant $PLAT_QUANT ($(quant_size_gb "$PLAT_QUANT") GB)"
    else
      ui_err "${ram} GB RAM — 27B does not fit. Needs >= 22 GB free of unified memory for Q4_K_XL."
      PLAT_OK=0
    fi
  fi
  if [[ -n "$PLAT_QUANT" ]] && (( ram >= 22 && ram < 30 )); then
    ui_warn "  tight: expect swapping. Close heavy apps before chatting."
  fi
  if [[ -n "$PLAT_QUANT" ]] && (( ram >= 40 && ram < 60 )); then
    ui_info "  Q8_0 (29 GB) would be closer to the trained weights; --quant Q8_0 if you keep apps closed"
  fi

  # 4. disk — only the part of the model that is not on disk yet
  if [[ -n "$PLAT_QUANT" ]]; then
    local missing_gb need_gb
    missing_gb=$(( ($(model_bytes_missing) + 1024 * 1024 * 1024 - 1) / 1024 / 1024 / 1024 ))
    need_gb=$(( missing_gb + MIN_FREE_AFTER_GB ))
    if (( free_gb >= need_gb )); then
      if (( missing_gb == 0 )); then
        ui_ok "${free_gb} GB free on $(dirname "$HUSHFACE_HOME") (model already on disk, ${need_gb} GB of room needed)"
      else
        ui_ok "${free_gb} GB free on $(dirname "$HUSHFACE_HOME") (need ${need_gb} GB: ${missing_gb} GB download + room)"
      fi
    else
      ui_err "only ${free_gb} GB free, need ${need_gb} GB in $HUSHFACE_HOME"
      PLAT_OK=0
    fi
  fi

  # 5. runtime deps
  if have curl; then ui_ok "curl $(curl --version 2>/dev/null | head -1 | awk '{print $2}')"
  else ui_err "curl missing"; PLAT_OK=0; fi


  local nv
  nv="$(node_version)"
  if bundled_runtime && [[ -n "$nv" ]]; then
    ui_ok "node $nv (bundled)"
  elif [[ -z "$nv" ]]; then
    if have brew; then
      ui_warn "node missing — will install with brew"
    else
      ui_err "node missing (pi needs >= $MIN_NODE) — install node, then re-run"
      PLAT_OK=0
    fi
  elif ver_ge "$nv" "$MIN_NODE"; then
    ui_ok "node $nv"
  else
    ui_err "node $nv is too old for pi (need >= $MIN_NODE)"
    PLAT_OK=0
  fi

  if pi_available; then
    if bundled_runtime; then ui_ok "pi $(pi_version) (bundled)"; else ui_ok "pi $(pi_version)"; fi
  else
    ui_info "pi not installed — will install"
  fi

  if find_llama >/dev/null 2>&1; then
    ui_ok "llama.cpp $(llama_version)"
  else
    ui_info "llama.cpp not installed — will install"
  fi

  return $(( PLAT_OK == 1 ? 0 : 1 ))
}
