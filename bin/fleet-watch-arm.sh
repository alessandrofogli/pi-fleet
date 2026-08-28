#!/usr/bin/env bash
# pi-fleet · watch arm — forks fleet-watch.sh as tracked child, lock + beacon, retry, recovery
#
# Port semplificato di firstmate/bin/fm-watch-arm.sh per pi-fleet (Livello 3).
# Stato su disco in STATE="${FLEET_STATE_HOME:-$HOME/.pi/fleet}" (coerente con extensions/index.ts).
# Output contract: stampa SEMPRE una riga classificabile (signal:/stale:/check:/heartbeat/watcher: ...)
# così l'estensione può classificare senza parsing fragile.
#
# Modalità:
#   (default)                      arm normale — acquisisce lock, lancia watcher figlio, classifica uscita
#   --handling-delivered GEN --watcher-pid PID   conferma consegna wake (chiamato dall'estensione prima di re-arm)
#   --restart                       forza riacquisizione (re-arm dopo close)
#   --drain-check                   solo verifica se c'è coda pending (per estensione)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLEET_ROOT="${FLEET_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FLEET_HOME="${FLEET_HOME:-$FLEET_ROOT}"
STATE="${FLEET_STATE_HOME:-$HOME/.pi/fleet}"

# Source fleet-lock-lib se presente (future L3: state/.watch.lock + beacon helpers).
if [[ -f "$SCRIPT_DIR/fleet-lock-lib.sh" ]]; then
  # shellcheck source=bin/fleet-lock-lib.sh
  source "$SCRIPT_DIR/fleet-lock-lib.sh"
fi
if [[ -f "$FLEET_ROOT/bin/fleet-lock-lib.sh" ]]; then
  # fallback path when invoked from different cwd
  :
fi

WATCH_LOCK="$STATE/.watch.lock"
BEAT="$STATE/.last-watcher-beat"
DELIVERIES="$STATE/.watch-deliveries.log"
CYCLE_LOG="$STATE/.watch-cycle-exits.log"
WATCHER_DOWN="$STATE/.watcher-down"
GENERATION_FILE="$STATE/.watcher-generation"
QUEUE_DIR="$STATE/.wake-queue"
WATCH_SCRIPT="$SCRIPT_DIR/fleet-watch.sh"
GRACE=300
CYCLE_MAX_LINES=500

mkdir -p "$STATE"

# ---------------------------------------------------------------- helpers ---
pid_alive() {
  local pid="$1"
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null
}

beacon_age() {
  local m
  if [[ "$(uname)" == "Darwin" ]]; then
    m=$(stat -f %m "$BEAT" 2>/dev/null || echo "")
  else
    m=$(stat -c %Y "$BEAT" 2>/dev/null || echo "")
  fi
  if [[ -z "$m" ]]; then echo 999999; return; fi
  echo $(( $(date +%s) - m ))
}

lock_held_by_live_other() {
  local pid
  if [[ ! -f "$WATCH_LOCK" ]]; then return 1; fi
  pid=$(cat "$WATCH_LOCK" 2>/dev/null || true)
  pid=$(printf '%s' "$pid" | tr -d '[:space:]')
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  if ! pid_alive "$pid"; then return 1; fi
  # same process → not "other"
  local me="${BASHPID:-$$}"
  if [[ "$pid" == "$me" ]] || [[ "$pid" == "$$" ]]; then return 1; fi
  # beacon stale → treat as not healthy (stale holder can be stolen)
  local age
  age=$(beacon_age)
  if [[ "$age" -ge "$GRACE" ]]; then return 1; fi
  return 0
}

acquire_lock() {
  local me="${BASHPID:-$$}"
  # Use a directory lock for atomicity with retry, then write PID file.
  local claim="$STATE/.watch.lock.claim.$me"
  # Simple: write PID to file (overwrites stale). Use mkdir for mutual exclusion briefly.
  local lockdir="$STATE/.watch.lock.acquire"
  local i=0
  while ! mkdir "$lockdir" 2>/dev/null; do
    if [[ $i -ge 10 ]]; then break; fi
    sleep 0.05
    i=$((i+1))
  done
  printf '%s\n' "$me" > "$WATCH_LOCK"
  rmdir "$lockdir" 2>/dev/null || true
  mkdir -p "$QUEUE_DIR"
}

generate_generation() {
  local gen
  gen="$(date +%s)-${BASHPID:-$$}"
  printf '%s\n' "$gen" > "$GENERATION_FILE"
  printf '%s' "$gen"
}

read_generation() {
  cat "$GENERATION_FILE" 2>/dev/null | tr -d '[:space:]' || true
}

append_delivery() {
  local watcher_pid="$1" reason="$2"
  # Tab-separated watcherPid<TAB>reason for attach verification
  printf '%s\t%s\n' "$watcher_pid" "$reason" >> "$DELIVERIES"
}

append_cycle_log() {
  local arm_pid="$1" watcher_pid="$2" exit_code="$3" reason="$4"
  local ts
  ts=$(date +%s)
  # Format: armPid<TAB>watcherPid<TAB>ts<TAB>exit_code<TAB>reason
  printf '%s\t%s\t%s\t%s\t%s\n' "$arm_pid" "$watcher_pid" "$ts" "$exit_code" "$reason" >> "$CYCLE_LOG" 2>/dev/null || true
  # Size-cap to max 500 righe
  local lines
  lines=$(wc -l < "$CYCLE_LOG" 2>/dev/null | tr -d '[:space:]')
  case "$lines" in ''|*[!0-9]*) return ;; esac
  if [[ "$lines" -gt "$CYCLE_MAX_LINES" ]]; then
    local tmp="$CYCLE_LOG.tmp.${BASHPID:-$$}"
    tail -n "$CYCLE_MAX_LINES" "$CYCLE_LOG" > "$tmp" 2>/dev/null && mv -f "$tmp" "$CYCLE_LOG" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
  fi
}

classify_output() {
  local out_file="$1"
  # Returns reason string or empty
  if grep -Eq '^(signal:|stale:|check:|heartbeat($|:))' "$out_file" 2>/dev/null; then
    grep -E '^(signal:|stale:|check:|heartbeat($|:))' "$out_file" 2>/dev/null | head -1 | tr -d '\r' | cut -c1-512
    return 0
  fi
  if grep -q 'watcher: healthy' "$out_file" 2>/dev/null; then
    echo "watcher: healthy"
    return 0
  fi
  if grep -q 'watcher: FAILED' "$out_file" 2>/dev/null; then
    grep 'watcher: FAILED' "$out_file" 2>/dev/null | head -1 | tr -d '\r' | cut -c1-512
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------- args ---
MODE="arm"
HANDLING_GEN=""
HANDLING_PID=""
DRAIN_CHECK=0
RESTART=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --handling-delivered)
      MODE="handling-delivered"
      HANDLING_GEN="${2:-}"
      if [[ "${3:-}" != "--watcher-pid" ]]; then
        echo "watcher: invalid handling delivery confirmation (missing --watcher-pid)" >&2
        exit 2
      fi
      HANDLING_PID="${4:-}"
      case "$HANDLING_GEN" in ''|*[!A-Za-z0-9._-]*) echo "watcher: invalid recovery generation" >&2; exit 2 ;; esac
      case "$HANDLING_PID" in ''|*[!0-9]*) echo "watcher: invalid watcher pid" >&2; exit 2 ;; esac
      shift 4
      if [[ $# -ne 0 ]]; then echo "watcher: unexpected handling delivery arguments" >&2; exit 2; fi
      break
      ;;
    --restart)
      RESTART=1
      shift
      ;;
    --drain-check)
      DRAIN_CHECK=1
      shift
      ;;
    --help|-h)
      sed -n '1,40p' "$0"
      exit 0
      ;;
    *)
      echo "usage: $(basename "$0") [--restart | --handling-delivered GENERATION --watcher-pid PID | --drain-check]" >&2
      exit 2
      ;;
  esac
done

# ---------------------------------------------------------------- handling-delivered ---
if [[ "$MODE" == "handling-delivered" ]]; then
  GEN_FILE=$(read_generation)
  if [[ "$GEN_FILE" != "$HANDLING_GEN" ]]; then
    echo "watcher: handling-delivered generation mismatch: expected $GEN_FILE got $HANDLING_GEN" >&2
    exit 1
  fi
  if [[ ! -f "$DELIVERIES" ]]; then
    echo "watcher: handling-delivered no delivery log" >&2
    exit 1
  fi
  # Check delivery log contains PID (tab-separated first field)
  if grep -q "^${HANDLING_PID}	" "$DELIVERIES" 2>/dev/null || grep -q "^${HANDLING_PID} " "$DELIVERIES" 2>/dev/null; then
    exit 0
  else
    # Fallback: any line containing PID
    if grep -q "$HANDLING_PID" "$DELIVERIES" 2>/dev/null; then
      exit 0
    fi
    echo "watcher: handling-delivered no delivery for pid $HANDLING_PID generation $HANDLING_GEN" >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------- drain-check ---
if [[ "$DRAIN_CHECK" == 1 ]]; then
  mkdir -p "$QUEUE_DIR"
  count=$(find "$QUEUE_DIR" -maxdepth 1 -name "*.json" -type f 2>/dev/null | wc -l | tr -d '[:space:]')
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  if [[ "$count" -gt 0 ]]; then
    echo "wake-queue: $count pending"
  else
    echo "no pending wakes"
  fi
  exit 0
fi

# ---------------------------------------------------------------- default arm ---
# 1. Verifica lock ownership (skip if --restart)
if [[ "$RESTART" -eq 0 ]] && lock_held_by_live_other; then
  holder=$(cat "$WATCH_LOCK" 2>/dev/null | tr -d '[:space:]')
  # Also verify beacon fresh already done in lock_held_by_live_other
  echo "watcher: healthy - session lock is held by another pi-fleet session (pid=$holder)"
  exit 0
fi

# 2. Acquisisci lock + queue dir
acquire_lock
ARM_PID="${BASHPID:-$$}"

# 3. Genera generation
GEN=$(generate_generation)

# 4. Lancia fleet-watch.sh come figlio tracciato (foreground, non detached)
#    Stampa header started prima di wait, così l'estensione può classificare immediatamente.
if [[ ! -x "$WATCH_SCRIPT" && ! -f "$WATCH_SCRIPT" ]]; then
  # No watcher script yet (L3 not fully installed) → report FAILED for retry
  echo "watcher: FAILED - fleet-watch.sh not found at $WATCH_SCRIPT"
  append_cycle_log "$ARM_PID" "none" 1 "missing-watch-script"
  exit 1
fi

WATCH_OUT=$(mktemp "$STATE/.watch-arm-output.XXXXXX") || {
  echo "watcher: FAILED - cannot create temp output"
  exit 1
}
cleanup_watch_out() {
  rm -f "$WATCH_OUT" 2>/dev/null || true
}
trap cleanup_watch_out EXIT INT TERM

# Fork watcher as child and wait (tracked child, not detached)
bash "$WATCH_SCRIPT" > "$WATCH_OUT" 2>&1 &
WATCHER_PID=$!
# Must print started line BEFORE wait so harness sees it
echo "watcher: started pid=$WATCHER_PID recovery-generation=$GEN"

# Touch beacon immediately so attach checks see freshness (watcher itself should also update it)
touch "$BEAT" 2>/dev/null || true

wait "$WATCHER_PID"
WATCH_EXIT=$?
# Also capture signal name if exit >128
WATCH_SIGNAL="none"
if [[ "$WATCH_EXIT" -gt 128 ]]; then
  sig_num=$((WATCH_EXIT - 128))
  WATCH_SIGNAL=$(kill -l "$sig_num" 2>/dev/null || printf '%s' "$sig_num")
fi

# 5. Classifica output
REASON=""
if REASON=$(classify_output "$WATCH_OUT"); then
  # Has a classifiable reason
  if printf '%s' "$REASON" | grep -Eq '^(signal:|stale:|check:|heartbeat)'; then
    # Actionable → append delivery, print reason, log cycle, exit 0
    append_delivery "$WATCHER_PID" "$REASON"
    printf '%s\n' "$REASON"
    append_cycle_log "$ARM_PID" "$WATCHER_PID" "$WATCH_EXIT" "$REASON"
    # Print full watcher output for debugging (after reason line, so first line stays classifiable)
    if [[ -s "$WATCH_OUT" ]]; then
      # Avoid duplicating the reason line if it's already the whole output
      cat "$WATCH_OUT" | grep -v -F "$REASON" 2>/dev/null | head -n 20 || true
    fi
    exit 0
  elif printf '%s' "$REASON" | grep -q 'watcher: healthy'; then
    # Healthy → exit 0, log
    printf '%s\n' "$REASON"
    append_cycle_log "$ARM_PID" "$WATCHER_PID" "$WATCH_EXIT" "healthy"
    exit 0
  elif printf '%s' "$REASON" | grep -q 'watcher: FAILED'; then
    printf '%s\n' "$REASON"
    append_cycle_log "$ARM_PID" "$WATCHER_PID" "$WATCH_EXIT" "failed"
    exit 1
  fi
fi

# 6. No classifiable reason → decide based on exit code
if [[ "$WATCH_EXIT" -ne 0 ]]; then
  # Non-zero without actionable → FAILED for extension retry
  echo "watcher: FAILED - watcher cycle exited $WATCH_EXIT signal=$WATCH_SIGNAL without actionable reason"
  # Also dump watcher output if any
  if [[ -s "$WATCH_OUT" ]]; then
    cat "$WATCH_OUT" | head -n 20 || true
  fi
  append_cycle_log "$ARM_PID" "$WATCHER_PID" "$WATCH_EXIT" "nonzero-exit:$WATCH_SIGNAL"
  exit 1
fi

# 7. Zero exit but no actionable reason → check delivery ledger (like firstmate close_unobserved_cycle)
#    Se watcher ha scritto delivery prima di rilasciare lock, recupera reason
if [[ -f "$DELIVERIES" ]]; then
  # Last delivery for this watcher pid
  last_reason=$(grep "^${WATCHER_PID}	" "$DELIVERIES" 2>/dev/null | tail -1 | cut -f2- || true)
  if [[ -n "$last_reason" ]]; then
    printf '%s\n' "$last_reason"
    append_cycle_log "$ARM_PID" "$WATCHER_PID" "$WATCH_EXIT" "delivery-ledger:$last_reason"
    exit 0
  fi
fi

# Empty clean exit with no delivery → FAILED (never clean empty success per arm contract)
echo "watcher: FAILED - cycle ended without an actionable reason"
if [[ -s "$WATCH_OUT" ]]; then
  cat "$WATCH_OUT" | head -n 20 || true
fi
append_cycle_log "$ARM_PID" "$WATCHER_PID" "$WATCH_EXIT" "empty-cycle"
exit 1
