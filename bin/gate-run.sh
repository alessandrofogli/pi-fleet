#!/usr/bin/env bash
# pi-fleet · gate meccanico deterministico (T-011)
#
# Esegue i checks di consegna del progetto gated (gate.yaml, o fallback se assente)
# IN ORDINE sullo stato corrente della worktree, generando un report.json per-step
# + overall green|red. Nessun AI nel gate: solo exit code di processi reali.
#
# Uso:
#   bin/gate-run.sh [--report <path>] [--json]
#
#   --report <path>   scrive il report json nel path (default: gate/report.json
#                     relativo alla root del progetto gated = cwd)
#   --json            stampa il report su stdout (per il figlio)
#
# Config (gate.yaml nella root del cwd):
#   posture: no-mistakes | autoPr: true|false | loop.maxRounds: N
#   checks:  - { name, cmd, kind: hard|advisory }
#   kind hard → ok obbligatorio (exit 0); advisory → report, non blocca.
#   Config assente → fallback: posture da postures.json (default no-mistakes),
#   autoPr false, checks default: typecheck (se tsconfig), test (se script test),
#   + git diff --check + git status pulito (hard). MAI blocca su config assente.
#
# Exit code:
#   0  green — tutti i checks hard ok
#   1  red   — almeno un check hard ha exit != 0
#   2  config/strumento mancante — un check hard ha un tool assente (fail-safe,
#      MAI falso verde); advisory mancante → solo warning, non blocca.
#
# Gira SUL COMMIT CORRENTE della worktree (cwd). Non committa, non pusha, non
# apre PR: è puramente valutativo.
set -u

REPORT=""
JSON_OUT=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --report) REPORT="$2"; shift 2 ;;
    --json) JSON_OUT=1; shift ;;
    *) printf 'error: argomento sconosciuto: %s\n' "$1" >&2; exit 2 ;;
  esac
done

PROJECT_ROOT="$(pwd)"
GATE_YAML="$PROJECT_ROOT/gate.yaml"
[[ -z "$REPORT" ]] && REPORT="gate/report.json"

# ------------------------------------------------------------ parse config ----
# Valori di default (comportamento attuale preservato in assenza di gate.yaml)
posture="no-mistakes"
autoPr="false"
maxRounds=5
declare -a CHECKS=()   # una riga per check: "name|cmd|kind"

if [[ -f "$GATE_YAML" ]]; then
  cfg_posture="$(sed -n 's/^[[:space:]]*posture:[[:space:]]*\(.*\)/\1/p' "$GATE_YAML" | head -1 | tr -d '[:space:]')"
  [[ -n "$cfg_posture" ]] && posture="$cfg_posture"
  cfg_autoPr="$(sed -n 's/^[[:space:]]*autoPr:[[:space:]]*\(.*\)/\1/p' "$GATE_YAML" | head -1 | tr -d '[:space:]')"
  [[ -n "$cfg_autoPr" ]] && autoPr="$cfg_autoPr"
  cfg_rounds="$(sed -n 's/^[[:space:]]*maxRounds:[[:space:]]*\(.*\)/\1/p' "$GATE_YAML" | head -1 | tr -d '[:space:]')"
  [[ -n "$cfg_rounds" ]] && [[ "$cfg_rounds" =~ ^[0-9]+$ ]] && maxRounds="$cfg_rounds"
  # checks: righe "- { name: X, cmd: Y, kind: Z }"
  while IFS= read -r line; do
    trimmed="${line#"${line%%[![:space:]]*}"}"
    case "$trimmed" in
      "- {"*)
        name="$(printf '%s' "$line" | sed -n 's/.*name:[[:space:]]*\([^,]*\).*/\1/p' | tr -d '[:space:]')"
        cmd="$(printf '%s' "$line" | sed -n 's/.*cmd:[[:space:]]*\(.*\),[[:space:]]*kind:.*/\1/p')"
        kind="$(printf '%s' "$line" | sed -n 's/.*kind:[[:space:]]*\([a-z-]*\).*/\1/p' | tr -d '[:space:]')"
        [[ -n "$name" && -n "$cmd" ]] && CHECKS+=( "$name|$cmd|$kind" )
        ;;
    esac
  done < "$GATE_YAML"
fi

# Fallback: config assente → checks default (hard), MAI bloccante
if [[ ${#CHECKS[@]} -eq 0 ]]; then
  if [[ -f "$PROJECT_ROOT/tsconfig.json" ]]; then
    CHECKS+=( "typecheck|npx tsc --noEmit|hard" )
  fi
  if [[ -f "$PROJECT_ROOT/package.json" ]] && grep -qE '"test"[[:space:]]*:' "$PROJECT_ROOT/package.json"; then
    CHECKS+=( "test|npm test|hard" )
  fi
  CHECKS+=( "diffcheck|git diff --check|hard" )
  CHECKS+=( "clean|out=\$(git status --porcelain); [ -z \"\$out\" ]|hard" )
fi

# ------------------------------------------------------------- run checks ----
# tool disponibile? Solo per cmd che inizia con un nome semplice (niente operatori
# shell: in quei casi non falsifica il rilevamento).
tool_available() {
  local first="$1"
  if [[ "$first" == */* ]]; then [[ -x "$first" ]]; return $?; fi
  command -v "$first" >/dev/null 2>&1
}
first_word() { printf '%s' "$1" | awk '{print $1}'; }
is_simple_cmd() { [[ "$1" =~ ^[A-Za-z0-9_./-]+([[:space:]]|$) ]]; }

has_hard_fail=0     # qualche hard check rosso (exit != 0) → exit 1
has_hard_missing=0  # qualche hard check con tool mancante → exit 2
n=0
declare -a NAMES=() CMDS=() KINDS=() EXITS=() OKS=() MSGS=()

for entry in "${CHECKS[@]}"; do
  name="${entry%%|*}"; rest="${entry#*|}"
  cmd="${rest%%|*}"; kind="${rest#*|}"
  n=$((n + 1))
  code=0
  msg=""
  fw="$(first_word "$cmd")"
  if is_simple_cmd "$fw" && ! tool_available "$fw"; then
    code=2
    msg="tool mancante: $fw"
    if [[ "$kind" == "hard" ]]; then
      has_hard_missing=1
      printf '[gate] check %s: %s (fail-safe, MAI falso verde)\n' "$name" "$msg" >&2
    else
      printf '[gate] advisory %s: %s (warning, non blocca)\n' "$name" "$msg" >&2
    fi
  else
    out="$(bash -c "$cmd" 2>&1)"
    code=$?
    if [[ -n "$out" ]]; then
      # strizza: newline → spazio, ANSI codes via, tronca
      msg="$(printf '%s' "$out" | sed 's/\x1b\[[0-9;]*m//g' | tr '\n' ' ' | cut -c1-160)"
    fi
  fi
  if [[ "$code" -eq 0 ]]; then ok="true"; else ok="false"; fi
  if [[ "$kind" == "hard" ]]; then
    if [[ "$code" -ne 0 && "$code" -ne 2 ]]; then has_hard_fail=1; fi
  fi
  NAMES+=("$name"); CMDS+=("$cmd"); KINDS+=("$kind"); EXITS+=("$code"); OKS+=("$ok"); MSGS+=("$msg")
  # log dei check su STDERR: stdout resta pulito per --json
  printf '[gate] %-12s %-8s exit=%s ok=%s\n' "$name" "$kind" "$code" "$ok" >&2
  [[ -n "$msg" ]] && printf '        → %s\n' "$msg" >&2
done

# --------------------------------------------------------------- report ----
# overall: tool mancante hard forza red (ma exit 2); altrimenti green se tutto ok
overall="green"
if [[ "$has_hard_missing" -eq 1 ]]; then overall="red"; fi
if [[ "$has_hard_fail" -eq 1 ]]; then overall="red"; fi

# costruisci l'array checks come json
build_checks() {
  printf '['
  for ((i = 0; i < n; i++)); do
    [[ $i -gt 0 ]] && printf ','
    printf '{"name":%s,"cmd":%s,"kind":%s,"exit":%s,"ok":%s,"msg":%s}' \
      "$(jq -Rn --arg v "${NAMES[$i]}" '$v')" \
      "$(jq -Rn --arg v "${CMDS[$i]}" '$v')" \
      "$(jq -Rn --arg v "${KINDS[$i]}" '$v')" \
      "${EXITS[$i]}" \
      "$(jq -Rn --arg v "${OKS[$i]}" '$v')" \
      "$(jq -Rn --arg v "${MSGS[$i]}" '$v')"
  done
  printf ']'
}

REPORT_JSON="$(jq -nc \
  --arg project "$PROJECT_ROOT" \
  --arg posture "$posture" \
  --arg autoPr "$autoPr" \
  --argjson rounds "$maxRounds" \
  --arg overall "$overall" \
  --argjson checks "$(build_checks)" \
  '{ project:$project, config:{posture:$posture,autoPr:$autoPr,maxRounds:$rounds}, checks:$checks, overall:$overall }')"

mkdir -p "$(dirname "$REPORT")" 2>/dev/null
if [[ "$(dirname "$REPORT")" == "." ]]; then
  printf '%s\n' "$REPORT_JSON" > "$REPORT"
else
  printf '%s\n' "$REPORT_JSON" > "$REPORT"
fi
if [[ "$JSON_OUT" -eq 1 ]]; then printf '%s\n' "$REPORT_JSON"; fi

# exit code
if [[ "$overall" == "red" ]]; then
  [[ "$has_hard_missing" -eq 1 ]] && exit 2
  exit 1
fi
exit 0
