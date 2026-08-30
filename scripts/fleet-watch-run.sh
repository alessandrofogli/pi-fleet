#!/usr/bin/env bash
# pi-fleet · fleet-watch-run.sh — systemd supervisor for the L3 external
# watcher (fleet-watch.service, user unit). D1 hardening: manages the
# watcher the same way the PROVEN ad-hoc wrapper did:
#
#   while true; do bash bin/fleet-watch.sh --interval 3 || true; sleep 2; done
#
# Why a wrapper is needed at all: bin/fleet-watch.sh is a singleton poll
# loop that EXITS (releasing the lock via its EXIT trap) as soon as it
# classifies an actionable task (done/needs_input/failed/health) — the
# wrapper re-spawns it after a 2s gap. `|| true` keeps the loop alive even
# on a non-zero watcher exit.
#
# No-overlap guarantee (two watchers can never run):
#   - singleton lock  ~/.pi/fleet/.watch.lock = owning PID; a new spawn
#     finds a live owner and exits `watcher: healthy` without forking;
#     stale locks (dead PID / non-numeric) are stolen atomically.
#   - self-eviction   a watcher that lost its lock exits immediately.
#   - the wrapper only re-spawns AFTER the previous watcher exited, and
#     the exit trap releases the lock first.
# Liveness beacon: .last-watcher-beat is touched every poll (~3s);
# the captain/arm checks beat age for liveness.
#
# Environment: no secrets — the watcher needs only POSIX tools (PATH below).
# FLEET_STATE_HOME defaults to ~/.pi/fleet (the mini captain's state dir);
# an EnvironmentFile is deliberately NOT used (nothing secret to inject).

set -u

export PATH=/usr/local/bin:/usr/bin:/bin

cd /home/ale/pi-fleet || { echo "fleet-watch-run: cd /home/ale/pi-fleet failed" >&2; exit 1; }

while true; do
  bash bin/fleet-watch.sh --interval 3 || true
  sleep 2
done