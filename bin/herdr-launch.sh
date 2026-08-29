#!/usr/bin/env bash
# pi-fleet · launcher task (CLI per M1, chiamato dall'estensione per M2+).
#
# Spawna un sub-agent "visibile": crea un pane herdr reale (split laterale
# nel tab corrente del chiamante) con pi dentro, gli passa un brief, e al
# completamento (done-marker su disco) riporta il risultato, chiude il pane e
# rilascia la worktree.
#
# Uso:
#   bin/herdr-launch.sh "<titolo>" "<brief>" [flags]
#   bin/herdr-launch.sh "<titolo>" @file-brief.md [flags]
#
# Flags:
#   --project <path>     repo di lavoro (default: dir corrente)
#   --no-worktree        disabilita treehouse (default: worktree SÌ)
#   --timeout-min <n>    timeout attesa done-marker (default: 360 = 6h)
#   --task-id <id>       id task esplicito (default: generato)
#   --model <prov/mod>   override modello figlio (default: eredita dal parent)
#   --session <name>     sessione herdr (default: HERDR_SESSION | "default")
#   --debug              stampa output raw dei comandi herdr
set -u

# ---------------------------------------------------------------- config ----
FM_DEBUG=0
SESSION="${HERDR_SESSION:-default}"
PROJECT="$(pwd)"
USE_WORKTREE=1
TIMEOUT_MIN=360
TASK_ID_OVERRIDE=""
MODEL_OVERRIDE=""
GROUP_ID=""
GROUP_LABEL=""
GROUP_MODE="barrier"
TITLE=""
BRIEF=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2 ;;
    --no-worktree) USE_WORKTREE=0; shift ;;
    --timeout-min) TIMEOUT_MIN="$2"; shift 2 ;;
    --task-id) TASK_ID_OVERRIDE="$2"; shift 2 ;;
    --model) MODEL_OVERRIDE="$2"; shift 2 ;;
    --session) SESSION="$2"; shift 2 ;;
    --group-id) GROUP_ID="$2"; shift 2 ;;
    --group-label) GROUP_LABEL="$2"; shift 2 ;;
    --group-mode) GROUP_MODE="$2"; shift 2 ;;
    --debug) FM_DEBUG=1; shift ;;
    -h|--help) sed -n '1,24p' "$0"; exit 0 ;;
    *)
      if [[ -z "$TITLE" ]]; then TITLE="$1"; shift
      elif [[ -z "$BRIEF" ]]; then BRIEF="$1"; shift
      else echo "error: argomenti inattesi: $*" >&2; exit 2; fi ;;
  esac
done

[[ -z "$TITLE" ]] && { echo "error: manca il titolo" >&2; exit 2; }
if [[ "$PROJECT" == "$HOME" ]]; then
  echo "warning: nessun --project esplicito, cwd = HOME. Passa --project <path>." >&2
fi
[[ -z "$BRIEF" ]] && { echo "error: manca il brief" >&2; exit 2; }

STATE_HOME="${FLEET_STATE_HOME:-$HOME/.pi/fleet}"
mkdir -p "$STATE_HOME/tasks"

log()  { printf '[fleet] %s\n' "$*"; }
herr() { printf '[fleet] ERRORE: %s\n' "$*" >&2; }

# Marca failed su uscita prematura del launcher (tab/agent/prompt falliti):
# senza questo lo stato resta 'spawning' e il task muore SILENZIOSO (il watcher
# non wake su spawning).
fail_task() {
  local why="${1:-errore del launcher}"
  jq --arg done "$(date +%s)000" --arg sum "$why" \
    '.state="failed" | .doneAt=($done|tonumber) | .summary=$sum' "$STATE_JSON" \
    > "$STATE_JSON.tmp" 2>/dev/null && mv "$STATE_JSON.tmp" "$STATE_JSON"
}

# Aggiorna lo stato su disco in modo robusto (jq, non sed).
set_state() {
  local val="$1" done_ms="${2:-}"
  local patch=".state = \"$val\""
  [[ -n "$done_ms" ]] && patch="$patch | .doneAt = $done_ms"
  jq "$patch" "$STATE_JSON" > "$STATE_JSON.tmp" 2>/dev/null && mv "$STATE_JSON.tmp" "$STATE_JSON"
}

# Scrive pane/tab/workspace nel json DOPO il tab create (atomic).
add_pane_ids() {
  jq --arg p "$PANE_ID" --arg t "$TAB_ID" --arg w "$WORKSPACE" \
    '.paneId=$p | .tabId=$t | .workspaceId=$w' "$STATE_JSON" \
    > "$STATE_JSON.tmp" 2>/dev/null && mv "$STATE_JSON.tmp" "$STATE_JSON"
}

# Enable debugging per le chiamate herdr
herdr_cli() {
  if [[ "$FM_DEBUG" == 1 ]]; then
    echo "  → herdr $*" >&2
  fi
  herdr --session "$SESSION" "$@" 2>&1
}

# Legge un brief da file se comincia con @
if [[ "$BRIEF" == @* ]]; then
  BRIEF_FILE="${BRIEF#@}"
  [[ -f "$BRIEF_FILE" ]] || { herr "file brief non trovato: $BRIEF_FILE"; exit 2; }
  BRIEF_CONTENT="$(cat "$BRIEF_FILE")"
else
  BRIEF_CONTENT="$BRIEF"
fi

# ------------------------------------------------------- 1. workspace herdr ----
# Il figlio gira in una workspace "fleet" DEDICATA per progetto: non tocca MAI il
# workspace/tab del capitano. Da qui è visibile SOLO nella sidebar agents di herdr
# a sinistra (stato roll-up per workspace) e non occupa spazio nel tab della chat.
# Slug leggibile dal titolo (fallback quando --task-id non è passato).
slugify() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-//; s/-$//' | cut -c1-30 | sed 's/-$//'
}

TASK_ID="${TASK_ID_OVERRIDE:-$(slugify "$TITLE")-$(printf '%03d' $((RANDOM % 1000)))}"
PANE_ID=""
TAB_ID=""
# Nome agente: vincolo herdr = 1-32 char, inizia con lettera minuscola.
# Id del task (readabile, lungo) e nome agente (corto) sono SPAZZATI di proposito.
AGENT_NAME="f-$(printf '%s' "$(slugify "$TITLE")" | cut -c1-23)-$(printf '%04d' $((RANDOM % 10000)))"
log "task: $TASK_ID — $TITLE"

resolve_fleet_workspace() {
  # Workspace "fleet" DEDICATA (una sola): i figli girano qui, MAI nel
  # workspace/tab del capitano → visibili SOLO nella sidebar agents di herdr
  # (roll-up per workspace). `workspace list` NON espone la cwd, quindi il
  # match è per label; se esistono più workspace "fleet" prende la prima e
  # riusa sempre quella nei lanci successivi.
  local ws_out ws
  ws_out="$(herdr_cli workspace list)" || ws_out=""
  ws="$(printf '%s' "$ws_out" | jq -r --arg l "fleet" \
    '[.result.workspaces[]? | select(.label==$l)] | .[0].workspace_id // empty' 2>/dev/null)" \
    || ws=""
  [[ -n "$ws" ]] && { echo "$ws"; return 0; }
  for ((try = 1; try <= 3; try++)); do
    # NOTA: `workspace create` risponde con .result.workspace.workspace_id
    # (shape: .result.workspace / .result.tab / .result.root_pane).
    ws="$(herdr_cli workspace create --label "fleet" --cwd "$PROJECT" --no-focus \
      | jq -r '.result.workspace.workspace_id // empty' 2>/dev/null)" || ws=""
    [[ -n "$ws" ]] && { log "workspace fleet creata: $ws"; echo "$ws"; return 0; }
    sleep 1
    ws_out="$(herdr_cli workspace list)" || continue
    ws="$(printf '%s' "$ws_out" | jq -r --arg l "fleet" \
      '[.result.workspaces[]? | select(.label==$l)] | .[0].workspace_id // empty' 2>/dev/null)" || ws=""
    [[ -n "$ws" ]] && { echo "$ws"; return 0; }
  done
  echo ""
}


# ------------------------------------------------------- 2. worktree ----
TASK_CWD="$PROJECT"
WT_PATH=""
if [[ "$USE_WORKTREE" == 1 ]]; then
  WT_OUT="$(cd "$PROJECT" && treehouse get --lease --no-fetch --lease-holder "pi-fleet:$TASK_ID" 2>&1)" \
    || { herr "treehouse get fallito per '$PROJECT': $WT_OUT"; exit 1; }
  WT_PATH="${WT_OUT##*$'\n'}"   # il path è l'ultima riga
  [[ -d "$WT_PATH" ]] || { herr "worktree non valida: $WT_PATH"; exit 1; }
  TASK_CWD="$WT_PATH"
  log "worktree: $WT_PATH"
fi

release_worktree() {
  [[ -z "$WT_PATH" ]] && return 0
  (cd "$PROJECT" && treehouse return "$WT_PATH" 2>&1 | sed 's/^/  treehouse: /' >&2) || true
  WT_PATH=""
}

# Modello del figlio: il default di pi senza --model è il primo modello del
# catalogo (qui opencode/kimi-k2.6, senza credito). Ereditiamo quindi il modello
# della sessione main con il flag LUNGO --model (pi non ha -m; con -m fallisce).
# REGOLA: SI passa SEMPRE il full id `provider/id` — il bare id (es.
# "deepseek-v4-flash") collide tra più provider e `pi --model <bare>` parte ed
# esce in ~2.6s per ambiguità. Mai `pi --model <bare>`.
MODEL_ARGS=()
if [[ -n "$MODEL_OVERRIDE" ]]; then
  if [[ "$MODEL_OVERRIDE" == */* ]]; then
    MODEL_ARGS=(--model "$MODEL_OVERRIDE")
    log "modello figlio (override): $MODEL_OVERRIDE"
  elif [[ -n "${PI_PROVIDER:-}" ]]; then
    # override bare id: qualificato con PI_PROVIDER per non lanciare un bare id
    MODEL_ARGS=(--model "${PI_PROVIDER}/${MODEL_OVERRIDE}")
    log "modello figlio (override bare id qualificato): ${PI_PROVIDER}/${MODEL_OVERRIDE}"
  else
    # override non usabile: ignora con warning e prosegui con la catena env
    log "override scorretto ignorato: '$MODEL_OVERRIDE' è un bare id (manca PI_PROVIDER) — uso la catena env"
  fi
fi
if [[ ${#MODEL_ARGS[@]} -eq 0 ]]; then
  if [[ -n "${PI_PROVIDER:-}" && -n "${PI_MODEL:-}" ]]; then
    MODEL_ARGS=(--model "${PI_PROVIDER}/${PI_MODEL}")
    log "modello figlio: ${PI_PROVIDER}/${PI_MODEL}"
  elif [[ -n "${PI_DEFAULT_MODEL:-}" ]]; then
    MODEL_ARGS=(--model "$PI_DEFAULT_MODEL")
    log "modello figlio: $PI_DEFAULT_MODEL"
  else
    log "modello figlio: nessun modello dal parent, uso default globale"
  fi
fi

# ------------------------------------------------------- 3. stato su disco ----
STATE_JSON="$STATE_HOME/$TASK_ID.json"
BRIEF_PATH="$STATE_HOME/tasks/$TASK_ID.brief.md"
DONE_PATH="$STATE_HOME/$TASK_ID.done.json"
NEEDS_INPUT_PATH="$STATE_HOME/$TASK_ID.needs-input.json"

printf '%s\n' "$BRIEF_CONTENT" > "$BRIEF_PATH"
# L3.5 group fields — GROUP_ID vuoto → usa TASK_ID (singolo), GROUP_SIZE placeholder 1
EFFECTIVE_GROUP_ID="${GROUP_ID:-$TASK_ID}"
cat > "$STATE_JSON.tmp" <<EOF
{
  "id": "$TASK_ID",
  "title": $(jq -Rn --arg v "$TITLE" '$v'),
  "project": "$PROJECT",
  "worktree": ${USE_WORKTREE},
  "cwd": "$TASK_CWD",
  "briefFile": "$BRIEF_PATH",
  "state": "spawning",
  "startedAt": $(date +%s)000,
  "lastBeatAt": $(date +%s)000,
  "doneAt": null,
  "timeoutMs": $((TIMEOUT_MIN * 60000)),
  "groupId": $(jq -Rn --arg v "$EFFECTIVE_GROUP_ID" '$v'),
  "groupSize": 1,
  "groupLabel": $(jq -Rn --arg v "${GROUP_LABEL:-}" '$v'),
  "groupMode": "${GROUP_MODE:-barrier}"
}
EOF
mv "$STATE_JSON.tmp" "$STATE_JSON"  # atomico: niente letture a metà da parte del watcher
log "stato: $STATE_JSON"
if [[ -n "${GROUP_ID:-}" ]]; then log "gruppo: $GROUP_ID ($GROUP_MODE)"; fi

# ------------------------------------------------------- 4. tab herdr (sidebar-only) ----
# I figli girano nel workspace "fleet" dedicato (mai nel tab del capitano) in un
# tab `--no-focus`: non rubano il focus, NON occupano spazio nel tab della chat e
# NON appaiono nella tab bar del capitano — sono visibili SOLO nella sidebar
# agents di herdr a sinistra (stato roll-up per workspace) finché non li si apre.
# close_tab chiude tab + pane (il tab del workspace fleet è dedicato al task;
# il tab del capitano non viene MAI toccato).
close_tab() {
  if [[ -n "$TAB_ID" ]]; then
    herdr_cli tab close "$TAB_ID" >/dev/null 2>&1 && log "tab chiuso" || log "tab già chiuso"
    TAB_ID=""
  fi
  if [[ -n "$PANE_ID" ]]; then
    herdr_cli pane close "$PANE_ID" >/dev/null 2>&1 && log "pane chiuso" || log "pane già chiuso"
    PANE_ID=""
  fi
}
WORKSPACE="$(resolve_fleet_workspace)"
[[ -z "$WORKSPACE" ]] && { herr "impossibile creare/risolvere la workspace fleet"; fail_task "workspace fleet non risolvibile"; release_worktree; exit 1; }
log "workspace fleet: $WORKSPACE"
TB_OUT="$(herdr_cli tab create --workspace "$WORKSPACE" --cwd "$TASK_CWD" --label "$TASK_ID" --no-focus)"
TAB_ID="$(printf '%s' "$TB_OUT" | jq -r '.result.tab.tab_id // empty' 2>/dev/null)"
PANE_ID="$(printf '%s' "$TB_OUT" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)"
[[ -z "$TAB_ID" || -z "$PANE_ID" ]] && { herr "tab create senza tab/pane id: $TB_OUT"; fail_task "tab create fallito: $TB_OUT"; release_worktree; exit 1; }
log "tab fleet (solo sidebar): $TAB_ID | pane: $PANE_ID"
add_pane_ids

# Cleanup su errore: SEMPRE pane/tab prima di treehouse return (return uccide i
# processi nella worktree, compresa la shell del pane).
trap 'log "interrotto: pulisco..."; close_tab; release_worktree; exit 130' INT TERM

# ------------------------------------------------------- 5. avvia pi nel pane ----
# Nome agente UNICO per task (herdr rifiuta nomi duplicati: agent_name_taken) e
# retry sulle race transitorie (agent_pane_busy: pane non ancora shell disponibile
# subito dopo il tab create, tipico con lanci paralleli ravvicinati).
AS_OUT=""
OK=0
for ((try = 1; try <= 4; try++)); do
  AS_OUT="$(herdr_cli agent start "$AGENT_NAME" --kind pi --pane "$PANE_ID" -- "${MODEL_ARGS[@]}")"
  if [[ $? -eq 0 ]]; then OK=1; break; fi
  herr "agent start: tentativo $try/4 fallito: ${AS_OUT:0:160}"
  sleep 3
done
if [[ $OK -ne 1 ]]; then
  herr "agent start fallito ($AGENT_NAME): $AS_OUT"
  fail_task "agent start fallito: ${AS_OUT:0:200}"
  close_tab
  release_worktree
  exit 1
fi
log "pi avviato nel pane (readiness ok)"

# Attende che pi sia davvero pronto (idle al prompt) PRIMA del prompt:
# il prompt inviato troppo presto va nel buffer e si perde (race "typing too early").
herdr_cli agent wait "$PANE_ID" --until idle >/dev/null 2>&1 \
  || log "wait idle non confermato (procedo comunque)"
sleep 2

# ------------------------------------------------------- 6. brief al figlio ----
CHILD_PROMPT="Sei un sub-agent fleet (task $TASK_ID). Leggi il brief in:
$BRIEF_PATH

Regole:
- Esegui il task dentro il cwd corrente. NON modificare nulla fuori dal cwd.
- La worktree è in stato detached HEAD: se devi committare, crea prima un branch (git switch -c fleet/<taskid>-<slug>). NON committare mai in detached HEAD o sul branch main.
- Non interrompere l'utente: lavora in autonomia fino alla fine.
- Se ti serve un input dal capitano, scrivi il file $NEEDS_INPUT_PATH con {\"question\":\"...\",\"taskState\":\"needs_input\"} e FERMATI (niente domande in chat).
- Quando hai finito, scrivi il file $DONE_PATH in formato JSON:
{\"status\":\"done\",\"summary\":\"...\",\"changedFiles\":[\"rel/path\"]}
(su errore impedibile: {\"status\":\"failed\",\"summary\":\"...motivo...\"})
- REGOLA CRITICA sulla summary: NON è un verbale di attività. Deve contenere IL RISULTATO richiesto dal brief (punti, elenchi, risposte, decisioni), completo e autocontenuto. Chi la legge (il capitano) deve capire l'esito SENZA aprire altri file. Una riga tipo \"fatto / letto i file\" è INSUFFICIENTE: riporta nel dettaglio ciò che il brief ti chiede di produrre.
- REGOLA DI FORMATTAZIONE: scrivi la summary in Markdown strutturato — intestazioni, bullet, liste numerate, tabelle dove ha senso. NIENTE muri di prosa continua: se il testo supera poche righe, spezzalo in sezioni con titoli. L'output leggibile è parte del deliverable.
- Poi termina il turno senza chiedere nulla (questo script chiude il tab e pulisce).

Il task è: $BRIEF_CONTENT"

herdr_cli agent prompt "$PANE_ID" "$CHILD_PROMPT" >/dev/null \
  || { herr "invio brief fallito"; fail_task "invio brief al figlio fallito"; close_tab; release_worktree; exit 1; }
log "brief consegnato al figlio"

# ------------------------------------------------------- 7. attesa done-marker ----
# Liveness: se il figlio (agent nel pane) sparisce senza aver scritto marker
# (crash, tab chiuso, sessione terminata dal capitano), NON restare in attesa
# fino al timeout: dopo ~30s senza pane attivo dichiara failed con motivo.
agent_alive() {
  local out
  out="$(herdr_cli agent list 2>/dev/null)" || return 2   # herdr irraggiungibile: ignora
  jq -e --arg p "$PANE_ID" '[.result.agents[] | select(.pane_id==$p)] | length > 0' <<<"$out" >/dev/null 2>&1 && return 0
  return 1
}

set_state running
log "in attesa del completamento (timeout ${TIMEOUT_MIN}min)..."
DEADLINE=$(( $(date +%s) + TIMEOUT_MIN * 60 ))
LAST_LIVE=$(date +%s)
MISS=0
while :; do
  if [[ -f "$DONE_PATH" ]]; then
    RESULT="$(cat "$DONE_PATH")"
    STATUS="$(printf '%s' "$RESULT" | jq -r '.status // "failed"')"
    SUMMARY="$(printf '%s' "$RESULT" | jq -r '.summary // ""')"
    FILES="$(printf '%s' "$RESULT" | jq -c '.changedFiles // []')"
    log "completato: $STATUS"
    printf '
=== RISULTATO TASK %s ===
%s
=== FINE ===
' "$TASK_ID" "$RESULT"
    # scrive stato + risultato nello state json (il capitano lo vede in fleet_status)
    jq --arg st "$STATUS" --arg done "$(date +%s)000" --arg sum "$SUMMARY" --argjson files "$FILES" \
      '.state=$st | .doneAt=($done|tonumber) | .summary=$sum | .changedFiles=$files' "$STATE_JSON" \
      > "$STATE_JSON.tmp" 2>/dev/null && mv "$STATE_JSON.tmp" "$STATE_JSON"
    rm -f "$DONE_PATH"
    break
  fi
  if [[ -f "$NEEDS_INPUT_PATH" ]]; then
    log "il figlio CHIEDE INPUT (tab lasciato aperto, watcher resta in attesa)"
    set_state needs_input
    rm -f "$NEEDS_INPUT_PATH"
  fi
  if [[ -f "$STATE_HOME/$TASK_ID.abort" ]]; then
    log "abort richiesto dal capitano"
    set_state aborted
    close_tab
    release_worktree
    exit 0
  fi
  if [[ $(date +%s) -gt $DEADLINE ]]; then
    herr "timeout dopo ${TIMEOUT_MIN}min: uccido il task"
    set_state failed
    close_tab
    release_worktree
    exit 1
  fi
  # liveness: controlla ogni 15s che il pane abbia ancora l'agent attivo
  if (( $(date +%s) - LAST_LIVE >= 15 )); then
    LAST_LIVE=$(date +%s)
    agent_alive
    case $? in
      0) MISS=0 ;;
      1) MISS=$((MISS + 1)); log "figlio non rilevato nel pane ($MISS/2)" ;;
      *) : ;;                                        # herdr giù: non contare
    esac
    if (( MISS >= 2 )); then
      herr "il figlio è terminato senza done-marker (agent non più rilevato): chiudo il task"
      jq --arg done "$(date +%s)000" --arg sum "Il figlio è terminato senza scrivere il done-marker (agent/pane non più presente)." \
        '.state="failed" | .doneAt=($done|tonumber) | .summary=$sum' "$STATE_JSON" \
        > "$STATE_JSON.tmp" 2>/dev/null && mv "$STATE_JSON.tmp" "$STATE_JSON"
      close_tab
      release_worktree
      exit 1
    fi
  fi
  sleep 2
done

# ------------------------------------------------------- 8. cleanup ----
close_tab
release_worktree
log "fine $TASK_ID"