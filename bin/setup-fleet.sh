#!/usr/bin/env bash
# pi-fleet · setup on a new machine.
#
# Does: prerequisites check, extension install (pi install .),
# writes ~/.pi/AGENTS.md from the global policy (backing up any existing file),
# configures treehouse for the projects in FLEET_PROJECTS_DIR,
# writes the sub-agent config (6h timeout + waitTool), and prints the final steps.
#
# Usage:  ./bin/setup-fleet.sh
set -u

PACKAGE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOME_AGENTS="$HOME/.pi/AGENTS.md"

say()  { printf '\033[1;32m[fleet] %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[fleet] WARN %s\033[0m\n' "$*"; }
err()  { printf '\033[1;31m[fleet] ERROR %s\033[0m\n' "$*" >&2; }

echo
say "pi-fleet setup — $(basename "$PACKAGE_DIR")"

# ------------------------------------------------------------- prerequisites ----
echo
say "1/5 · prerequisite check"
missing=""
for cmd in pi herdr treehouse jq python3; do
  if command -v "$cmd" >/dev/null 2>&1; then
    echo "   ✓ $cmd: $(command -v "$cmd")"
  else
    echo "   ✗ $cmd: MISSING"
    missing="$missing $cmd"
  fi
done
if [[ -n "$missing" ]]; then
  echo
  err "missing prerequisites:$missing — install them before continuing (see README.md)."
  exit 1
fi
echo "   ℹ  versions: see README Requirements — pi ≥ 0.84, herdr ≥ 0.8, treehouse ≥ 2.3."

# T-011: gh-axi for the gate's automatic PR — OPTIONAL, auto-install if absent
if command -v gh-axi >/dev/null 2>&1; then
  echo "   ✓ gh-axi: $(command -v gh-axi) (gate T-011 automatic PR)"
else
  echo "   … gh-axi: absent — trying to install it (npm i -g gh-axi)"
  if command -v npm >/dev/null 2>&1 && npm i -g gh-axi >/dev/null 2>&1; then
    echo "   ✓ gh-axi installed: $(command -v gh-axi)"
  else
    warn "gh-axi not installed: the delivery gate (T-011) stays active but the automatic PR (autoPr: true) is not possible. Install with: npm i -g gh-axi"
  fi
fi
# T-011: the gate and the no-mistakes engine are OPTIONAL — only for projects with gate.yaml
# and no-mistakes posture; the no-mistakes commands (impacted-checks/resolve-check) in the
# checks are optional.
echo "   ℹ  delivery gate (T-011): OPTIONAL — active only for projects with gate.yaml and"
echo "      no-mistakes posture; the no-mistakes engine in the checks (impacted-checks/resolve-check) is optional."

# herdr reachable?
if ! herdr workspace list >/dev/null 2>&1; then
  warn "herdr not reachable (socket?). Start it first; setup continues anyway."
fi

# ------------------------------------------------------- pi install extension ----
echo
say "2/5 · install the pi-fleet extension (pi install .)"
( cd "$PACKAGE_DIR" && pi install . ) || { err "pi install . failed"; exit 1; }

# --------------------------------------------------------- global AGENTS.md ----
echo
say "3/5 · ~/.pi/AGENTS.md (pi-fleet delegation policy)"
if [[ -f "$HOME_AGENTS" ]]; then
  cp "$HOME_AGENTS" "$HOME_AGENTS.bak" && echo "   backup of the existing file → $HOME_AGENTS.bak"
fi
cp "$PACKAGE_DIR/templates/AGENTS.global.md" "$HOME_AGENTS" \
  && echo "   written: $HOME_AGENTS (policy: automatic delegation, anti-polling, wake only on failed/needs_input)"

# ------------------------------------------------- treehouse auto-config ----
echo
say "4/5 · configure treehouse for the projects in FLEET_PROJECTS_DIR"
configure_treehouse_projects() {
  local root="${FLEET_PROJECTS_DIR:-}"
  if [[ -z "$root" ]]; then
    warn "FLEET_PROJECTS_DIR not set — skipping treehouse auto-config."
    echo "       Set: export FLEET_PROJECTS_DIR=~/projects  (in your ~/.zshrc or ~/.bashrc)"
    echo "       Then restart this script or configure treehouse manually per repo:"
    echo "         cd <repo> && treehouse init    # verify: treehouse status"
    return 0
  fi
  # expand ~ if present
  root="${root/#\~/$HOME}"
  if [[ ! -d "$root" ]]; then
    warn "FLEET_PROJECTS_DIR does not exist: $root — skipping."
    return 0
  fi
  # Modern treehouse (>= 2.3) registers repos with `init` (creates treehouse.toml) and
  # warms the pool with `get --lease`/`return`; very old releases used `config` + `add`.
  # Feature-detect so both work.
  local modern=0
  if treehouse init --help >/dev/null 2>&1; then modern=1; fi
  local count=0
  for dir in "$root"/*/; do
    [[ -d "$dir/.git" ]] || continue
    echo "   configuring treehouse for: $(basename "$dir")"
    if [[ "$modern" == "1" ]]; then
      if ( cd "$dir" && warm_treehouse_pool ); then
        ((count++))
      else
        warn "   failed for $(basename "$dir") — check that treehouse >= 2.3 (see README Requirements)"
      fi
    else
      ( cd "$dir" && treehouse config --root ~/.treehouse && treehouse add --target . ) \
        && ((count++)) || warn "   failed for $(basename "$dir")"
    fi
  done
  if [[ $count -eq 0 ]]; then
    warn "no git repo found in $root"
  else
    echo "   ✓ $count repos configured"
  fi
}

# Register one repo with modern treehouse (>= 2.3) and warm its pool idempotently.
# `treehouse init` on an already-initialized repo prints "treehouse.toml already exists"
# and exits 1 — that is NOT a failure. The pool is warmed only when empty, so re-runs
# never grow the pool.
warm_treehouse_pool() {
  local out rc wt
  out="$(treehouse init 2>&1)"; rc=$?
  if [[ $rc -ne 0 ]] && [[ "$out" != *"already exists"* ]]; then
    return 1
  fi
  if treehouse status 2>&1 | grep -qiE "no worktrees in pool"; then
    wt="$(treehouse get --lease --no-fetch --lease-holder pi-fleet-setup 2>/dev/null)" || return 1
    [[ -n "$wt" ]] || return 1
    treehouse return "$wt" >/dev/null 2>&1 || true
  fi
  return 0
}
configure_treehouse_projects

# ------------------------------------------------- subagent timeout config (6h) ----
echo
say "5/5 · sub-agent config 6h timeout + waitTool"
SUB_CFG="$HOME/.pi/agent/extensions/subagent/config.json"
mkdir -p "$(dirname "$SUB_CFG")"
if [[ -f "$SUB_CFG" ]]; then
  echo "   already present, not touching: $SUB_CFG"
else
  cp "$PACKAGE_DIR/templates/subagents.config.json" "$SUB_CFG" \
    && echo "   written: $SUB_CFG"
fi

echo
echo "──────────────────────────────────────────────────────────────────"
say "DONE. Final manual steps:"
echo
echo "  1. Start herdr (if you haven't): herdr   (default session)"
echo "     Requirements: pi >= 0.84 · herdr >= 0.8 · treehouse >= 2.3 · jq · python3 (see README)."
echo "  2. (Already done if FLEET_PROJECTS_DIR was set) Otherwise configure treehouse per repo:"
echo "       cd <repo-path> && treehouse init    # verify: treehouse status"
echo "  3. Recommended: export FLEET_PROJECTS_DIR=~/projects (in ~/.zshrc or ~/.bashrc) so"
echo "     fleet_launch can reference projects by short name; otherwise use absolute paths."
echo "  4. Check the default model in ~/.pi/agent/settings.json"
echo "     if needed (children INHERIT the active model at launch)."
echo "  5. Reload pi with /reload (or restart pi) — extensions and skills load at startup."
echo "  6. Smoke test:  look at my-project and give me a README summary"
echo "     (replace my-project with any repo of yours; the report lands in the chat)."
echo
echo "  Already installed by this script / package:"
echo "    - 13 fleet_* extension tools + the fleet-brief skill (pi install . / package skills/)"
echo "    - ~/.pi/AGENTS.md delegation policy (existing file backed up to AGENTS.md.bak)"
echo "    - subagent config (6h timeout + wait tool): ~/.pi/agent/extensions/subagent/config.json"
echo
echo "  Delivery gate (T-011, optional):"
echo "    - To activate it in a project: create gate.yaml at the root (see README.md §Gate)."
echo "    - The automatic PR (autoPr: true) requires gh-axi and a GitHub remote on the repo."
echo
echo "  Debug log: ~/.pi/fleet/<task-id>.log   · state: ~/.pi/fleet/"
echo "──────────────────────────────────────────────────────────────────"