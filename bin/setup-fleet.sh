#!/usr/bin/env bash
# pi-fleet · setup su una nuova macchina.
#
# Fa: check prerequisiti, installa l'estensione (pi install .), pi-subagents,
# scrive ~/.pi/AGENTS.md dalla policy globale (backup del file esistente),
# scrive la config pi-subagents (timeout 6h + waitTool), e stampa i passi finali.
#
# Uso:  ./bin/setup-fleet.sh
set -u

PACKAGE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOME_AGENTS="$HOME/.pi/AGENTS.md"

say()  { printf '\033[1;32m[fleet] %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[fleet] WARN %s\033[0m\n' "$*"; }
err()  { printf '\033[1;31m[fleet] ERRORE %s\033[0m\n' "$*" >&2; }

echo
say "pi-fleet setup — $(basename "$PACKAGE_DIR")"

# ------------------------------------------------------------- prerequisiti ----
echo
say "1/5 · check prerequisiti"
missing=""
for cmd in pi herdr treehouse jq python3; do
  if command -v "$cmd" >/dev/null 2>&1; then
    echo "   ✓ $cmd: $(command -v "$cmd")"
  else
    echo "   ✗ $cmd: MANCANTE"
    missing="$missing $cmd"
  fi
done
if [[ -n "$missing" ]]; then
  echo
  err "prerequisiti mancanti:$missing — installali prima di continuare (vedi README.md)."
  exit 1
fi

# herdr attivo?
if ! herdr workspace list >/dev/null 2>&1; then
  warn "herdr non raggiungibile (socket?). Avvialo prima; il setup prosegue comunque."
fi

# ------------------------------------------------------- pi install estensione ----
echo
say "2/5 · installa l'estensione pi-fleet (pi install .)"
( cd "$PACKAGE_DIR" && pi install . ) || { err "pi install . fallita"; exit 1; }

echo
say "3/5 · pi-subagents (registry background-work, consigliato)"
if pi list 2>/dev/null | grep -q pi-subagents; then
  echo "   già installato"
else
  pi install npm:pi-subagents && echo "   installato npm:pi-subagents" \
    || warn "pi-subagents non installato (l'estensione usa il fallback registry)"
fi

# --------------------------------------------------------- AGENTS.md globale ----
echo
say "4/5 · ~/.pi/AGENTS.md (policy delega pi-fleet)"
if [[ -f "$HOME_AGENTS" ]]; then
  cp "$HOME_AGENTS" "$HOME_AGENTS.bak" && echo "   backup del file esistente → $HOME_AGENTS.bak"
fi
cp "$PACKAGE_DIR/templates/AGENTS.global.md" "$HOME_AGENTS" \
  && echo "   scritto: $HOME_AGENTS (policy: delega automatica, anti-polling, wake solo failed/needs_input)"

# ------------------------------------------------- config pi-subagents (6h) ----
echo
say "5/5 · config pi-subagents (timeout 6h + waitTool)"
SUB_CFG="$HOME/.pi/agent/extensions/subagent/config.json"
mkdir -p "$(dirname "$SUB_CFG")"
if [[ -f "$SUB_CFG" ]]; then
  echo "   già presente, non tocco: $SUB_CFG"
else
  cp "$PACKAGE_DIR/templates/subagents.config.json" "$SUB_CFG" \
    && echo "   scritto: $SUB_CFG"
fi

echo
echo "──────────────────────────────────────────────────────────────────"
say "FATTO. Ultimi passi manuali:"
echo
echo "  1. Avvia herdr (se non l'hai fatto): herdr"
echo "  2. Configura il pool treehouse dei repo:"
echo "       cd <repo-path> && treehouse config --root ~/.treehouse"
echo "       treehouse add --target ."
echo "       # Example: export FLEET_PROJECTS_DIR=~/projects  (enables short names)"
echo "  3. Check the default model in ~/.pi/agent/settings.json"
echo "     if needed (children INHERIT the active model at launch)."
echo "  4. RESTART pi (extension loads at startup)."
echo "  5. Try:  look at my-project and give me a README summary"
echo
echo "  Log di debug: ~/.pi/fleet/<task-id>.log   · stato: ~/.pi/fleet/"
echo "──────────────────────────────────────────────────────────────────"