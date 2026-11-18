#!/usr/bin/env bash
# llama-server lifecycle. bash 3.2 compatible.
# shellcheck shell=bash

LOG_MAX_BYTES=$((10 * 1024 * 1024))

base_url() { printf 'http://%s:%s' "$HOST" "$PORT"; }
healthy()  { curl -sf -m 2 "$(base_url)/health" >/dev/null 2>&1; }

server_model_ids() {
  curl -sf -m 5 "$(base_url)/v1/models" 2>/dev/null | "$NODE" -e '
    let raw = "";
    process.stdin.on("data", (c) => { raw += c; });
    process.stdin.on("end", () => {
      try {
        process.stdout.write(JSON.parse(raw).data.map((m) => m.id).join(","));
      } catch { process.exit(1); }
    });' 2>/dev/null
}

rotate_log() {
  [[ -f "$LOG" ]] || return 0
  local size
  size="$(stat -f%z "$LOG" 2>/dev/null || echo 0)"
  if (( size > LOG_MAX_BYTES )); then
    mv -f "$LOG" "$LOG.1"
  fi
}

stale_pid() {
  local pid
  [[ -f "$PIDFILE" ]] || return 1
  pid="$(cat "$PIDFILE" 2>/dev/null)"
  [[ -n "$pid" ]] || { rm -f "$PIDFILE"; return 1; }
  kill -0 "$pid" 2>/dev/null || { rm -f "$PIDFILE"; return 1; }
  printf '%s' "$pid"
}

server_args() {
  local base lora
  base="$MODELS_DIR/$(base_gguf_file)"
  lora="$MODELS_DIR/$LORA_FILE"
  [[ -f "$base" ]] || die "missing base model: $base" "run: hushface  (it will finish the install)"
  [[ -f "$lora" ]] || die "missing adapter: $lora" "run: hushface  (it will finish the install)"
  SERVER_BIN="$(find_llama)" || die "llama.cpp not found" "run: hushface  (it will install it)"

  SERVER_ARGS=(-m "$base" --lora "$lora" --alias "$ALIAS"
        -c "$CTX" -ngl 99 --jinja --no-webui --parallel 1
        --host "$HOST" --port "$PORT"
        --chat-template-kwargs '{"enable_thinking": false}')
  # llama.app ships a single `llama` front-end that dispatches subcommands
  if [[ "$(basename "$SERVER_BIN")" == "llama" ]]; then
    SERVER_ARGS=(serve "${SERVER_ARGS[@]}")
  fi
}

wait_healthy() {
  local t0=$SECONDS el
  healthy && return 0
  while (( SECONDS - t0 < START_TIMEOUT )); do
    el=$(( SECONDS - t0 ))
    if healthy; then
      [[ -t 2 ]] && printf '\r%*s\r' 60 '' >&2
      return 0
    fi
    if ! stale_pid >/dev/null && [[ "${HUSHFACE_FOREGROUND:-0}" != "1" ]]; then
      [[ -t 2 ]] && printf '\r%*s\r' 60 '' >&2
      ui_err "server exited during startup"
      ui_info "last lines of $LOG:"
      tail -n 20 "$LOG" >&2
      return 1
    fi
    if [[ -t 2 ]]; then
      printf '\r%sloading 27B + adapter… %ds%s' "$C_DIM" "$el" "$C_RESET" >&2
    elif (( el % 10 == 0 )); then
      ui_info "loading… ${el}s"
    fi
    sleep 1
  done
  [[ -t 2 ]] && printf '\r%*s\r' 60 '' >&2
  ui_err "server did not become healthy in ${START_TIMEOUT}s"
  tail -n 20 "$LOG" >&2
  return 1
}

start_server() {
  if healthy; then
    local ids
    ids="$(server_model_ids)"
    if [[ "$ids" == *"$ALIAS"* ]]; then
      ui_info "model server already running on $(base_url)"
      return 0
    fi
    ui_warn "port $PORT is used by another server ($ids)"
    local p
    p="$(pick_port $((PORT + 1)))"
    ui_info "using port $p instead"
    PORT="$p"
    config_set PORT "$PORT"
  fi

  server_args
  rotate_log
  mkdir -p "$(dirname "$LOG")"
  printf '\n=== %s starting on port %s (ctx %s, %s) ===\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" "$PORT" "$CTX" "$(base_quant)" >>"$LOG"
  if [[ "${HUSHFACE_FOREGROUND:-0}" == "1" ]]; then
    exec "$SERVER_BIN" "${SERVER_ARGS[@]}" 2>&1 | tee -a "$LOG"
  fi
  nohup "$SERVER_BIN" "${SERVER_ARGS[@]}" >>"$LOG" 2>&1 &
  echo $! >"$PIDFILE"
  ui_info "starting $(basename "$SERVER_BIN") on $(base_url)"
  wait_healthy || return 1
  ui_ok "ready: $(base_url)/v1  model=$ALIAS"
}

stop_server() {
  local pid
  if pid="$(stale_pid)"; then
    kill "$pid" 2>/dev/null
    local i=0
    while (( i < 50 )) && kill -0 "$pid" 2>/dev/null; do sleep 0.2; i=$((i + 1)); done
    kill -9 "$pid" 2>/dev/null
    rm -f "$PIDFILE"
    ui_ok "stopped (pid $pid)"
    return 0
  fi
  if healthy; then
    ui_warn "a model server on $(base_url) was not started by hushface"
    ui_info "stop it with: pkill -f llama-server"
    return 1
  fi
  ui_info "not running"
  return 0
}
