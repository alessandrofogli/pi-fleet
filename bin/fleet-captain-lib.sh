# pi-fleet · fleet-captain-lib.sh — single-captain / wave-ownership guard (issue #13)
#
# Dual-captain problem: the system can have TWO captains on the SAME machine at
# once — the local tmux captain (fleet-captain.service / mini-captain-run.sh) and
# a REMOTE captain via pi-bridge (Pi in Pocket / iPhone over Tailscale). Both set
# PI_FLEET_CAPTAIN=1 and attach to the SAME on-disk conversation, so two
# overlapping waves can be driven with zero coordination (2026-09-06: three
# overlapping review waves).
#
# This library provides TWO independent guards, both LIGHTWEIGHT (a small
# claim/heartbeat file in the fleet state dir — NO daemon):
#
#   1. OWNERSHIP (opt-in, fail-open): before launching, verify the acting session
#      owns the captain role via a per-project claim file (captain-claim.<slug>.json)
#      that every captain session checks and heartbeats. Refuses when ANOTHER live
#      captain session holds the claim; steals only when the claim is stale.
#      ACTIVE ONLY when PI_FLEET_CAPTAIN=1. Laptops w/o pi-bridge (PI_FLEET_CAPTAIN
#      unset, no claim file) are fail-open: behavior unchanged.
#
#   2. DUPLICATE LIVE GROUP (always on, refuses only CLEAR duplicates): before
#      launching a labeled group, verify no LIVE group with the same label exists
#      for the same project with a DIFFERENT groupId. Same-wave members (same
#      groupId) and terminal waves never trigger it.
#
# Sourced with: . "$SCRIPT_DIR/fleet-captain-lib.sh"
# Provides (state home default = $FLEET_STATE_HOME or ~/.pi/fleet):
#   fleet_captain_id                 → echo stable captain session identity
#   fleet_captain_claim_path <proj>  → echo per-project claim file path
#   fleet_captain_claim_acquire <proj> → (re)write the claim + heartbeat for this session
#   fleet_captain_owns <proj>        → 0 allowed-to-launch / 1 refused (ownership guard)
#   fleet_captain_duplicate_label <proj> <groupId> <groupLabel> <taskId>
#                                    → 0 a LIVE duplicate-labeled group exists (refuse)
#                                    / 1 allowed
set -u

# state home resolution (shared with herdr-launch.sh)
captain_state() { printf '%s' "${1:-${FLEET_STATE_HOME:-$HOME/.pi/fleet}}"; }

# Stable captain identity: the pi SESSION id (unique per captain session; the local
# and remote captains have DIFFERENT ids even on the same host). Fallback when the
# launcher is run by hand: host + pid.
fleet_captain_id() {
  if [ -n "${PI_SESSION_ID:-}" ]; then
    printf '%s' "$PI_SESSION_ID"
    return 0
  fi
  printf '%s' "${PI_FLEET_CAPTAIN:+remote-}${HOSTNAME:-$(hostname 2>/dev/null || echo unknown)}-$$"
}

# Per-project claim path: captain-claim.<slug>.json under the state home.
fleet_captain_claim_path() {
  local proj="$1" state slug
  state="$(captain_state "${2:-}")"
  slug="$(printf '%s' "$proj" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-//; s/-$//' | cut -c1-48 | sed 's/-$//')"
  printf '%s/captain-claim.%s.json' "$state" "${slug:-root}"
}

# (Re)write the claim + heartbeat for the acting session (atomic tmp+rename).
fleet_captain_claim_acquire() {
  local proj="$1" state claim now
  state="$(captain_state "${2:-}")"
  claim="$(fleet_captain_claim_path "$proj" "$state")"
  mkdir -p "$state" 2>/dev/null || true
  now="$(date +%s)000"
  jq -nc --arg p "$proj" --arg s "$(fleet_captain_id)" \
    --arg h "${HOSTNAME:-$(hostname 2>/dev/null || echo unknown)}" --arg now "$now" \
    '{project:$p, sessionId:$s, host:$h, claimedAt:($now|tonumber), lastBeatAt:($now|tonumber)}' \
    > "$claim.tmp.$$" 2>/dev/null && mv "$claim.tmp.$$" "$claim" 2>/dev/null
}

# Ownership guard. Returns 0 = allowed to launch, 1 = refused.
#   - OPT-IN: active ONLY when PI_FLEET_CAPTAIN=1. Unset (laptop single-captain,
#     no pi-bridge) → always 0 (fail-open, behavior unchanged).
#   - No claim file → acquire it and allow (first captain becomes the owner).
#   - Claim owned by THIS session → refresh heartbeat, allow.
#   - Claim owned by ANOTHER session:
#       stale (lastBeatAt older than FLEET_CAPTAIN_STALE_S, default 900s) → steal, allow
#       live → REFUSE (another captain is driving waves).
fleet_captain_owns() {
  local proj="$1" state claim mine now
  state="$(captain_state "${2:-}")"
  [ "${PI_FLEET_CAPTAIN:-}" = "1" ] || return 0      # fail-open for laptops
  mine="$(fleet_captain_id)"
  claim="$(fleet_captain_claim_path "$proj" "$state")"
  if [ ! -f "$claim" ]; then
    fleet_captain_claim_acquire "$proj" "$state"
    return 0
  fi
  local owner
  owner="$(jq -r '.sessionId // empty' "$claim" 2>/dev/null || true)"
  if [ -z "$owner" ]; then
    fleet_captain_claim_acquire "$proj" "$state"   # unparseable claim → take it
    return 0
  fi
  if [ "$owner" = "$mine" ]; then
    fleet_captain_claim_acquire "$proj" "$state"   # refresh heartbeat
    return 0
  fi
  # owned by another session → stale?
  local stale_s last
  stale_s="${FLEET_CAPTAIN_STALE_S:-900}"
  case "$stale_s" in ''|*[!0-9]*) stale_s=900 ;; esac
  last="$(jq -r '.lastBeatAt // 0' "$claim" 2>/dev/null || echo 0)"
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  now="$(date +%s)000"
  if [ $(( now - last )) -gt $(( stale_s * 1000 )) ]; then
    fleet_captain_claim_acquire "$proj" "$state"   # stale → steal
    return 0
  fi
  return 1
}

# Duplicate live-group guard. Returns 0 = a LIVE same-label DIFFERENT-groupId group
# exists for the same project (REFUSE), 1 = allowed.
#   - Only triggers for labeled launches (no label → 1, allowed).
#   - Same-wave members (same groupId) are skipped.
#   - Only LIVE states count (spawning|running|needs_input): a completed wave never
#     blocks a later re-run of the same label.
#   - Scoped to the SAME project (a wave on another project never blocks).
fleet_captain_duplicate_label() {
  local proj="$1" gid="$2" label="$3" tid="$4" state
  state="$(captain_state "${5:-}")"
  [ -n "$label" ] || return 1
  [ -n "$gid" ] || return 1
  local f p l g st o
  for f in "$state"/*.json; do
    [ -f "$f" ] || continue
    case "$(basename "$f")" in
      captain-claim.*) continue ;;
    esac
    o="$(jq -r '.id // empty' "$f" 2>/dev/null || true)"
    [ -n "$o" ] || continue                                  # not a task record
    [ "$o" = "$tid" ] && continue                           # our own record
    p="$(jq -r '.project // empty' "$f" 2>/dev/null || true)"
    [ "$p" = "$proj" ] || continue                          # same project only
    l="$(jq -r '.groupLabel // empty' "$f" 2>/dev/null || true)"
    [ "$l" = "$label" ] || continue                         # same label
    g="$(jq -r '.groupId // empty' "$f" 2>/dev/null || true)"
    [ -n "$g" ] && [ "$g" = "$gid" ] && continue            # same wave member
    st="$(jq -r '.state // empty' "$f" 2>/dev/null || true)"
    case "$st" in
      spawning|running|needs_input) return 0 ;;             # LIVE → refuse
    esac
  done
  return 1
}
