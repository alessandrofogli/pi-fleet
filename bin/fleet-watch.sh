#!/usr/bin/env bash
# pi-fleet · fleet-watch.sh — zero-token external watcher (L3), polling+classification loop
# Runs outside Pi (zero-token, restart-proof), classifies task JSON in ~/.pi/fleet
# and queues actionable wakes into .wake-queue. Singleton via fleet-lock-lib.sh.
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
mkdir -p "$STATE/.health" 2>/dev/null || true

# shellcheck source=bin/fleet-lock-lib.sh
. "$SCRIPT_DIR/fleet-lock-lib.sh"
# fleet-wake-lib.sh optional (for shared queue helpers)
if [ -f "$SCRIPT_DIR/fleet-wake-lib.sh" ]; then
  # shellcheck source=bin/fleet-wake-lib.sh
  . "$SCRIPT_DIR/fleet-wake-lib.sh" 2>/dev/null || true
fi

POLL="${FLEET_POLL:-3}"
HEARTBEAT="${FLEET_HEARTBEAT:-60}"
SIGNAL_GRACE=5

# T-019 pane-health watchdog thresholds:
#   stale window  (context not growing) before the auto-steer -> default 10 min
#   kill window   (steer not acked) before kill+relaunch     -> default 5 min
#   bash timeout  (per-command tolerance) -> per-task state.bashTimeoutS (120..300)
# Test/debug overrides (integer seconds) win over the minute defaults.
STALE_T=$(( ${FLEET_HEALTH_STALE_MIN:-10} * 60 ))
KILL_T=$(( ${FLEET_HEALTH_KILL_MIN:-5} * 60 ))
case "${FLEET_HEALTH_STALE_S:-}" in ''|*[!0-9]*) : ;; *) STALE_T=$FLEET_HEALTH_STALE_S ;; esac
case "${FLEET_HEALTH_KILL_S:-}" in ''|*[!0-9]*) : ;; *) KILL_T=$FLEET_HEALTH_KILL_S ;; esac
[ "$STALE_T" -lt 1 ] && STALE_T=1
[ "$KILL_T" -lt 1 ] && KILL_T=1

# Numeric validation (avoids arithmetic error under set -u)
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
    # stale already handled by try_acquire; retry once
    rm -f "$WATCH_LOCK" 2>/dev/null || true
    if ! fleet_lock_try_acquire 2>/dev/null; then
      printf 'watcher: healthy\n' 2>&1
      exit 0
    fi
  fi
fi

# Trap to release the lock only if owned
_fleet_watch_cleanup() {
  fleet_lock_release 2>/dev/null || true
}
trap _fleet_watch_cleanup EXIT
trap '_fleet_watch_cleanup; exit 130' INT TERM
trap '_fleet_watch_cleanup; exit 1' HUP

# --- helpers ---

# Bounded absorb log (max 500 lines) on STATE/.watch-triage.log
_fleet_triage_log() {
  local msg="$1" log="$STATE/.watch-triage.log" tmp
  mkdir -p "$STATE" 2>/dev/null || true
  printf '[%s] %s\n' "$(date +%Y-%m-%dT%H:%M:%S%z 2>/dev/null || date)" "$msg" >> "$log" 2>/dev/null || true
  # rotate at 500 lines
  if [ -f "$log" ]; then
    local n
    n=$(wc -l < "$log" 2>/dev/null | tr -d ' ') || n=0
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    if [ "$n" -gt 500 ]; then
      tmp="$log.tmp.$$"
      tail -n 500 "$log" > "$tmp" 2>/dev/null && mv "$tmp" "$log" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
    fi
  fi
  # debug on stderr (does not interfere with the reason on stdout)
  printf '[fleet-watch] %s\n' "$msg" >&2 || true
}

# Monotonic seq with lock (flock if available, otherwise mkdir lock)
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

# Queues an actionable wake: writes .wake-queue/<seq>.json and appends to .watch-deliveries.log
_fleet_enqueue_wake() {
  local taskId="$1" reason="$2"
  local seq now out tmp
  mkdir -p "$STATE/.wake-queue" 2>/dev/null || true
  seq=$(_fleet_next_seq)
  # fallback if seq is not numeric (date +%s%N)
  case "$seq" in ''|*[!0-9]*) seq=$(date +%s 2>/dev/null || echo 0) ;; esac
  now=$(date +%s 2>/dev/null || echo 0)
  case "$now" in ''|*[!0-9]*) now=0 ;; esac
  out="$STATE/.wake-queue/${seq}.json"
  # avoid collision (seq duplicated by race)
  if [ -f "$out" ]; then
    out="$STATE/.wake-queue/${seq}-$$-$(date +%s 2>/dev/null || echo 0).json"
  fi
  # jq -Rs for safe escaping
  local j_task j_reason
  j_task=$(printf '%s' "$taskId" | jq -Rs . 2>/dev/null || printf '"%s"' "$taskId")
  j_reason=$(printf '%s' "$reason" | jq -Rs . 2>/dev/null || printf '"%s"' "$reason")
  tmp="$out.tmp.$$"
  printf '{"seq":%s,"taskId":%s,"reason":%s,"createdAt":%s}\n' "$seq" "$j_task" "$j_reason" "$now" > "$tmp" 2>/dev/null && mv "$tmp" "$out" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
  # delivery log per arm attach verification: PID<TAB>reason
  printf '%s\t%s\n' "$$" "$reason" >> "$STATE/.watch-deliveries.log" 2>/dev/null || true
}

# Checks whether a wake for taskId is already queued (avoids duplicates for failed)
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

  # self-eviction: if the lock is no longer ours, another watcher took over
  if ! fleet_lock_is_owned 2>/dev/null; then
    _fleet_triage_log "lock lost (owner=$(fleet_lock_owner_pid 2>/dev/null || echo none)), exiting"
    exit 0
  fi

  _actionable=""
  _taskId_found=""
  _now=$(date +%s 2>/dev/null || echo 0)
  case "$_now" in ''|*[!0-9]*) _now=0 ;; esac
  _now_ms=$((_now * 1000))

  # One agent list per poll: shared by the pane-liveness check and the T-019
  # pane-health watchdog (revision = context-growth heartbeat). Fail soft:
  # herdr missing/down -> empty (both checks skip, nothing is killed).
  _agents=""
  if command -v herdr >/dev/null 2>&1; then
    _agents="$(herdr --session "${HERDR_SESSION:-default}" agent list 2>/dev/null || true)"
  fi

  # Scans task JSON (excludes already-filtered markers)
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
    # id validation (avoids path traversal)
    case "$_tid" in ''|*/*|*\\*) continue ;; esac

    # 1) done marker → actionable (high priority, independent of .state)
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

      # pane liveness (only if running for >30s)
      _paneId=$(jq -r '.paneId // empty' "$_f" 2>/dev/null) || _paneId=""
      if [ -n "$_paneId" ] && [ "$_startedAt" -gt 0 ]; then
        _age_ms=$((_now_ms - _startedAt))
        if [ "$_age_ms" -gt 30000 ]; then
          if [ -n "$_agents" ]; then
            if ! printf '%s' "$_agents" | jq -e --arg p "$_paneId" '[.result.agents[]? | select(.pane_id==$p)] | length > 0' >/dev/null 2>&1; then
              _actionable="stale: ${_tid} pane dead"
              _taskId_found="$_tid"
              break
            fi
          fi
          # ----- T-019 pane-health watchdog (running panes only) -----
          # Heartbeat = context growth (herdr per-agent `revision`; fallback =
          # the `agent read` transcript checksum). The 'Working…' spinner is a
          # session-state flag, NOT context growth, and never counted as alive.
          # Ladder: static for min(bashTimeoutS, staleT) -> auto-steer
          # 'abort command + commit WIP' (inbox seq + immediate prompt) and exit
          # with `health: <tid> <trigger>`; no ack for killT -> fleet-relaunch.sh
          # (salvage -> kill -> resume) and exit with `health: <tid> relaunch`.
          if [ "$_state" = "running" ] && [ ! -f "$STATE/${_tid}.relaunch" ] && [ ! -f "$STATE/${_tid}.abort" ]; then
            _hrev=""
            _hstatus=""
            if [ -n "$_agents" ]; then
              _hprobe="$(printf '%s' "$_agents" | jq -r --arg p "$_paneId" \
                '.result.agents[]? | select(.pane_id==$p) | [((.revision // "")|tostring), (.agent_status // "")] | @tsv' 2>/dev/null || true)"
              if [ -n "$_hprobe" ]; then
                _hrev="${_hprobe%%$'\t'*}"
                _hrest="${_hprobe#*$'\t'}"
                [ "$_hrest" != "$_hprobe" ] && _hstatus="$_hrest"
              fi
            fi
            if [ -z "$_hrev" ] && command -v herdr >/dev/null 2>&1; then
              _hrev="$(herdr --session "${HERDR_SESSION:-default}" agent read "$_paneId" 2>/dev/null | cksum 2>/dev/null | awk '{print $1}')"
            fi
            if [ -n "$_hrev" ]; then
              _last_file="$STATE/.health/$_tid.last"
              _prev_rev=""
              _static_since="$_now"
              _p1_seq=""
              _p1_at=""
              _p1_reason=""
              _relaunch_count=0
              if [ -f "$_last_file" ]; then
                _prev_rev="$(jq -r '.rev // ""' "$_last_file" 2>/dev/null || true)"
                _st="$(jq -r '.staticSince // empty' "$_last_file" 2>/dev/null || true)"
                case "$_st" in ''|*[!0-9]*) _st="" ;; esac
                [ -n "$_st" ] && _static_since="$_st"
                _p1_seq="$(jq -r '.p1Seq // ""' "$_last_file" 2>/dev/null || true)"
                _p1_at="$(jq -r '.p1At // ""' "$_last_file" 2>/dev/null || true)"
                _p1_reason="$(jq -r '.p1Reason // ""' "$_last_file" 2>/dev/null || true)"
                _rc="$(jq -r '.relaunchCount // 0' "$_last_file" 2>/dev/null || true)"
                case "$_rc" in ''|*[!0-9]*) _rc=0 ;; esac
                _relaunch_count="$_rc"
              fi
              # per-task bash tolerance (120..300 from the launcher; env override for tests/drills)
              _bash_t=300
              _bt="$(jq -r '.bashTimeoutS // 0' "$_f" 2>/dev/null || echo 0)"
              case "$_bt" in ''|*[!0-9]*) _bt=0 ;; esac
              [ "$_bt" -ge 120 ] && [ "$_bt" -le 300 ] && _bash_t="$_bt"
              case "${FLEET_HEALTH_BASH_TIMEOUT_S:-}" in ''|*[!0-9]*) : ;; *) _bash_t=$FLEET_HEALTH_BASH_TIMEOUT_S ;; esac
              [ "$_bash_t" -lt 1 ] && _bash_t=1
              _stale=$((_now - _static_since))
              _write_health() {
                local rev="$1" since="$2" p1s="${3:-}" p1a="${4:-}" p1r="${5:-}" rc="${6:-$_relaunch_count}"
                jq -nc --arg rev "$rev" --argjson since "$since" \
                  --argjson p1s "${p1s:-null}" --argjson p1a "${p1a:-null}" --arg p1r "$p1r" --argjson rc "$rc" \
                  '{rev:$rev, staticSince:$since, p1Seq:$p1s, p1At:$p1a, p1Reason:$p1r, relaunchCount:$rc}' \
                  > "$_last_file.tmp.$$" 2>/dev/null && mv "$_last_file.tmp.$$" "$_last_file" 2>/dev/null || true
              }
              if [ "$_prev_rev" != "$_hrev" ]; then
                # context grew -> alive: reset the staleness clock and any pending steer
                _write_health "$_hrev" "$_now"
                _fleet_triage_log "health ok: $_tid rev changed"
              elif [ -n "$_p1_seq" ]; then
                # auto-steer sent: an ack resets the timer; silence for killT -> kill+relaunch
                if [ -f "$STATE/$_tid.inbox/$_p1_seq.acked" ]; then
                  _fleet_triage_log "health recovered: $_tid acked steer #$_p1_seq — timer reset"
                  _write_health "$_hrev" "$_now"
                else
                  _p1a=${_p1_at:-0}
                  case "$_p1a" in ''|*[!0-9]*) _p1a=0 ;; esac
                  if [ $((_now - _p1a)) -ge "$KILL_T" ]; then
                    _relaunch_count=$((_relaunch_count + 1))
                    _write_health "$_hrev" "$_static_since" "" "" "" "$_relaunch_count"
                    # DETACHED: the relaunch runs the full launcher cycle; the watcher
                    # must not block on it (it exits with the health reason right away).
                    ( bash "$SCRIPT_DIR/fleet-relaunch.sh" "$_tid" \
                        --reason "T-019: no ack of steer #$_p1_seq (${_p1_reason:-frozen}) after ${KILL_T}s" \
                        >/dev/null 2>&1 & )
                    _fleet_triage_log "health relaunch invoked (detached) for $_tid (relaunch#$_relaunch_count)"
                    _actionable="health: ${_tid} relaunch"
                    _taskId_found="$_tid"
                    break
                  fi
                fi
              else
                # static context: threshold reached -> auto-steer 'abort + commit WIP'
                _trigger=""
                if [ "$_stale" -ge "$_bash_t" ] && [ "$_hstatus" = "working" ]; then
                  _trigger="bash-timeout"
                elif [ "$_stale" -ge "$STALE_T" ]; then
                  _trigger="pane-stale"
                fi
                if [ -n "$_trigger" ]; then
                  _dir="$STATE/$_tid.inbox"
                  mkdir -p "$_dir/handled" 2>/dev/null || true
                  _seq=0
                  for _f2 in "$_dir"/*.json "$_dir"/handled/*.json; do
                    [ -e "$_f2" ] || continue
                    _b2=$(basename "$_f2" .json)
                    case "$_b2" in ''|*[!0-9]*) continue ;; esac
                    [ "$_b2" -gt "$_seq" ] && _seq="$_b2"
                  done
                  _seq=$((_seq + 1))
                  _ack_path="$_dir/$_seq.acked"
                  _msg="T-019 health watchdog ($_trigger): your pane has had NO context growth for ${_stale}s (heartbeat = context growth, NOT the Working spinner). ABORT the current command if any; commit ALL work now INCLUDING untracked files (ONE COMMIT PER FILE). Then ack by creating the empty file: $_ack_path . If you are running a legitimately long command, ack immediately (this resets the watchdog timer); otherwise the pane will be KILLED and relaunched from the last WIP commit."
                  jq -nc --arg m "$_msg" --argjson at "$((_now * 1000))" --argjson seq "$_seq" \
                    '{seq:$seq, message:$m, createdAt:$at, acked:false, replays:0}' \
                    > "$_dir/$_seq.json.tmp.$$" 2>/dev/null && mv "$_dir/$_seq.json.tmp.$$" "$_dir/$_seq.json" 2>/dev/null || true
                  # immediate best-effort delivery (the captain's durable inbox re-ring also covers it)
                  if command -v herdr >/dev/null 2>&1; then
                    herdr --session "${HERDR_SESSION:-default}" agent prompt "$_paneId" "$_msg" >/dev/null 2>&1 || true
                  fi
                  _fleet_triage_log "health steer: $_tid seq=$_seq trigger=$_trigger stale=${_stale}s (pane $_paneId)"
                  _write_health "$_hrev" "$_static_since" "$_seq" "$_now" "$_trigger"
                  _actionable="health: ${_tid} ${_trigger}"
                  _taskId_found="$_tid"
                  break
                fi
              fi
            fi
          fi
        fi
      fi
      # otherwise benign → absorb, continue
    fi

    # 3) failed not yet delivered → actionable
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
    # reason on stdout for arm (delivery verification), also logged to triage
    _fleet_triage_log "actionable: $_actionable (task=$_taskId_found)"
    printf '%s\n' "$_actionable"
    exit 0
  fi

  # heartbeat scan: every HEARTBEAT sec it re-scans anyway for undetected stale
  # (the loop already scans every POLL, but here we keep last_heartbeat for logging)
  _now2=$(date +%s 2>/dev/null || echo 0)
  case "$_now2" in ''|*[!0-9]*) _now2=0 ;; esac
  if [ $((_now2 - _last_heartbeat)) -ge "$HEARTBEAT" ]; then
    _last_heartbeat=$_now2
    # T-002 (5b.2): EXTERNAL inbox re-ring — decision: BEST-EFFORT, only mention
    # it in the triage classification (log). The real re-ring/escalation is
    # in-process (extensions/fleet-inbox.ts in the captain): this bash loop must
    # never block on deliveries/acks, so no enqueue_wake here.
    _inbox_summary=""
    for _idir in "$STATE"/*.inbox; do
      [ -d "$_idir" ] || continue
      _inbox_n=0
      for _ij in "$_idir"/*.json; do
        [ -e "$_ij" ] || continue
        _ibase=${_ij%.json}
        [ -e "${_ibase}.acked" ] && continue
        _iseq=${_ibase##*/}
        case "$_iseq" in ''|*[!0-9]*) continue ;; esac
        jq -e '.seq | type == "number"' "$_ij" >/dev/null 2>&1 || continue
        _inbox_n=$((_inbox_n + 1))
      done
      if [ "$_inbox_n" -gt 0 ]; then
        _itid=$(basename "$_idir" .inbox)
        _inbox_summary="${_inbox_summary:+$_inbox_summary }${_itid}=$_inbox_n"
      fi
    done
    if [ -n "$_inbox_summary" ]; then
      _fleet_triage_log "inbox pending (best-effort; re-ring in-process): $_inbox_summary"
    fi
    # Touch also updates the implicit .last-heartbeat via beat; separate log
    _fleet_triage_log "heartbeat scan (no actionable)"
  else
    _fleet_triage_log "absorb: no actionable at ${_now}"
  fi

  sleep "$POLL" 2>/dev/null || sleep 3
done
