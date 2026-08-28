#!/usr/bin/env bash
# pi-fleet · fleet-watch.sh — watcher esterno zero-token (L3), loop polling+classificazione
# Esegue fuori da Pi (zero-token, restart-proof), classifica task JSON in ~/.pi/fleet
# e accoda wake actionable su .wake-queue. Singleton via fleet-lock-lib.sh.
# L3.5 group barrier: tasks with groupId barrier are buffered by the TS coordinator,
# not woken per-task. This bash watcher still exits with signal: <id>.done for each
# terminal task; the TS extension (fleet-group.ts) filters before sendMessage
# and emits a single group digest when pending==0. needs_input breaks barrier immediately.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE="${FLEET_STATE_HOME:-$HOME/.pi/fleet}"
mkdir -p "$STATE" 2>/dev/null || true
mkdir -p "$STATE/.wake-queue" 2>/dev/null || true
mkdir -p "$STATE/tasks" 2>/dev/null || true

# shellcheck source=bin/fleet-lock-lib.sh
. "$SCRIPT_DIR/fleet-lock-lib.sh"
# fleet-wake-lib.sh opzionale (per queue helpers condivisi)
if [ -f "$SCRIPT_DIR/fleet-wake-lib.sh" ]; then
  # shellcheck source=bin/fleet-wake-lib.sh
  . "$SCRIPT_DIR/fleet-wake-lib.sh" 2>/dev/null || true
fi

POLL="${FLEET_POLL:-3}"
HEARTBEAT="${FLEET_HEARTBEAT:-60}"
SIGNAL_GRACE=5

# Validazione numerica (evita arithmetic error sotto set -u)
case "$POLL" in ''|*[!0-9]*) POLL=3 ;; esac
case "$HEARTBEAT" in ''|*[!0-9]*) HEARTBEAT=60 ;; esac

# Portable stat mtime (epoch seconds)
if [ "$(uname)" = "Darwin" ]; then
  _fleet_stat_mtime() { stat -f %m "$1" 2>/dev/null; }
else
  _fleet_stat_mtime() { stat -c %Y "$1" 2>/dev/null; }
fi

# --- generation banner ---
GEN_FILE="$STATE/.watcher-generation"
GEN=""
if [ -f "$GEN_FILE" ]; then
  GEN=$(tr -d '\r\n' < "$GEN_FILE" 2>/dev/null || true)
fi
if [ -z "$GEN" ]; then
  GEN="$(date +%s)-$$"
  printf '%s\n' "$GEN" > "$GEN_FILE" 2>/dev/null || true
fi
printf 'watcher: started pid=%s recovery-generation=%s\n' "$$" "$GEN"

# --- singleton lock ---
if ! fleet_lock_try_acquire 2>/dev/null; then
  _owner=$(fleet_lock_owner_pid 2>/dev/null || true)
  if [ -n "$_owner" ] && kill -0 "$_owner" 2>/dev/null; then
    _age=$(fleet_beat_age 2>/dev/null || echo 0)
    printf 'watcher: healthy pid=%s beat_age=%ss\n' "$_owner" "$_age" 2>&1
    exit 0
  else
    # stale già gestito da try_acquire; ritenta una volta
    rm -f "$WATCH_LOCK" 2>/dev/null || true
    if ! fleet_lock_try_acquire 2>/dev/null; then
      printf 'watcher: healthy\n' 2>&1
      exit 0
    fi
  fi
fi

# Trap per rilascio lock solo se owned
_fleet_watch_cleanup() {
  fleet_lock_release 2>/dev/null || true
}
trap _fleet_watch_cleanup EXIT
trap '_fleet_watch_cleanup; exit 130' INT TERM
trap '_fleet_watch_cleanup; exit 1' HUP

# --- helpers ---

# Log absorb bounded (max 500 righe) su STATE/.watch-triage.log
_fleet_triage_log() {
  local msg="$1" log="$STATE/.watch-triage.log" tmp
  mkdir -p "$STATE" 2>/dev/null || true
  printf '[%s] %s\n' "$(date +%Y-%m-%dT%H:%M:%S%z 2>/dev/null || date)" "$msg" >> "$log" 2>/dev/null || true
  # ruota a 500 righe
  if [ -f "$log" ]; then
    local n
    n=$(wc -l < "$log" 2>/dev/null | tr -d ' ') || n=0
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    if [ "$n" -gt 500 ]; then
      tmp="$log.tmp.$$"
      tail -n 500 "$log" > "$tmp" 2>/dev/null && mv "$tmp" "$log" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
    fi
  fi
  # debug su stderr (non interferisce con reason su stdout)
  printf '[fleet-watch] %s\n' "$msg" >&2 || true
}

# Seq monotonic con lock (flock se disponibile, altrimenti mkdir lock)
_fleet_next_seq() {
  local seq_file="$STATE/.wake-seq"
  local seq=0
  if command -v flock >/dev/null 2>&1; then
    local lockf="$STATE/.wake-seq.flock"
    # usa fd 9
    exec 9>"$lockf" 2>/dev/null || { seq=$(date +%s%N 2>/dev/null || echo "$(date +%s)$$"); printf '%s' "$seq"; return 0; }
    flock 9 2>/dev/null || true
    seq=$(cat "$seq_file" 2>/dev/null | tr -d ' \t\r\n') || seq=0
    case "$seq" in ''|*[!0-9]*) seq=0 ;; esac
    seq=$(( seq + 1 ))
    printf '%s' "$seq" > "$seq_file" 2>/dev/null || true
    flock -u 9 2>/dev/null || true
    exec 9>&- 2>/dev/null || true
    printf '%s' "$seq"
  else
    local ldir="$STATE/.wake-seq.lock" i=0
    while ! mkdir "$ldir" 2>/dev/null; do
      sleep 0.02
      i=$(( i + 1 ))
      if [ "$i" -gt 50 ]; then
        seq=$(date +%s%N 2>/dev/null || echo "$(date +%s)$$")
        printf '%s' "$seq"
        return 0
      fi
    done
    seq=$(cat "$seq_file" 2>/dev/null | tr -d ' \t\r\n') || seq=0
    case "$seq" in ''|*[!0-9]*) seq=0 ;; esac
    seq=$(( seq + 1 ))
    printf '%s' "$seq" > "$seq_file" 2>/dev/null || true
    rmdir "$ldir" 2>/dev/null || true
    printf '%s' "$seq"
  fi
}

# Accoda wake actionable: scrive .wake-queue/<seq>.json e append a .watch-deliveries.log
_fleet_enqueue_wake() {
  local taskId="$1" reason="$2"
  local seq now out tmp
  mkdir -p "$STATE/.wake-queue" 2>/dev/null || true
  seq=$(_fleet_next_seq)
  # fallback se seq non numerico (date +%s%N)
  case "$seq" in ''|*[!0-9]*) seq=$(date +%s 2>/dev/null || echo 0) ;; esac
  now=$(date +%s 2>/dev/null || echo 0)
  case "$now" in ''|*[!0-9]*) now=0 ;; esac
  out="$STATE/.wake-queue/${seq}.json"
  # evita collisione (seq duplicato per race)
  if [ -f "$out" ]; then
    out="$STATE/.wake-queue/${seq}-$$-$(date +%s 2>/dev/null || echo 0).json"
  fi
  # jq -Rs per escaping sicuro
  local j_task j_reason
  j_task=$(printf '%s' "$taskId" | jq -Rs . 2>/dev/null || printf '"%s"' "$taskId")
  j_reason=$(printf '%s' "$reason" | jq -Rs . 2>/dev/null || printf '"%s"' "$reason")
  tmp="$out.tmp.$$"
  printf '{"seq":%s,"taskId":%s,"reason":%s,"createdAt":%s}\n' "$seq" "$j_task" "$j_reason" "$now" > "$tmp" 2>/dev/null && mv "$tmp" "$out" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
  # delivery log per arm attach verification: PID<TAB>reason
  printf '%s\t%s\n' "$$" "$reason" >> "$STATE/.watch-deliveries.log" 2>/dev/null || true
}

# Verifica se un wake per taskId è già in coda (evita duplicati per failed)
_fleet_already_queued() {
  local tid="$1" q qtid
  for q in "$STATE/.wake-queue"/*.json; do
    [ -e "$q" ] || continue
    qtid=$(jq -r '.taskId // empty' "$q" 2>/dev/null) || continue
    [ "$qtid" = "$tid" ] && return 0
  done
  return 1
}

# --- main loop ---

_last_heartbeat=$(date +%s 2>/dev/null || echo 0)
case "$_last_heartbeat" in ''|*[!0-9]*) _last_heartbeat=0 ;; esac

while :; do
  fleet_beat_touch 2>/dev/null || true

  # self-eviction: se il lock non è più nostro, un altro watcher ha preso over
  if ! fleet_lock_is_owned 2>/dev/null; then
    _fleet_triage_log "lock lost (owner=$(fleet_lock_owner_pid 2>/dev/null || echo none)), exiting"
    exit 0
  fi

  _actionable=""
  _taskId_found=""
  _now=$(date +%s 2>/dev/null || echo 0)
  case "$_now" in ''|*[!0-9]*) _now=0 ;; esac
  _now_ms=$((_now * 1000))

  # Scansiona task JSON (esclude marker already-filtered)
  for _f in "$STATE"/*.json; do
    [ -e "$_f" ] || continue
    _bn=$(basename "$_f" 2>/dev/null || echo "")
    case "$_bn" in
      .*) continue ;;
      *.done.json) continue ;;
      *.needs-input.json) continue ;;
      .watch*|.wake*|.last*|.heartbeat*) continue ;;
    esac
    # jq fail soft
    _state=$(jq -r '.state // empty' "$_f" 2>/dev/null) || continue
    [ -n "$_state" ] || continue
    _tid=$(jq -r '.id // empty' "$_f" 2>/dev/null) || _tid=""
    if [ -z "$_tid" ]; then
      _tid=${_bn%.json}
    fi
    # validazione id (evita path traversal)
    case "$_tid" in ''|*/*|*\\*) continue ;; esac

    # 1) done marker → actionable (priorità alta, indipendente da .state)
    if [ -f "$STATE/${_tid}.done.json" ]; then
      _actionable="signal: ${_tid}.done"
      _taskId_found="$_tid"
      break
    fi
    if [ -f "$STATE/${_tid}.needs-input.json" ]; then
      _actionable="signal: ${_tid}.needs-input"
      _taskId_found="$_tid"
      break
    fi

    # 2) running / spawning → timeout + pane liveness
    if [ "$_state" = "running" ] || [ "$_state" = "spawning" ]; then
      _startedAt=$(jq -r '.startedAt // 0' "$_f" 2>/dev/null) || _startedAt=0
      _timeoutMs=$(jq -r '.timeoutMs // 0' "$_f" 2>/dev/null) || _timeoutMs=0
      case "$_startedAt" in ''|*[!0-9]*) _startedAt=0 ;; esac
      case "$_timeoutMs" in ''|*[!0-9]*) _timeoutMs=0 ;; esac

      # timeout
      if [ "$_timeoutMs" -gt 0 ] && [ "$_startedAt" -gt 0 ]; then
        _elapsed=$((_now_ms - _startedAt))
        if [ "$_elapsed" -gt "$_timeoutMs" ]; then
          _actionable="stale: ${_tid} timeout"
          _taskId_found="$_tid"
          break
        fi
      fi

      # pane liveness (solo se running da >30s)
      _paneId=$(jq -r '.paneId // empty' "$_f" 2>/dev/null) || _paneId=""
      if [ -n "$_paneId" ] && [ "$_startedAt" -gt 0 ]; then
        _age_ms=$((_now_ms - _startedAt))
        if [ "$_age_ms" -gt 30000 ]; then
          if command -v herdr >/dev/null 2>&1; then
            _agents=$(herdr --session "${HERDR_SESSION:-default}" agent list 2>/dev/null || true)
            if [ -n "$_agents" ]; then
              if ! printf '%s' "$_agents" | jq -e --arg p "$_paneId" '[.result.agents[]? | select(.pane_id==$p)] | length > 0' >/dev/null 2>&1; then
                _actionable="stale: ${_tid} pane dead"
                _taskId_found="$_tid"
                break
              fi
            fi
          fi
        fi
      fi
      # altrimenti benign → assorbe, continua
    fi

    # 3) failed non ancora consegnato → actionable
    if [ "$_state" = "failed" ]; then
      if ! _fleet_already_queued "$_tid"; then
        _actionable="signal: ${_tid} failed"
        _taskId_found="$_tid"
        break
      fi
    fi
  done

  if [ -n "$_actionable" ]; then
    _fleet_enqueue_wake "$_taskId_found" "$_actionable"
    # reason su stdout per arm (verifica delivery), log anche su triage
    _fleet_triage_log "actionable: $_actionable (task=$_taskId_found)"
    printf '%s\n' "$_actionable"
    exit 0
  fi

  # heartbeat scan: ogni HEARTBEAT sec riscansiona comunque per stale non rilevati
  # (il loop già scansiona ogni POLL, ma qui manteniamo last_heartbeat per log)
  _now2=$(date +%s 2>/dev/null || echo 0)
  case "$_now2" in ''|*[!0-9]*) _now2=0 ;; esac
  if [ $((_now2 - _last_heartbeat)) -ge "$HEARTBEAT" ]; then
    _last_heartbeat=$_now2
    # Touch aggiorna anche .last-heartbeat implicito via beat; log separato
    _fleet_triage_log "heartbeat scan (no actionable)"
  else
    _fleet_triage_log "absorb: no actionable at ${_now}"
  fi

  sleep "$POLL" 2>/dev/null || sleep 3
done
