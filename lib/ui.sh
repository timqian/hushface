#!/usr/bin/env bash
# Output helpers. bash 3.2 compatible (macOS /bin/bash).
# shellcheck shell=bash

if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_CYN=$'\033[36m'
else
  C_RESET=''; C_DIM=''; C_BOLD=''; C_RED=''; C_GRN=''; C_YEL=''; C_CYN=''
fi

ui_say()  { printf '%s\n' "$*"; }
ui_info() { printf '%s%s%s\n' "$C_DIM" "$*" "$C_RESET"; }
ui_ok()   { printf '%s✓%s %s\n' "$C_GRN" "$C_RESET" "$*"; }
ui_warn() { printf '%s!%s %s\n' "$C_YEL" "$C_RESET" "$*" >&2; }
ui_err()  { printf '%s✗%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
ui_step() { printf '\n%s%s%s\n' "$C_BOLD" "$*" "$C_RESET"; }

# --- spinner ---------------------------------------------------------------
UI_SPIN_PID=""
UI_SPIN_MSG=""

ui_spin_start() {
  UI_SPIN_MSG="$1"
  if [[ ! -t 2 ]]; then return 0; fi
  (
    i=0
    frames='|/-\'
    while :; do
      f=${frames:$((i % 4)):1}
      printf '\r%s%s%s %s' "$C_CYN" "$f" "$C_RESET" "$UI_SPIN_MSG" >&2
      i=$((i + 1))
      sleep 0.1
    done
  ) &
  UI_SPIN_PID=$!
}

ui_spin_stop() {
  if [[ -n "$UI_SPIN_PID" ]]; then
    kill "$UI_SPIN_PID" 2>/dev/null
    wait "$UI_SPIN_PID" 2>/dev/null
    UI_SPIN_PID=""
    if [[ -t 2 ]]; then printf '\r%*s\r' $((${#UI_SPIN_MSG} + 4)) '' >&2; fi
  fi
}

# ui_run "<what>" <logfile> <cmd...>
# Runs a long command with a spinner; hides output unless VERBOSE=1.
# On failure prints the tail of the log so the user can act on it.
ui_run() {
  local msg="$1" log="$2" rc=0
  shift 2
  mkdir -p "$(dirname "$log")"
  if [[ "${VERBOSE:-0}" == "1" ]]; then
    ui_info "$msg"
    "$@" 2>&1 | tee -a "$log"
    rc=${PIPESTATUS[0]}
    return $rc
  fi
  [[ -t 2 ]] && ui_spin_start "$msg"
  "$@" >>"$log" 2>&1
  rc=$?
  ui_spin_stop
  if (( rc != 0 )); then
    ui_err "$msg (exit $rc)"
    ui_info "last lines of $log:"
    tail -n 15 "$log" >&2
  fi
  return $rc
}

# --- prompts ---------------------------------------------------------------
# ui_confirm "question" [default:y|n]
ui_confirm() {
  local q="$1" def="${2:-y}" ans=""
  if [[ "${ASSUME_YES:-0}" == "1" ]]; then return 0; fi
  if [[ ! -t 0 ]]; then
    ui_err "needs confirmation but stdin is not a TTY — re-run with --yes"
    return 1
  fi
  if [[ "$def" == "y" ]]; then
    printf '%s [Y/n] ' "$q"
  else
    printf '%s [y/N] ' "$q"
  fi
  read -r ans
  case "$ans" in
    "") [[ "$def" == "y" ]] ;;
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

# ui_choose "question" <default-index> <label> <label> ...
# Sets UI_CHOICE to the chosen index (1-based). Falls back to the default when
# there is no terminal (CI, pipes) or --yes was passed.
export UI_CHOICE=""
ui_choose() {
  local q="$1" def="$2"
  shift 2
  local n=$#
  UI_CHOICE="$def"
  if [[ "${ASSUME_YES:-0}" == "1" ]] || [[ ! -t 0 ]]; then return 0; fi
  printf '\n%s\n' "$q"
  local i=1 label
  for label in "$@"; do
    printf '  %s) %s\n' "$i" "$label"
    i=$((i + 1))
  done
  local ans tries=0
  while (( tries < 3 )); do
    printf 'choose [1-%s] (default %s): ' "$n" "$def"
    read -r ans || return 0
    [[ -z "$ans" ]] && { UI_CHOICE="$def"; return 0; }
    if [[ "$ans" =~ ^[0-9]+$ ]] && (( ans >= 1 && ans <= n )); then
      UI_CHOICE="$ans"
      return 0
    fi
    printf '  %s is not one of 1-%s\n' "$ans" "$n"
    tries=$((tries + 1))
  done
  UI_CHOICE="$def"
  return 0
}

# --- formatting ------------------------------------------------------------
human_bytes() {
  awk -v b="${1:-0}" 'BEGIN{split("B KB MB GB TB",u," ");i=1;
    while(b>=1024 && i<5){b/=1024;i++}
    if(i==1) printf "%.0f %s",b,u[i]; else printf "%.1f %s",b,u[i]}'
}

# decimal units (1 GB = 1e9), for sizes quoted in the docs
human_bytes10() {
  awk -v b="${1:-0}" 'BEGIN{split("B KB MB GB TB",u," ");i=1;
    while(b>=1000 && i<5){b/=1000;i++}
    if(i==1) printf "%.0f %s",b,u[i]; else printf "%.1f %s",b,u[i]}'
}

human_dur() {
  awk -v s="${1:-0}" 'BEGIN{
    if(s<0||s>31536000){print "--"; exit}
    if(s<60) printf "%ds",s;
    else if(s<3600) printf "%dm%02ds",int(s/60),s%60;
    else printf "%dh%02dm",int(s/3600),int((s%3600)/60)}'
}

# ver_ge 26.7.0 22.19
ver_ge() {
  awk -v a="$1" -v b="$2" 'BEGIN{
    n=split(a,x,"."); m=split(b,y,".");
    for(i=1;i<=4;i++){p=x[i]+0; q=y[i]+0;
      if(p>q) exit 0; if(p<q) exit 1}
    exit 0}'
}
