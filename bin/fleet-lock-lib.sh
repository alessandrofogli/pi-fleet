# pi-fleet · fleet-lock-lib.sh — lock + beacon library (L3 external watcher)
# Sourced with: . "$SCRIPT_DIR/fleet-lock-lib.sh"
# Provides: fleet_lock_try_acquire / is_owned / release / owner_pid / beat_touch / beat_age
# State: $FLEET_STATE_HOME (default ~/.pi/fleet), lock .watch.lock (PID), beat .last-watcher-beat
set -u

STATE="${FLEET_STATE_HOME:-$HOME/.pi/fleet}"
mkdir -p "$STATE" 2>/dev/null || true
WATCH_LOCK="$STATE/.watch.lock"
LAST_BEAT="$STATE/.last-watcher-beat"

# Reads the PID from the lock file (empty string if missing/unreadable).
fleet_lock_owner_pid() {
  if [ -f "$WATCH_LOCK" ]; then
    tr -d ' \t\r\n' < "$WATCH_LOCK" 2>/dev/null | head -c 32 || true
  fi
}

# Tries to acquire the singleton lock. Returns 0 if acquired, 1 if held by a live watcher.
# Stale lock handling: if the PID is not alive (kill -0 fails), steals the lock.
fleet_lock_try_acquire() {
  mkdir -p "$STATE" 2>/dev/null || true
  local owner=""
  if [ -f "$WATCH_LOCK" ]; then
    owner=$(fleet_lock_owner_pid)
    if [ -n "$owner" ]; then
      case "$owner" in
        ''|*[!0-9]*)
          # non-numeric content → stale
          rm -f "$WATCH_LOCK" 2>/dev/null || true
          owner=""
          ;;
        *)
          if kill -0 "$owner" 2>/dev/null; then
            return 1
          else
            # dead PID → stale, steal
            rm -f "$WATCH_LOCK" 2>/dev/null || true
            owner=""
          fi
          ;;
      esac
    else
      rm -f "$WATCH_LOCK" 2>/dev/null || true
    fi
  fi
  # Atomic attempt with noclobber
  if ( set -o noclobber; echo "$$" > "$WATCH_LOCK" ) 2>/dev/null; then
    return 0
  fi
  # Race: re-check stale (another process died between check and write)
  owner=$(fleet_lock_owner_pid)
  if [ -n "$owner" ]; then
    case "$owner" in
      ''|*[!0-9]*)
        rm -f "$WATCH_LOCK" 2>/dev/null || true
        ;;
      *)
        if ! kill -0 "$owner" 2>/dev/null; then
          rm -f "$WATCH_LOCK" 2>/dev/null || true
          if ( set -o noclobber; echo "$$" > "$WATCH_LOCK" ) 2>/dev/null; then
            return 0
          fi
        fi
        ;;
    esac
  fi
  return 1
}

# Checks whether the lock belongs to this PID or an ancestor (ps ppid chain, 8 levels), and whether the PID is alive.
fleet_lock_is_owned() {
  local owner
  owner=$(fleet_lock_owner_pid)
  [ -n "$owner" ] || return 1
  case "$owner" in ''|*[!0-9]*) return 1 ;; esac
  if ! kill -0 "$owner" 2>/dev/null; then
    return 1
  fi
  # self
  if [ "$owner" = "$$" ]; then
    return 0
  fi
  # BASHPID can differ from $$ in a subshell
  if [ -n "${BASHPID:-}" ] && [ "$owner" = "$BASHPID" ]; then
    return 0
  fi
  local pid cur
  pid="$$"
  for _ in 1 2 3 4 5 6 7 8; do
    cur=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' \t\r\n') || break
    [ -n "$cur" ] || break
    [ "$cur" = "1" ] && break
    if [ "$cur" = "$owner" ]; then
      return 0
    fi
    pid="$cur"
  done
  return 1
}

# Removes the lock only if owned.
fleet_lock_release() {
  if fleet_lock_is_owned 2>/dev/null; then
    rm -f "$WATCH_LOCK" 2>/dev/null || true
  fi
}

# Writes an epoch timestamp to LAST_BEAT (liveness beacon).
fleet_beat_touch() {
  mkdir -p "$STATE" 2>/dev/null || true
  date +%s > "$LAST_BEAT" 2>/dev/null || true
}

# Returns seconds since last beat (0 if the file is missing or unreadable).
fleet_beat_age() {
  if [ ! -f "$LAST_BEAT" ]; then
    printf '0\n'
    return 0
  fi
  local now beat
  now=$(date +%s 2>/dev/null) || { printf '0\n'; return 0; }
  beat=$(tr -d ' \t\r\n' < "$LAST_BEAT" 2>/dev/null) || beat=""
  case "$beat" in ''|*[!0-9]*)
    # fallback to mtime
    if [ "$(uname)" = "Darwin" ]; then
      beat=$(stat -f %m "$LAST_BEAT" 2>/dev/null || echo "$now")
    else
      beat=$(stat -c %Y "$LAST_BEAT" 2>/dev/null || echo "$now")
    fi
    ;;
  esac
  case "$beat" in ''|*[!0-9]*) printf '0\n'; return 0 ;; esac
  # clamp to 0 if beat is in the future (clock skew)
  if [ "$beat" -gt "$now" ]; then
    printf '0\n'
  else
    printf '%s\n' "$(( now - beat ))"
  fi
}
