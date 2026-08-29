#!/usr/bin/env bash
#
# pi-fleet · T-015 loop acceptance smoke — headless review&fix loop
#
# Runs the ORCHESTRATOR SEMANTICS of the review&fix loop on the loop-sample
# fixture (fixtures/loop-sample) with a MOCKED fleet layer (no herdr panes,
# no LLM, real ~/.pi/fleet untouched — same isolation strategy as
# tests/smoke-nested.sh). The reviewer is the deterministic companion
# bin/audit.sh (sample-style-review checklist); fixers are deterministic
# transforms implementing the findings' requiredFix; integration is REAL git
# (fixer branch + ONE COMMIT PER FILE + cherry-pick onto the effective
# branch fleet/pipeline-<id>); verification runs the spec `checks` (exit-0
# commands, gate-run.sh semantics).
#
# What this proves (T-015 acceptance):
#   - findings read STRICTLY from reviewer STATE files (<id>.findings.json)
#     via bin/fleet-loop-helper.sh (never from prose);
#   - hybrid fixer partitioning (parallel only on disjoint files);
#   - fixers never commit on the effective branch (orchestrator-only,
#     cherry-pick integration), one commit per file;
#   - exactly 3 FIXED cycles — no early exit on a first PASS; cycles 2-3 are
#     fresh reviews of the current tree;
#   - per-cycle verification; red -> revert + regression recorded;
#   - correct verdict: PASS (cycle-3 review PASS + checks green, verified
#     branch, clean status) or FAILED_TO_CONVERGE (report: unresolved
#     findings / regressions).
#
# Scenarios:
#   A  pass             planted defects fixed in cycle 1, cycles 2-3 clean
#                       -> PASS, effective branch has exactly ONE commit
#   B  no-converge      a stubborn finding (utils.sh FIXME never fixed)
#                       -> FAILED_TO_CONVERGE, unresolved repeated finding
#   C  no-early-exit    clean fixture -> 0 fixes, still 3 cycles, PASS
#   D  regression       a fixer breaks the syntax every cycle -> verify RED
#                       -> revert each cycle -> FAILED_TO_CONVERGE
#
# Isolation: scratch repo + state in /tmp. Real ~/.pi/fleet untouched.
# Usage:    bash tests/smoke-loop.sh            (runs all 4 scenarios)
# Exit:     0 green / 1 failed / 2 missing prerequisites
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
HELPER="$REPO_ROOT/bin/fleet-loop-helper.sh"
FIXTURE="$REPO_ROOT/fixtures/loop-sample"
TS="$(date +%s)"
SCRATCH="/tmp/fleet-loop-smoke-$TS"
KEEP="${SMOKE_KEEP:-0}"

log()  { printf 'LOOP [%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die()  { printf 'LOOP FAIL: %s\n' "$*" >&2; exit 1; }
die2() { printf 'LOOP SKIP (exit 2): %s\n' "$*" >&2; exit 2; }

command -v jq  >/dev/null 2>&1 || die2 "jq not found in PATH (brew install jq)"
command -v git >/dev/null 2>&1 || die2 "git not found in PATH"
[[ -x "$HELPER" ]] || die "helper not found: $HELPER"
[[ -d "$FIXTURE" ]] || die "fixture not found: $FIXTURE"

cleanup() {
  [[ "$KEEP" == "1" ]] && { log "SMOKE_KEEP=1: keeping $SCRATCH"; return 0; }
  rm -rf "$SCRATCH"
}
trap cleanup EXIT
mkdir -p "$SCRATCH"
cd "$SCRATCH" || die "cannot cd scratch"

# --------------------------------------------------------------------- setup
# One scratch git repo per scenario, copied from the fixture. Env (set by the
# scenario call): PLANT_FIXME=1 adds an eternal FIXME to utils.sh; CLEAN_SEED=1
# starts from the fixed shapes.sh. BASE_COMMIT is captured AFTER scenario prep.
setup_repo() { # name -> prints repo path
  local name="$1" repo="$SCRATCH/$name"
  mkdir -p "$repo"
  cp -R "$FIXTURE"/. "$repo/"
  rm -rf "$repo/.git"
  ( cd "$repo" \
      && git init -q \
      && git config user.name "loop-smoke" \
      && git config user.email "loop-smoke@localhost" \
      && git add -A && git commit -qm "base fixture" ) || die "setup_repo failed: $name"
  if [[ "${PLANT_FIXME:-0}" == "1" ]]; then
    printf '\n# FIXME: eternal backlog item\n' >> "$repo/src/utils.sh"
    ( cd "$repo" && git add -A && git commit -qm "plant eternal FIXME" )
  fi
  if [[ "${CLEAN_SEED:-0}" == "1" ]]; then
    apply_fixes_to_file "$repo/src/shapes.sh"
    ( cd "$repo" && git add -A && git commit -qm "clean seed" )
  fi
  echo "$repo"
}

# --------------------------------------------- deterministic fixer transforms
# Implements the requiredFix of each finding id. Applied to the file listed by
# the finding's location. Idempotent content transforms (safe to re-run).
insert_after_shebang() { # file text
  local f="$1" t="$2" tmp
  tmp="$(mktemp)"
  {
    sed -n '1p' "$f"
    printf '%s\n' "$t"
    sed -n '2,$p' "$f"
  } > "$tmp" && mv "$tmp" "$f"
}

apply_fixes_to_file() { # file — full sample-style checklist repair
  local f="$1" tmp
  # SAMPLE-03: remove TODO/FIXME marker lines
  tmp="$(mktemp)"; grep -vE '^[[:space:]]*#.*(TODO|FIXME)' "$f" > "$tmp" && mv "$tmp" "$f"
  # SAMPLE-04: comment directly above every function whose line above is not a
  # comment (blank included — blank is not a comment, matching bin/audit.sh)
  tmp="$(mktemp)"
  awk '
    NR == 1 { print; prev = $0; next }
    {
      if ($0 ~ /^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*\(\)[[:space:]]*\{/ && prev !~ /^[[:space:]]*#/) {
        fn = $0; sub(/^[[:space:]]*/, "", fn); sub(/\(.*/, "", fn)
        print "# " fn " helper"
      }
      print
      prev = $0
    }
  ' "$f" > "$tmp" && mv "$tmp" "$f"
  # SAMPLE-02: set -u right after the shebang
  grep -qE '^[[:space:]]*set[[:space:]]+-[a-z]*u([[:space:]]|$)' "$f" || insert_after_shebang "$f" "set -u"
  # SAMPLE-01: header comment right after the shebang (before set -u)
  if ! awk 'NR==1 && /^#!/ { next } NR>1 && NF>0 { if ($0 ~ /^#/) exit 0; exit 1 }' "$f"; then
    insert_after_shebang "$f" "# shapes calculator: rectangle area and perimeter"
  fi
}

# ------------------------------------------------------------------ reviewer
# Mirrors a scout reviewer: evaluates the CURRENT tree from scratch with the
# review skill's deterministic companion and writes the structured findings to
# its durable state file <id>.findings.json (the orchestrator brief contract).
review_wave() { # cycle repo state -> reviewer task id
  local cycle="$1" repo="$2" state="$3"
  local rev="rev-c$cycle"
  ( cd "$repo" \
      && bash bin/audit.sh \
        | jq -c --arg tid "$rev" '{taskId: $tid, findings: .}' \
        > "$state/$rev.findings.json" ) || die "audit failed c$cycle"
  echo "$rev"
}

# ------------------------------------------------------------------- fixers
# One fixer per batch (single domain). The fixer works on its OWN branch like a
# ship task, commits ONE COMMIT PER FILE, and the orchestrator (this driver)
# cherry-picks onto the effective branch — mirroring the template integration.
fix_batch() { # repo eff batch batch_no cycle -> echo status
  local repo="$1" eff="$2" batch="$3" no="$4" cycle="$5"
  local files
  files="$(jq -r '.files[]' <<<"$batch")"
  local branch="fleet/fixer-$no-c$cycle" file commits=0
  ( cd "$repo" && git switch -q -c "$branch" ) || return 1
  for file in $files; do
    if [[ -n "${STUBBORN_FILE:-}" ]] && [[ "$file" == "$STUBBORN_FILE" ]]; then
      echo "cycle $cycle: batch $no skipped $file (stubborn finding)"; continue
    fi
    apply_fixes_to_file "$repo/$file"
    [[ -n "${DECEPTIVE:-}" ]] && printf '((\n' >> "$repo/$file"   # scenario D
    ( cd "$repo" \
        && git add "$file" \
        && git commit -qm "fix(SAMPLE): $file (batch $no, cycle $cycle)" ) \
      || die "fixer commit failed c$cycle batch $no"
    commits=$((commits + 1))
  done
  ( cd "$repo" && git switch -q "$eff" ) || return 1
  local sha
  for sha in $(cd "$repo" && git rev-list --reverse "$eff".."$branch"); do
    ( cd "$repo" && git cherry-pick -n "$sha" && git commit -q -m "integrate $(git log -1 --format=%s "$sha")" ) \
      || { echo "cycle $cycle: batch $no cherry-pick conflict on $sha" ; return 1; }
  done
  ( cd "$repo" && git branch -q -D "$branch" ) || true
  echo "cycle $cycle: batch $no integrated $commits commit(s) via fixer-$no-c$cycle"
}

# ------------------------------------------------------------------- verify
# Runs the pipeline checks (.checks[].cmd, exit 0 = pass — gate-run.sh
# semantics) on the current checkout. Prints "ok" or "RED:<name>".
verify_checks() { # repo spec
  local repo="$1" spec="$2" res="ok" name cmd
  while IFS= read -r name; do
    cmd="$(jq -r --arg n "$name" '.checks[] | select(.name==$n) | .cmd' "$spec")"
    if ! ( cd "$repo" && bash -c "$cmd" >/dev/null 2>&1 ); then res="RED:$name"; break; fi
  done < <(jq -r '.checks[].name' "$spec")
  echo "$res"
}

# ------------------------------------------------------------------ the loop
run_loop() { # repo state spec eff cycleslog
  local repo="$1" state="$2" spec="$3" eff="$4" cycles="$5"
  local c w wmax batch_no rev blocking nf nb
  for c in 1 2 3; do
    rev="$(review_wave "$c" "$repo" "$state")"
    # 2. read findings STRICTLY from the state file via the helper
    blocking="$( "$HELPER" partition --severity BLOCKING "$state/$rev.findings.json" 2>/dev/null )"
    nf="$(jq -r '.findings' <<<"$blocking")"
    nb="$(jq -r '.batches | length' <<<"$blocking")"
    # 3. fix waves: batches of the same wave are file-disjoint (parallel-safe);
    #    waves are sequential — same as the orchestrator's wave scheduling
    batch_no=0
    wmax="$(jq -r '.waves' <<<"$blocking")"
    local batch w
    for ((w = 1; w <= wmax; w++)); do
      for batch in $(jq -c --argjson w "$w" '.batches[] | select(.wave==$w)' <<<"$blocking"); do
        batch_no=$((batch_no + 1))
        fix_batch "$repo" "$eff" "$batch" "$batch_no" "$c" || true
      done
    done
    # 4. verify after fixes
    local vres
    vres="$(verify_checks "$repo" "$spec")"
    if [[ "$vres" == "ok" ]]; then
      echo "cycle $c: findings=$nf batches=$nb fixes=$batch_no verify=ok" >> "$cycles"
    else
      echo "cycle $c: findings=$nf batches=$nb fixes=$batch_no verify=$vres" >> "$cycles"
      # revert-on-red: restore a green base before the next cycle (regression)
      ( cd "$repo" && git revert --no-edit "$eff"~1.."$eff" >/dev/null 2>&1 ) \
        || ( cd "$repo" && git revert --no-edit "$eff" >/dev/null 2>&1 ) || true
      echo "cycle $c: reverted broken fixes (verify=$vres)" >> "$cycles"
    fi
  done
  # verdict: cycle-3 fresh review PASS (no BLOCKING findings) AND checks green
  local third n3 v3 unresolved
  n3="$( "$HELPER" partition --severity BLOCKING "$state/rev-c3.findings.json" 2>/dev/null | jq -r '.findings' )"
  v3="$(verify_checks "$repo" "$spec")"
  if [[ "$n3" == "0" && "$v3" == "ok" ]]; then third="PASS"; else third="FAILED_TO_CONVERGE"; fi
  # unresolved = what the LAST fresh review still reports (deduped by id+location)
  unresolved="$( "$HELPER" dedup "$state/rev-c3.findings.json" 2>/dev/null | jq -c '[.[] | {id, location}]' )"
  printf 'VERDICT: %s\nUNRESOLVED: %s\nREGRESSIONS: %s\n' "$third" "$unresolved" ""
  echo "$third" > "$state/verdict.txt"
}

# ------------------------------------------------------------------ scenarios
step() { printf '\n════ LOOP %s ════\n' "$*"; }
FAILS=0
check() { # check <scenario> <name> <got> <want>
  if [[ "$3" == "$4" ]]; then printf '  OK   [%s] %s\n' "$1" "$2"
  else printf '  FAIL [%s] %s (got "%s" want "%s")\n' "$1" "$2" "$3" "$4"; FAILS=$((FAILS+1)); fi
}

scenario() { # name  (env: PLANT_FIXME / CLEAN_SEED / STUBBORN_FILE / DECEPTIVE)
  local name="$1" repo state spec eff base
  state="$SCRATCH/state-$name"; mkdir -p "$state"
  repo="$(setup_repo "$name")"
  spec="$repo/pipeline.spec.json"
  base="$(cd "$repo" && git rev-parse HEAD)"
  eff="fleet/pipeline-$name"
  ( cd "$repo" && git switch -q -c "$eff" ) || die "cannot create effective branch"
  step "SCENARIO $name"
  local out
  out="$(run_loop "$repo" "$state" "$spec" "$eff" "$state/cycles.log" 2>&1)"
  printf '%s\n' "$out" | tee "$state/run.txt"
  local ncycles
  ncycles="$(grep -c '^cycle ' "$state/cycles.log" || true)"
  case "$name" in
    A)
      check A "verdict PASS" "$(grep -c 'VERDICT: PASS' "$state/run.txt" || true)" "1"
      check A "exactly 3 cycles" "$ncycles" "3"
      check A "cycle 1 fixes = 1 batch" "$(grep '^cycle 1:' "$state/cycles.log" | sed 's/.*fixes=\([0-9]*\).*/\1/')" "1"
      check A "cycles 2-3 fresh = clean" "$(grep -c '^cycle [23]: findings=0' "$state/cycles.log" || true)" "2"
      check A "checks green every cycle" "$(grep -c 'verify=ok' "$state/cycles.log" || true)" "3"
      check A "one commit integrated" "$(cd "$repo" && git rev-list --count "$base..$eff")" "1"
      check A "commit touches exactly 1 file" "$(cd "$repo" && git show --format= --name-only "$eff" | grep -vc '^$')" "1"
      check A "on the effective branch" "$(cd "$repo" && git rev-parse --abbrev-ref HEAD)" "$eff"
      check A "working tree clean" "$(cd "$repo" && git status --porcelain | wc -l | tr -d ' ')" "0"
      check A "final audit clean on the branch" "$(cd "$repo" && bash bin/audit.sh | jq 'length')" "0"
      ;;
    B)
      check B "verdict FAILED_TO_CONVERGE" "$(grep -c 'VERDICT: FAILED_TO_CONVERGE' "$state/run.txt" || true)" "1"
      check B "exactly 3 cycles" "$ncycles" "3"
      check B "unresolved SAMPLE-03 in utils" "$(grep -c 'FINDING-SAMPLE-03.*src/utils.sh' "$state/run.txt" || true)" "1"
      check B "no regression (checks green)" "$(grep -c 'verify=ok' "$state/cycles.log" || true)" "3"
      ;;
    C)
      check C "verdict PASS (clean from start)" "$(grep -c 'VERDICT: PASS' "$state/run.txt" || true)" "1"
      check C "still exactly 3 cycles (no early exit)" "$ncycles" "3"
      check C "zero findings every cycle" "$(grep -c 'findings=0' "$state/cycles.log" || true)" "3"
      check C "zero fixes" "$(grep -c 'fixes=0' "$state/cycles.log" || true)" "3"
      check C "no commits on the effective branch" "$(cd "$repo" && git rev-list --count "$base..$eff")" "0"
      ;;
    D)
      check D "verdict FAILED_TO_CONVERGE (regression)" "$(grep -c 'VERDICT: FAILED_TO_CONVERGE' "$state/run.txt" || true)" "1"
      check D "exactly 3 cycles" "$(grep -c '^cycle [123]: findings=' "$state/cycles.log" || true)" "3"
      check D "syntax red every cycle" "$(grep -c '^cycle [123]:.*findings=.*verify=RED:syntax' "$state/cycles.log" || true)" "3"
      check D "revert recorded every cycle" "$(grep -c 'reverted broken fixes' "$state/cycles.log" || true)" "3"
      check D "final tree green after last revert" "$(cd "$repo" && bash bin/check.sh syntax >/dev/null 2>&1 && echo ok)" "ok"
      ;;
  esac
}

scenario A
PLANT_FIXME=1 STUBBORN_FILE="src/utils.sh" scenario B
CLEAN_SEED=1 scenario C
DECEPTIVE=1 scenario D

if [[ "$FAILS" -gt 0 ]]; then die "$FAILS check(s) failed across scenarios — see FAIL lines above"; fi
log "OUTCOME: OK — loop acceptance: PASS and FAILED_TO_CONVERGE on a verified branch, 3 fixed cycles, one-commit-per-file integration, revert-on-red"
exit 0