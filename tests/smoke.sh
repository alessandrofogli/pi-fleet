#!/usr/bin/env bash
#
# pi-fleet · smoke test end-to-end (T-008)
#
# Collauda la CATENA DI BASE del sistema su un repo scratch temporaneo:
#
#   launcher (bin/herdr-launch.sh) → pi figlio nel pane herdr (workspace "fleet",
#   sidebar only) → done-marker su disco → stato finale su disco
#
# Isolamento: FLEET_STATE_HOME punta a /tmp/fleet-smoke-state-* → nessun file
# scritto nella flotta reale (~/.pi/fleet). La workspace herdr reale viene usata
# (è il punto del test: catena reale), ma il pane/tab viene chiuso dal launcher
# al termine e lo stato su disco non è mai toccato.
#
# Uso:
#   bash tests/smoke.sh
#
# Exit codes:
#   0  verde — tutta la catena ok (state done, esito.txt con SMOKE_OK, done-marker consumato)
#   1  fallito — un check o il launcher sono falliti
#   2  prerequisiti mancanti — herdr assente o irraggiungibile, jq assente
#      (skipped documentato, MAI falso verde)
#
# Environment (tutti opzionali):
#   HERDR_SESSION          sessione herdr da usare (default: "default")
#   PI_FLEET_SMOKE_MODEL   override modello figlio, full id "provider/id"
#                          (default: catena env del launcher, es. PI_PROVIDER/PI_MODEL)
#   SMOKE_TIMEOUT_S        timeout esterno del launcher, secondi (default: 480)
#   SMOKE_KEEP=1           NON rimuovere scratch/state alla fine (debug)
#
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
LAUNCHER="$REPO_ROOT/bin/herdr-launch.sh"

TS="$(date +%s)"
TASK_ID="smoke-$TS"
SCRATCH="/tmp/fleet-smoke-$TS"
STATE_DIR="/tmp/fleet-smoke-state-$TS"
BRIEF_FILE="$STATE_DIR/brief.md"
SESSION="${HERDR_SESSION:-default}"
LAUNCH_TIMEOUT_S="${SMOKE_TIMEOUT_S:-480}"
KEEP="${SMOKE_KEEP:-0}"

log()  { printf 'SMOKE [%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die()  { printf 'SMOKE FAIL: %s\n' "$*" >&2; exit 1; }
die2() { printf 'SMOKE SKIP (exit 2): %s\n' "$*" >&2; exit 2; }

cleanup() {
  [[ "$KEEP" == "1" ]] && { log "cleanup: SMOKE_KEEP=1, lascio /tmp/fleet-smoke-$TS e /tmp/fleet-smoke-state-$TS"; return 0; }
  rm -rf "$SCRATCH" "$STATE_DIR"
}
trap cleanup EXIT

# Timeout robusto: `timeout` (GNU) o `gtimeout` (coreutils su macOS) se presenti;
# altrimenti wrapper POSIX con background + kill.
run_with_timeout() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"; return $?; fi
  if command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"; return $?; fi
  "$@" &
  local pid=$! rc
  ( sleep "$secs"; kill -TERM "$pid" 2>/dev/null ) &
  local killer=$!
  wait "$pid"; rc=$?
  kill "$killer" 2>/dev/null
  wait "$killer" 2>/dev/null   # consuma la notifica di job termination (niente "Terminated" su stderr)
  return $rc
}

# ---------------------------------------------------------------- [1/6] preflight
log "[1/6] preflight: binari, herdr raggiungibile, repo scratch"

command -v herdr >/dev/null 2>&1 || die2 "herdr non trovato in PATH — avvia herdr e riprova"
command -v jq   >/dev/null 2>&1 || die2 "jq non trovato in PATH (brew install jq)"
command -v git  >/dev/null 2>&1 || die2 "git non trovato in PATH"
[[ -f "$LAUNCHER" ]] || die "launcher non trovato: $LAUNCHER"

if ! herdr --session "$SESSION" workspace list >/dev/null 2>&1; then
  die2 "herdr non raggiungibile (sessione '$SESSION'): workspace list fallito — \
il daemon herdr è attivo? (la smoke test è SKIPPATA, non falsa verde)"
fi

mkdir -p "$SCRATCH" "$STATE_DIR"
( cd "$SCRATCH" \
    && git init -q \
    && git config user.name "fleet-smoke" \
    && git config user.email "fleet-smoke@localhost" \
    && printf '# fleet smoke scratch\n' > README.md \
    && git add README.md \
    && git commit -qm "init smoke" ) \
  || die "creazione repo scratch fallita: $SCRATCH"
log "repo scratch: $SCRATCH (commit iniziale ok)"

# ---------------------------------------------------------------- [2/6] stato isolato
log "[2/6] stato isolato: FLEET_STATE_HOME=$STATE_DIR (flotta reale ~/.pi/fleet intatta)"
export FLEET_STATE_HOME="$STATE_DIR"

# ---------------------------------------------------------------- [3/6] brief
log "[3/6] breve brief per il figlio ($BRIEF_FILE)"
cat > "$BRIEF_FILE" <<'EOF'
# T-008 smoke — task figlio minimo

Obiettivo: verificare la catena launcher → figlio → done-marker → stato su disco.
Non serve altro: questo task è volutamente banale.

1. Crea il file `esito.txt` nella ROOT del cwd (niente sottocartelle) e scrivici
   ESATTAMENTE una riga: `SMOKE_OK` + la versione di pi (esegui `pi --version`
   se utile e aggiungila). Esempio: `SMOKE_OK pi 0.84.x`

2. Termina scrivendo il done-marker nel file DONE_PATH che ti ha indicato il
   launcher, formato JSON:
   {"status":"done","summary":"...","changedFiles":["esito.txt"]}
   - summary: breve e autocontenuta, con l'esito reale (es. "SMOKE_OK su pi x.y.z — esito.txt scritto").
   - changedFiles: ["esito.txt"] (path relativo al cwd).

3. NON committare, NON fare pull/push di nessun tipo, NON chiedere input:
   scrivi i due file e termina.
EOF
log "brief scritto"

# ---------------------------------------------------------------- [4/6] launcher
MODEL_FLAG=()
if [[ -n "${PI_FLEET_SMOKE_MODEL:-}" ]]; then
  MODEL_FLAG=(--model "$PI_FLEET_SMOKE_MODEL")
  log "modello figlio (override env): $PI_FLEET_SMOKE_MODEL"
else
  log "modello figlio: catena env del launcher (PI_PROVIDER/PI_MODEL o default)"
fi

log "[4/6] lancio launcher: timeout interno 5min, timeout esterno ${LAUNCH_TIMEOUT_S}s"
run_with_timeout "$LAUNCH_TIMEOUT_S" \
  "$LAUNCHER" "smoke-$TS" "@$BRIEF_FILE" \
  --project "$SCRATCH" --no-worktree --task-id "$TASK_ID" --timeout-min 5 \
  "${MODEL_FLAG[@]+"${MODEL_FLAG[@]}"}"
RC=$?
log "[4/6] launcher uscito con exit code: $RC"
if [[ $RC -ne 0 ]]; then
  if [[ $RC -eq 143 || $RC -eq 137 ]]; then
    die "launcher terminato dal wrapper dopo ${LAUNCH_TIMEOUT_S}s (timeout esterno): \
il task non è arrivato al done-marker in tempo — controlla herdr e il pane"
  fi
  die "launcher fallito (exit $RC) — vedi log [fleet] sopra"
fi

# ---------------------------------------------------------------- [5/6] verifiche
log "[5/6] verifica esito (state json, esito.txt, done-marker consumato)"

STATE_JSON="$STATE_DIR/$TASK_ID.json"
DONE_JSON="$STATE_DIR/$TASK_ID.done.json"
ESITO_FILE="$SCRATCH/esito.txt"
FAILS=0

# 5.1 state json: esiste, state == done, summary non vuota
if [[ ! -f "$STATE_JSON" ]]; then
  FAILS=$((FAILS + 1)); log "FAIL: stato json mancante: $STATE_JSON"
else
  S="$(jq -r '.state // ""' "$STATE_JSON")"
  SUM="$(jq -r '.summary // ""' "$STATE_JSON")"
  FILES="$(jq -c '.changedFiles // []' "$STATE_JSON")"
  log "  state json: state=$S changedFiles=$FILES"
  [[ "$S" == "done" ]] || { FAILS=$((FAILS + 1)); log "FAIL: state='$S', atteso 'done'"; }
  [[ -n "$SUM" ]] || { FAILS=$((FAILS + 1)); log "FAIL: summary vuota nello state json"; }
fi

# 5.2 esito.txt nel repo scratch contiene SMOKE_OK
if [[ -f "$ESITO_FILE" ]]; then
  if grep -q "SMOKE_OK" "$ESITO_FILE" 2>/dev/null; then
    log "  esito.txt: ok (contenuto: $(tr '\n' ' ' < "$ESITO_FILE"))"
  else
    FAILS=$((FAILS + 1)); log "FAIL: esito.txt non contiene SMOKE_OK: $(cat "$ESITO_FILE")"
  fi
else
  FAILS=$((FAILS + 1)); log "FAIL: esito.txt mancante in $SCRATCH"
fi

# 5.3 done-marker consumato (il launcher lo rimuove dopo aver scritto lo stato)
if [[ -f "$DONE_JSON" ]]; then
  FAILS=$((FAILS + 1)); log "FAIL: done-marker ancora presente (non consumato): $DONE_JSON"
else
  log "  done-marker: consumato (rimosso dal launcher)"
fi

if [[ $FAILS -gt 0 ]]; then
  die "verifiche fallite: $FAILS check non passati"
fi

# ---------------------------------------------------------------- [6/6] esito
log "[6/6] tutti i check verdi"
log "ESITO: OK — catena launcher → figlio → done-marker → stato verificata (task $TASK_ID)"

# ══════════════════════════════════════════════════════════ gate T-011 ════════════════
# Scenario gate meccanico (T-011) su repo scratch dedicati con gate.yaml e
# autoPr:false (NO remote → niente PR reale). Il launcher riceve --gate direttamente
# (stesso flag che l'estensione passa quando posture=no-mistakes E gate.yaml esiste).
#
#   Case A — test rotto  → task failed, gate rosso, report presente, nessuna PR
#   Case B — test verde  → task done, gate verde, nessuna PR (autoPr false)
#
# La PR automatica vera (remote GitHub + gh-axi) è FUORI da questo smoke automatico:
# procedura manuale documentata nel summary del task e nel README.

GATE_RUN="$REPO_ROOT/bin/gate-run.sh"
[[ -f "$GATE_RUN" ]] || die "gate-run.sh non trovato: $GATE_RUN"

log "[7/9] gate (T-011): setup scratch gate.yaml + brief case A/B"
TSG="$(date +%s)"
SCRATCH_A="/tmp/fleet-gate-a-$TSG"
SCRATCH_B="/tmp/fleet-gate-b-$TSG"
STATE_A="/tmp/fleet-gate-state-a-$TSG"
STATE_B="/tmp/fleet-gate-state-b-$TSG"
BRIEF_A="$STATE_A/brief.md"
BRIEF_B="$STATE_B/brief.md"
TASK_A="gate-a-$TSG"
TASK_B="gate-b-$TSG"
mkdir -p "$STATE_A" "$STATE_B"   # serve prima dei brief (heredoc sopra); gli scratch li crea setup_gate_scratch

# cleanup esteso: anche gli scratch/state dei gate — unico EXIT trap che
# preserva il cleanup base originale (in bash l'ultimo trap EXIT sostituisce i precedenti)
_cleanup_gate() {
  [[ "$KEEP" == "1" ]] && return 0
  rm -rf "$SCRATCH_A" "$SCRATCH_B" "$STATE_A" "$STATE_B"
}
trap 'cleanup; _cleanup_gate' EXIT

setup_gate_scratch() {
  local dir="$1" state="$2"
  mkdir -p "$dir" "$state"
  # gate.yaml scritto FUORI della subshell (heredoc + &&-chain in ( ) non è
  # parsabile da bash): content = gate con autoPr false (no remote → niente PR)
  cat > "$dir/gate.yaml" <<'YEOF'
posture: no-mistakes
autoPr: false
loop:
  maxRounds: 3
checks:
  - { name: gate-test, cmd: bash gate-test.sh, kind: hard }
YEOF
  ( cd "$dir" \
      && git init -q \
      && git config user.name "fleet-smoke" \
      && git config user.email "fleet-smoke@localhost" \
      && printf '# fleet gate scratch\n' > README.md \
      && git add README.md gate.yaml \
      && git commit -qm "init gate smoke" ) \
    || die "creazione repo scratch gate fallita: $dir"
}

# ---- brief dei due case ----
cat > "$BRIEF_A" <<'EOF'
# T-011 smoke — gate ROSSO (case A)

Progetto scratch con gate.yaml: il check `gate-test` esegue `bash gate-test.sh` (hard).

1. Crea nella root del cwd il file `gate-test.sh` con questo contenuto ESATTO
   (test volutamente ROTTO — termina con exit 1):

       #!/usr/bin/env bash
       echo "gate rosso (voluto)"; exit 1

2. NON ripararlo: è il caso di verifica del gate ROSSO. Se il gate ti chiede
   di fixare, NON fixare (istruzione esplicita del brief).

3. Esegui il gate (sezione GATE della tua prompt) e poi scrivi il done-marker
   nel file DONE_PATH con status "failed" e nella summary il contenuto
   essenziale del report del gate (nomi checks + exit code + overall).

4. NON committare, NON fare push, NON aprire PR.
EOF
cat > "$BRIEF_B" <<'EOF'
# T-011 smoke — gate VERDE (case B)

Progetto scratch con gate.yaml: il check `gate-test` esegue `bash gate-test.sh` (hard).

1. Crea nella root del cwd il file `gate-test.sh` che termina con exit 0:

       #!/usr/bin/env bash
       echo "gate verde"; exit 0

2. Esegui il gate (sezione GATE della tua prompt): deve risultare VERDE al
   primo round (nessun fix necessario).

3. A verde scrivi il done-marker nel file DONE_PATH con status "done" e nel
   JSON il campo gate:
       "gate":{"passed":true,"rounds":1,"reportPath":"gate/report.json"}

4. NON committare, NON fare push, NON aprire PR.
EOF
log "  scratch A: $SCRATCH_A · scratch B: $SCRATCH_B (state isolati in /tmp)"

# ------------------------------------------------------------- [8/9] gate case A
log "[8/9] gate case A (test rotto → atteso failed, gate rosso, nessuna PR)"
setup_gate_scratch "$SCRATCH_A" "$STATE_A"
export FLEET_STATE_HOME="$STATE_A"
run_with_timeout "$LAUNCH_TIMEOUT_S" \
  "$LAUNCHER" "gate-a-$TSG" "@$BRIEF_A" \
  --project "$SCRATCH_A" --no-worktree --task-id "$TASK_A" --timeout-min 8 \
  --gate --auto-pr false \
  "${MODEL_FLAG[@]+"${MODEL_FLAG[@]}"}" \
  >/dev/null 2>&1
RC_A=$?
log "  case A: launcher exit=$RC_A"
[[ $RC_A -eq 0 ]] || die "case A: launcher fallito (exit $RC_A)"
SA="$STATE_A/$TASK_A.json"
FAILS=0
[[ -f "$SA" ]] || die "case A: state json mancante: $SA"
ST_A="$(jq -r '.state // ""' "$SA")"
GP_A="$(jq -r '.gate.passed // false' "$SA")"
PR_A="$(jq -r '.prUrl // ""' "$SA")"
log "  case A: state=$ST_A gate.passed=$GP_A prUrl='$PR_A'"
[[ "$ST_A" == "failed" ]] || { FAILS=$((FAILS + 1)); log "  FAIL: state='$ST_A', atteso failed"; }
[[ "$GP_A" == "false" ]] || { FAILS=$((FAILS + 1)); log "  FAIL: gate.passed='$GP_A', atteso false"; }
[[ -z "$PR_A" ]] || { FAILS=$((FAILS + 1)); log "  FAIL: prUrl presente='$PR_A', atteso vuoto (autoPr false)"; }
if [[ -f "$SCRATCH_A/gate/report.json" ]]; then
  REP_A="$(jq -r '.overall // ""' "$SCRATCH_A/gate/report.json")"
  log "  case A: report presente, overall=$REP_A"
  [[ "$REP_A" == "red" ]] || { FAILS=$((FAILS + 1)); log "  FAIL: overall report='$REP_A', atteso red"; }
else
  FAILS=$((FAILS + 1)); log "  FAIL: report gate mancante: $SCRATCH_A/gate/report.json"
fi
[[ $FAILS -eq 0 ]] || die "case A: $FAILS check non passati"
log "  case A OK: failed + gate rosso + report presente + nessuna PR"

# ------------------------------------------------------------- [9/9] gate case B
log "[9/9] gate case B (test verde → atteso done, gate verde, nessuna PR)"
setup_gate_scratch "$SCRATCH_B" "$STATE_B"
export FLEET_STATE_HOME="$STATE_B"
run_with_timeout "$LAUNCH_TIMEOUT_S" \
  "$LAUNCHER" "gate-b-$TSG" "@$BRIEF_B" \
  --project "$SCRATCH_B" --no-worktree --task-id "$TASK_B" --timeout-min 8 \
  --gate --auto-pr false \
  "${MODEL_FLAG[@]+"${MODEL_FLAG[@]}"}" \
  >/dev/null 2>&1
RC_B=$?
log "  case B: launcher exit=$RC_B"
[[ $RC_B -eq 0 ]] || die "case B: launcher fallito (exit $RC_B)"
SB="$STATE_B/$TASK_B.json"
FAILS=0
[[ -f "$SB" ]] || die "case B: state json mancante: $SB"
ST_B="$(jq -r '.state // ""' "$SB")"
GP_B="$(jq -r '.gate.passed // false' "$SB")"
PR_B="$(jq -r '.prUrl // ""' "$SB")"
log "  case B: state=$ST_B gate.passed=$GP_B prUrl='$PR_B'"
[[ "$ST_B" == "done" ]] || { FAILS=$((FAILS + 1)); log "  FAIL: state='$ST_B', atteso done"; }
[[ "$GP_B" == "true" ]] || { FAILS=$((FAILS + 1)); log "  FAIL: gate.passed='$GP_B', atteso true"; }
[[ -z "$PR_B" ]] || { FAILS=$((FAILS + 1)); log "  FAIL: prUrl presente='$PR_B', atteso vuoto (autoPr false)"; }
if [[ -f "$SCRATCH_B/gate/report.json" ]]; then
  REP_B="$(jq -r '.overall // ""' "$SCRATCH_B/gate/report.json")"
  log "  case B: report presente, overall=$REP_B"
  [[ "$REP_B" == "green" ]] || { FAILS=$((FAILS + 1)); log "  FAIL: overall report='$REP_B', atteso green"; }
else
  FAILS=$((FAILS + 1)); log "  FAIL: report gate mancante: $SCRATCH_B/gate/report.json"
fi
[[ $FAILS -eq 0 ]] || die "case B: $FAILS check non passati"
log "  case B OK: done + gate verde + report presente + nessuna PR"

log "ESITO GATE (T-011): OK — case A (rosso→failed, no PR) e case B (verde→done, no PR)"
exit 0