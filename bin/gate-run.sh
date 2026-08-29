#!/usr/bin/env bash
# pi-fleet · deterministic mechanical gate (T-011)
#
# Runs the delivery checks of the gated project (gate.yaml, or fallback if absent)
# IN ORDER on the current state of the worktree, generating a per-step report.json
# + overall green|red. No AI in the gate: only exit codes of real processes.
#
# Usage:
#   bin/gate-run.sh [--report <path>] [--json]
#
#   --report <path>   writes the json report to the path (default: gate/report.json
#                     relative to the root of the gated project = cwd)
#   --json            prints the report to stdout (for the child)
#
# Config (gate.yaml at the root of the cwd):
#   posture: no-mistakes | autoPr: true|false | loop.maxRounds: N
#   checks:  - { name, cmd, kind: hard|advisory }
#   kind hard → required ok (exit 0); advisory → report, does not block.
#   Missing config → fallback: posture from postures.json (default no-mistakes),
#   autoPr false, default checks: typecheck (if tsconfig), test (if test script),
#   + git diff --check + clean git status (hard). NEVER blocks on missing config.
#
# Exit code:
#   0  green — all hard checks ok
#   1  red   — at least one hard check has exit != 0
#   2  missing config/tool — a hard check has a missing tool (fail-safe,
#      NEVER false green); missing advisory → only warning, does not block.
#
# Runs ON THE CURRENT COMMIT of the worktree (cwd). Does not commit, push, or
# open PRs: it is purely evaluative.
set -u

REPORT=""
JSON_OUT=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --report) REPORT="$2"; shift 2 ;;
    --json) JSON_OUT=1; shift ;;
    *) printf 'error: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

PROJECT_ROOT="$(pwd)"
GATE_YAML="$PROJECT_ROOT/gate.yaml"
[[ -z "$REPORT" ]] && REPORT="gate/report.json"

# ------------------------------------------------------------ parse config ----
# Default values (current behavior preserved in the absence of gate.yaml)
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

# Fallback: missing config → default checks (hard), NEVER blocking
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
# tool available? Only for cmds starting with a simple name (no shell operators:
# in those cases don't falsify detection).
tool_available() {
  local first="$1"
  if [[ "$first" == */* ]]; then [[ -x "$first" ]]; return $?; fi
  command -v "$first" >/dev/null 2>&1
}
first_word() { printf '%s' "$1" | awk '{print $1}'; }
is_simple_cmd() { [[ "$1" =~ ^[A-Za-z0-9_./-]+([[:space:]]|$) ]]; }

has_hard_fail=0     # any red hard check (exit != 0) → exit 1
has_hard_missing=0  # any hard check with a missing tool → exit 2
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
    msg="missing tool: $fw"
    if [[ "$kind" == "hard" ]]; then
      has_hard_missing=1
      printf '[gate] check %s: %s (fail-safe, NEVER false green)\n' "$name" "$msg" >&2
    else
      printf '[gate] advisory %s: %s (warning, does not block)\n' "$name" "$msg" >&2
    fi
  else
    out="$(bash -c "$cmd" 2>&1)"
    code=$?
    if [[ -n "$out" ]]; then
      # squeeze: newline → space, strip ANSI codes, truncate
      msg="$(printf '%s' "$out" | sed 's/\x1b\[[0-9;]*m//g' | tr '\n' ' ' | cut -c1-160)"
    fi
  fi
  if [[ "$code" -eq 0 ]]; then ok="true"; else ok="false"; fi
  if [[ "$kind" == "hard" ]]; then
    if [[ "$code" -ne 0 && "$code" -ne 2 ]]; then has_hard_fail=1; fi
  fi
  NAMES+=("$name"); CMDS+=("$cmd"); KINDS+=("$kind"); EXITS+=("$code"); OKS+=("$ok"); MSGS+=("$msg")
  # per-check log on STDERR: stdout stays clean for --json
  printf '[gate] %-12s %-8s exit=%s ok=%s\n' "$name" "$kind" "$code" "$ok" >&2
  [[ -n "$msg" ]] && printf '        → %s\n' "$msg" >&2
done

# --------------------------------------------------------------- report ----
# overall: missing hard tool forces red (but exit 2); otherwise green if everything ok
overall="green"
if [[ "$has_hard_missing" -eq 1 ]]; then overall="red"; fi
if [[ "$has_hard_fail" -eq 1 ]]; then overall="red"; fi

# build the checks array as json
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
