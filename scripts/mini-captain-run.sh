#!/usr/bin/env bash
# pi-fleet · mini-captain-run.sh — systemd launcher for the mini captain
# (pi TUI in tmux session `fleet`). D1 hardening: replaces the previous
# tmux+ad-hoc supervisor with a managed systemd unit (fleet-captain.service,
# user unit, Restart=always). See docs/mini-hardening.md.
#
# The launcher runs as the unit's MAIN process, so systemd supervises the
# whole captain lifecycle:
#   1. kills any orphaned tmux `fleet` session (idempotent start/restart),
#   2. removes STALE TRANSIENT DISPATCH MARKERS ONLY (see below),
#   3. supervises the captain in a while-true loop: pi is restarted whenever
#      the tmux session ends (pi died/exited), mirroring the proven ad-hoc
#      supervisor this replaces.
#
# The tmux session supplies the TTY pi needs: pi is a TUI and a bare systemd
# unit has no controlling terminal. `Restart=always` on the unit is the OUTER
# layer (recovers this script itself if it is ever killed); the while-true
# loop is the INNER layer (recovers pi without a systemd cycle).
#
# Environment: ONLY PATH + PI_FLEET_CAPTAIN are exported. The provider/model
# (opencode-go/deepseek-v4-flash) are NOT env: they come from pi config
# (~/.pi/agent/settings.json defaultProvider/defaultModel) and the API key
# lives in ~/.pi/agent/auth.json (mode 600). NO secrets env file is created
# (deliberate, see docs/mini-hardening.md). PI_DEFAULT_MODEL is deliberately
# NOT set (would override the config).

set -u

export PATH=/usr/local/bin:/usr/bin:/bin
export PI_FLEET_CAPTAIN=1        # captain gate: on the mini cwd is NOT $HOME

STATE="${FLEET_STATE_HOME:-$HOME/.pi/fleet}"
SESSION=fleet
TMUX_CMD="export PATH=/usr/local/bin:\$PATH; export PI_FLEET_CAPTAIN=1; cd /home/ale/pi-fleet && exec pi"

log() { echo "[fleet-captain] $(date '+%F %T') $*"; }

_on_term() {
  log "received TERM/INT — killing tmux session '$SESSION' (clean captain stop)"
  tmux kill-session -t "$SESSION" 2>/dev/null || true
  sleep 1
  exit 0
}
trap _on_term TERM INT

# 0) Idempotent start: remove a session left by a previous incarnation
#    (also covers an orphaned tmux server when KillMode=process wins a race).
tmux kill-session -t "$SESSION" 2>/dev/null || true

# 1) Stale TRANSIENT dispatch markers only. Safe because:
#    - "$STATE"/cmd-*.done.json        — dispatch return-channels of a
#      dispatch-cmd.sh that is no longer polling (it either completed and
#      --cleanup removed the trio, or it timed out); keeping them would re-wake
#      the fresh captain for a command nobody waits on.
#    - "$STATE"/cmd-*.needs-input.json — stale wake requests injected while the
#      previous captain was dead; same reasoning.
#    NEVER touched: tasks/*.brief.md, <id>.json (audit records), <id>.log,
#    <id>.inbox/, branch-outcomes.jsonl, .wake-queue/, .watch.*, captain.md.
#    NOTE: `*.done.json` of REAL tasks is NOT removed — a completed child's
#    marker may still be pending surface (watcher keys `signal: <id>.done` on
#    the FILE presence; the .wake-queue drain + state files cover the wake).
rm -f "$STATE"/cmd-*.done.json 2>/dev/null || true
rm -f "$STATE"/cmd-*.needs-input.json 2>/dev/null || true

# 2) Supervisor loop: keep the captain alive.
while true; do
  if ! tmux has-session -t "$SESSION" 2>/dev/null; then
    log "starting tmux session '$SESSION' (pi captain, bootstrap as mini-bootstrap.md)"
    tmux new-session -d -s "$SESSION" -x 200 -y 50 -c /home/ale/pi-fleet
    tmux send-keys -t "$SESSION" "$TMUX_CMD" Enter
  fi
  # Wait for the captain to exit (the session ends when the pane shell/pi dies).
  while tmux has-session -t "$SESSION" 2>/dev/null; do sleep 10; done
  log "captain session ended — restarting in 3s"
  sleep 3
done