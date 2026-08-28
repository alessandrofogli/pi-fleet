#!/usr/bin/env bash
# pi-fleet · setup su una nuova macchina.
#
# Fa: check prerequisiti, installa l'estensione (pi install .),
# scrive ~/.pi/AGENTS.md dalla policy globale (backup del file esistente),
# configura treehouse per i progetti in FLEET_PROJECTS_DIR,
# scrive la config sub-agent (timeout 6h + waitTool), e stampa i passi finali.
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

# --------------------------------------------------------- AGENTS.md globale ----
echo
say "3/5 · ~/.pi/AGENTS.md (policy delega pi-fleet)"
if [[ -f "$HOME_AGENTS" ]]; then
  cp "$HOME_AGENTS" "$HOME_AGENTS.bak" && echo "   backup del file esistente → $HOME_AGENTS.bak"
fi
cp "$PACKAGE_DIR/templates/AGENTS.global.md" "$HOME_AGENTS" \
  && echo "   scritto: $HOME_AGENTS (policy: delega automatica, anti-polling, wake solo failed/needs_input)"

# ------------------------------------------------- treehouse auto-config ----
echo
say "4/5 · configura treehouse per i progetti in FLEET_PROJECTS_DIR"
configure_treehouse_projects() {
  local root="${FLEET_PROJECTS_DIR:-}"
  if [[ -z "$root" ]]; then
    warn "FLEET_PROJECTS_DIR non impostato — salto auto-config treehouse."
    echo "       Imposta: export FLEET_PROJECTS_DIR=~/projects  (nel tuo ~/.zshrc o ~/.bashrc)"
    echo "       Poi riavvia questo script o esegui manualmente:"
    echo "         cd <repo> && treehouse config --root ~/.treehouse && treehouse add --target ."
    return 0
  fi
  # espandi ~ se presente
  root="${root/#\~/$HOME}"
  if [[ ! -d "$root" ]]; then
    warn "FLEET_PROJECTS_DIR non esiste: $root — salto."
    return 0
  fi
  local count=0
  for dir in "$root"/*/; do
    [[ -d "$dir/.git" ]] || continue
    echo "   configuro treehouse per: $(basename "$dir")"
    ( cd "$dir" && treehouse config --root ~/.treehouse && treehouse add --target . ) \
      && ((count++)) || warn "   fallito per $(basename "$dir")"
  done
  if [[ $count -eq 0 ]]; then
    warn "nessun repo git trovato in $root"
  else
    echo "   ✓ $count repo configurati"
  fi
}
configure_treehouse_projects

# ------------------------------------------------- config subagent timeout (6h) ----
echo
say "5/5 · config sub-agent timeout 6h + waitTool"
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
echo "  2. (Già fatto se FLEET_PROJECTS_DIR era impostato) Altrimenti configura treehouse manualmente:"
echo "       cd <repo-path> && treehouse config --root ~/.treehouse && treehouse add --target ."
echo "  3. Check the default model in ~/.pi/agent/settings.json"
echo "     if needed (children INHERIT the active model at launch)."
echo "  4. RESTART pi (extension loads at startup)."
echo "  5. Try:  look at my-project and give me a README summary"
echo
echo "  Log di debug: ~/.pi/fleet/<task-id>.log   · stato: ~/.pi/fleet/"
echo "──────────────────────────────────────────────────────────────────"