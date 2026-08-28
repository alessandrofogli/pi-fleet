# pi-fleet · fleet-lock-lib.sh — libreria lock + beacon (L3 watcher esterno)
# Sourced con: . "$SCRIPT_DIR/fleet-lock-lib.sh"
# Fornisce: fleet_lock_try_acquire / is_owned / release / owner_pid / beat_touch / beat_age
# Stato: $FLEET_STATE_HOME (default ~/.pi/fleet), lock .watch.lock (PID), beat .last-watcher-beat
set -u

STATE="${FLEET_STATE_HOME:-$HOME/.pi/fleet}"
mkdir -p "$STATE" 2>/dev/null || true
WATCH_LOCK="$STATE/.watch.lock"
LAST_BEAT="$STATE/.last-watcher-beat"

# Legge PID dal lock file (stringa vuota se mancante/illecibile).
fleet_lock_owner_pid() {
  if [ -f "$WATCH_LOCK" ]; then
    tr -d ' \t\r\n' < "$WATCH_LOCK" 2>/dev/null | head -c 32 || true
  fi
}

# Tenta di acquisire il lock singleton. Ritorna 0 se acquisito, 1 se occupato da watcher vivo.
# Gestione stale lock: se PID non vivo (kill -0 fallisce), ruba il lock.
fleet_lock_try_acquire() {
  mkdir -p "$STATE" 2>/dev/null || true
  local owner=""
  if [ -f "$WATCH_LOCK" ]; then
    owner=$(fleet_lock_owner_pid)
    if [ -n "$owner" ]; then
      case "$owner" in
        ''|*[!0-9]*)
          # contenuto non numerico → stale
          rm -f "$WATCH_LOCK" 2>/dev/null || true
          owner=""
          ;;
        *)
          if kill -0 "$owner" 2>/dev/null; then
            return 1
          else
            # PID morto → stale, ruba
            rm -f "$WATCH_LOCK" 2>/dev/null || true
            owner=""
          fi
          ;;
      esac
    else
      rm -f "$WATCH_LOCK" 2>/dev/null || true
    fi
  fi
  # Tentativo atomico con noclobber
  if ( set -o noclobber; echo "$$" > "$WATCH_LOCK" ) 2>/dev/null; then
    return 0
  fi
  # Race: ricontrolla stale (altro processo morto tra check e write)
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

# Verifica se il lock appartiene a questo PID o a un antenato (ps ppid chain, 8 livelli), e se PID vivo.
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
  # BASHPID può differire da $$ in subshell
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

# Rimuove il lock solo se owned.
fleet_lock_release() {
  if fleet_lock_is_owned 2>/dev/null; then
    rm -f "$WATCH_LOCK" 2>/dev/null || true
  fi
}

# Scrive timestamp epoch su LAST_BEAT (beacon liveness).
fleet_beat_touch() {
  mkdir -p "$STATE" 2>/dev/null || true
  date +%s > "$LAST_BEAT" 2>/dev/null || true
}

# Ritorna secondi da ultimo beat (0 se file mancante o illeggibile).
fleet_beat_age() {
  if [ ! -f "$LAST_BEAT" ]; then
    printf '0\n'
    return 0
  fi
  local now beat
  now=$(date +%s 2>/dev/null) || { printf '0\n'; return 0; }
  beat=$(tr -d ' \t\r\n' < "$LAST_BEAT" 2>/dev/null) || beat=""
  case "$beat" in ''|*[!0-9]*)
    # fallback a mtime
    if [ "$(uname)" = "Darwin" ]; then
      beat=$(stat -f %m "$LAST_BEAT" 2>/dev/null || echo "$now")
    else
      beat=$(stat -c %Y "$LAST_BEAT" 2>/dev/null || echo "$now")
    fi
    ;;
  esac
  case "$beat" in ''|*[!0-9]*) printf '0\n'; return 0 ;; esac
  # clamp a 0 se beat nel futuro (clock skew)
  if [ "$beat" -gt "$now" ]; then
    printf '0\n'
  else
    printf '%s\n' "$(( now - beat ))"
  fi
}
