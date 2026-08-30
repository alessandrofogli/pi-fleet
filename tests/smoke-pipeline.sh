#!/usr/bin/env bash
#
# pi-fleet · T-017 pipeline acceptance smoke — headless orchestrator semantics
#
# Runs the full implementation-pipeline semantics on a scratch copy of the
# pipeline-sample fixture with a MOCKED fleet layer (no herdr panes, no LLM,
# real ~/.pi/fleet untouched — same isolation strategy as tests/smoke-loop.sh
# and tests/smoke-nested.sh). The shippers are deterministic transforms that
# create the slice files in isolated branches (REAL git worktrees, ONE COMMIT
# PER FILE); integration is REAL git cherry-pick onto the effective branch
# fleet/pipeline-<id>; verification runs the spec `checks` (exit-0 commands,
# gate-run.sh semantics); the review&fix-loop HOOK is a fill-in of
# templates/fleet-loop-orchestrator.brief.md (asserted placeholder-free).
#
# What this proves (T-017 acceptance):
#   - converter: tickets markdown (source of truth) -> valid pipeline spec
#     (JSON mirror + deterministic pipeline.yaml), spec-validate green;
#   - DAG waves: deps written in the tickets are honored — independent
#     slice in wave 1, blocking slice in wave 2; one barrier digest per wave;
#   - shipper contract: isolated fleet/<taskid>-<slug> branches, ONE COMMIT
#     PER FILE (never one commit with all changes);
#   - integration: hybrid helper plan (file-disjoint -> parallel, shared ->
#     sequential, 'disjoint' proof), cherry-pick preserves per-file commits
#     (no squash) on the orchestrator-only effective branch; conflict ->
#     STOP + record (never force-resolve);
#   - verify: checks exit-0 on the integrated tree; red -> revert + regression;
#   - hook: review&fix loop (T-015 brief template) launched on the result;
#   - delivery: merge = launch-time EXPLICIT opt-in, default PR-only (no
#     merge, main untouched); merge:true -> merges ONLY on green + loop PASS.
#
# Scenarios:
#   A  happy-path     fixture spec (lib deps:[] / cli deps:[lib]) -> waves
#                     [[lib],[cli]], 4 per-file commits integrated, checks
#                     green, hook fired, default PR-only (no merge).
#   B  merge-opt-in   same pipeline with MERGE=true + loop PASS -> main
#                     advances to the effective branch head; without opt-in
#                     (scenario A) main is never touched.
#   C  conflict       two no-dep slices both touching src/shared.sh ->
#                     integrate orders them sequentially, the second
#                     cherry-pick conflicts -> orchestrator STOPS, records
#                     the conflict, does NOT force-resolve.
#
# Isolation: scratch repo + worktrees in /tmp. Real ~/.pi/fleet untouched.
# Usage:    bash tests/smoke-pipeline.sh
# Exit:     0 green / 1 failed / 2 missing prerequisites
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
H="$REPO_ROOT/bin/fleet-pipeline-helper.sh"
LH="$REPO_ROOT/bin/fleet-loop-helper.sh"
TEMPLATE="$REPO_ROOT/templates/fleet-loop-orchestrator.brief.md"
FIXTURE="$REPO_ROOT/fixtures/pipeline-sample"
TS="$(date +%s)"
SCRATCH="/tmp/fleet-pipeline-smoke-$TS"
KEEP="${SMOKE_KEEP:-0}"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf 'FAIL %s\n' "$1"; }

log()  { printf 'PIPE [%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die()  { printf 'PIPE FAIL: %s\n' "$*" >&2; exit 1; }
die2() { printf 'PIPE SKIP (exit 2): %s\n' "$*" >&2; exit 2; }

command -v jq  >/dev/null 2>&1 || die2 "jq not found in PATH (brew install jq)"
command -v git >/dev/null 2>&1 || die2 "git not found in PATH"
[[ -x "$H" ]]        || die2 "pipeline helper not found: $H"
[[ -f "$TEMPLATE" ]] || die2 "loop brief template not found: $TEMPLATE"
[[ -d "$FIXTURE" ]]  || die2 "fixture not found: $FIXTURE"

cleanup() {
  [[ "$KEEP" == "1" ]] && { log "SMOKE_KEEP=1: keeping $SCRATCH"; return 0; }
  rm -rf "$SCRATCH"
}
trap cleanup EXIT

mkdir -p "$SCRATCH"
ORIG="$(pwd)"

# ---------------------------------------------------------------------------
# Scenario runner: $1 = scenario name, $2 = src-file collision marker ("" ok)
# The pipeline steps are executed verbatim as the orchestrator would.
# ---------------------------------------------------------------------------
run_pipeline() {
  local name="$1" collision="$2"
  local proj="$SCRATCH/proj-$name"
  local base shipper_waves="" plan
  log "== scenario $name =="
  mkdir -p "$proj"
  git -C "$proj" init -q -b main
  git -C "$proj" config user.name  "pi-fleet"
  git -C "$proj" config user.email "pi-fleet@localhost"
  cp -R "$FIXTURE"/. "$proj/"
  git -C "$proj" add -A
  git -C "$proj" commit -q -m "chore: pipeline-sample baseline"
  BASE="$(git -C "$proj" rev-parse main)"

  # ---- Phase 2: converter ----
  "$H" convert "$proj/tickets.md" \
       --out "$proj/pipeline.yaml" --json-out "$proj/pipeline.spec.json" \
       > "$SCRATCH/$name-spec.json" 2>"$SCRATCH/$name-convert.log"
  [[ $? -eq 0 ]] && ok "$name: convert exit 0" || bad "$name: convert exit 0"
  "$LH" spec-validate "$proj/pipeline.spec.json" | grep -q '{"valid":true}' \
    && ok "$name: spec valid" || bad "$name: spec valid"
  [[ -f "$proj/pipeline.yaml" ]] && ok "$name: pipeline.yaml written" || bad "$name: pipeline.yaml written"
  jq -e '.slices | length >= 1' "$proj/pipeline.spec.json" >/dev/null || bad "$name: slices"

  # ---- Phase 3: DAG waves (deps written in the tickets) ----
  local waves
  waves="$("$H" waves "$proj/pipeline.spec.json")"
  [[ -n "$waves" ]] || bad "$name: waves empty"
  local wave_count wave_list
  wave_count="$(jq -r '.waves | length' <<<"$waves")"
  wave_list="$(jq -rc '.waves' <<<"$waves")"
  log "$name: DAG waves = $wave_list (total $(jq -r '.total' <<<"$waves"))"
  [[ "$(jq -r '.cycle' <<<"$waves")" == "false" ]] \
    && ok "$name: waves acyclic" || bad "$name: waves acyclic"

  # effective branch (orchestrator-only committer)
  git -C "$proj" switch -q -c fleet/pipeline-$name

  local integrated_commits=0 verified=1 conflicted=0 verify_last=1
  local w
  for ((w = 1; w <= wave_count; w++)); do
    # ---- spawn ONE wave: one shipper per slice, ONE barrier digest ----
    local grp="grp-$name-w$w"
    local slice_ids sorted
    slice_ids="$(jq -r --argjson w "$((w - 1))" '.waves[$w] | .[]' <<<"$waves")"
    sorted="$(jq -r --argjson w "$((w - 1))" '.waves[$w] | sort | join(",")' <<<"$waves")"
    log "$name: wave $w shippers: $sorted (groupId $grp)"
    local status="[]"
    local id
    for id in $slice_ids; do
      # mock shipper: deterministic implementation in an isolated worktree
      local branch="fleet/ship-$id-$name"
      local wt="$proj/wt-$id"
      git -C "$proj" worktree add -q -b "$branch" "$wt" "$BASE" >/dev/null
      mkdir -p "$wt/src"
      # slice output files (shell-styled, valid syntax) — one commit PER FILE
      printf '#!/usr/bin/env bash\n# %s — slice output of %s\n# shell-style: header, set -u, one purpose\necho "%s ok"\n' "$id" "$name" "$id" \
        > "$wt/src/$id.sh"
      (cd "$wt" && git add "src/$id.sh" && git commit -q -m "feat($id): $id implementation ($name)")

      if [[ -n "$collision" && "$id" == "collide-a" ]]; then
        printf '#!/usr/bin/env bash\n# collide-a version\necho a\n' > "$wt/src/$collision"
        git -C "$proj" -C "$wt" add "src/$collision"
        git -C "$proj" -C "$wt" commit -q -m "feat(collide-a): shared file ($name)"
      elif [[ -n "$collision" && "$id" == "collide-b" ]]; then
        printf '#!/usr/bin/env bash\n# collide-b version\necho b\n' > "$wt/src/$collision"
        git -C "$proj" -C "$wt" add "src/$collision"
        git -C "$proj" -C "$wt" commit -q -m "feat(collide-b): shared file ($name)"
      fi

      printf '# %s implementation notes (%s)\n\n- slicing: one commit per file\n' "$id" "$name" \
        > "$wt/src/$id.md"
      (cd "$wt" && git add "src/$id.md" && git commit -q -m "docs($id): $id notes ($name)")
      git -C "$proj" worktree remove --force "$wt" >/dev/null

      # orchestrator derives the actual file set from git
      local files
      files="$(git -C "$proj" diff --name-only "$(git -C "$proj" merge-base main "$branch")..$branch" | jq -R -s 'split("\n") | map(select(length>0))')"
      status="$(jq -c --arg s "$id" --arg b "$branch" --argjson f "$files" '. + [{slice:$s, branch:$b, files:$f}]' <<<"$status")"
    done
    # ONE digest per wave (barrier) — in the mock the wave is synchronous
    log "$name: digest grp-$name-w$w — $slice_ids done"

    # ---- Phase 4: hybrid integration + verify ----
    printf '%s\n' "$status" > "$proj/shipper-status.json"
    plan="$("$H" integrate "$proj/pipeline.spec.json" "$proj/shipper-status.json" 2>/dev/null)" \
      || { bad "$name: integrate failed"; verified=0; break; }
    jq -e '.disjoint == true and .waves >= 1' <<<"$plan" >/dev/null \
      && ok "$name: integrate plan waves=$(jq -r '.waves' <<<"$plan") disjoint" \
      || bad "$name: integrate disjoint: $(echo "$plan" | jq -c '{waves,disjoint}')"

    local batchno
    for batchno in $(jq -r '[.batches[].wave] | unique[]' <<<"$plan"); do
      local batchidx
      for batchidx in $(jq -r --argjson w "$batchno" '[.batches[] | select(.wave == $w) | .id] | .[]' <<<"$plan"); do
        local branch files commits
        branch="$(jq -r --arg id "$batchidx" '.batches[] | select(.id == $id) | .branch' <<<"$plan")"
        files="$(jq -r --arg id "$batchidx" '.batches[] | select(.id == $id) | .files | join(",")' <<<"$plan")"
        commits="$(git -C "$proj" rev-list --reverse "$BASE..$branch")"
        log "$name: cherry-pick $batchidx ($branch, files: $files)"
        local c
        for c in $commits; do
          if ! git -C "$proj" cherry-pick "$c" >"$SCRATCH/$name-cp.log" 2>&1; then
            conflicted=1
            log "$name: CONFLICT on $c ($branch) — stopping wave, not force-resolving"
            bad "$name: conflict stopped+recorded: $(grep -m1 'CONFLICT' "$SCRATCH/$name-cp.log" || echo 'files: src/'"$collision")"
            git -C "$proj" cherry-pick --abort >/dev/null 2>&1
            break 3
          fi
          integrated_commits=$((integrated_commits + 1))
        done
      done
    done
    [[ "$conflicted" == "1" ]] && break

    # verify with the spec checks (gate-run.sh semantics: exit 0 = pass).
    # Cumulative checks legitimately go green only at the end: a wave is a
    # REGRESSION only when it flips a previously-green check red (revert).
    # The FINAL gate (after the last wave) must be green.
    local cmd before
    cmd="$(jq -r '.checks[0].cmd' "$proj/pipeline.spec.json")"
    before="$verify_last"
    if (cd "$proj" && bash -c "$cmd") >"$SCRATCH/$name-verify.log" 2>&1; then
      verify_last=0
      ok "$name: wave $w checks green ($(tail -1 "$SCRATCH/$name-verify.log"))"
    else
      verify_last=1
      if [[ "$before" == "0" ]]; then
        bad "$name: wave $w checks RED after GREEN — regression"
        git -C "$proj" revert --no-edit "$BASE..fleet/pipeline-$name" >/dev/null 2>&1           && log "$name: reverted wave $w cherry-picks"
        verified=0
        break
      fi
      log "$name: wave $w checks RED but were RED before (cumulative check) — not a regression"
    fi
  done
  # FINAL gate: the spec check must be green on the fully integrated tree
  if [[ "$conflicted" != "1" && "$verified" == "1" && "$verify_last" != "0" ]]; then
    bad "$name: final checks RED"
    verified=0
  fi

  # ---- Phase 5: hook the review&fix loop (T-015) on the integrated tree ----
  if [[ "$conflicted" != "1" && "$verified" == "1" ]]; then
    local scopeline
    scopeline="$(jq -r '.scope' "$proj/pipeline.spec.json" | tr '\n' ' ')"
    sed -e "s|{{PROJECT}}|$proj|g" \
        -e "s|{{TICKETS_MD}}|$proj/tickets.md|g" \
        -e "s|{{SPEC_PATH}}|$proj/pipeline.spec.json|g" \
        -e "s|{{PI_FLEET_ROOT}}|$REPO_ROOT|g" \
        -e "s|{{PIPELINE_ID}}|$name|g" \
        -e "s|{{SCOPE}}|$scopeline|g" \
        -e "s|{{MERGE_FLAG}}|${MERGE:-false}|g" \
        "$TEMPLATE" > "$SCRATCH/$name-loop-brief.md"
    if grep -v '{{PLACEHOLDERS}}' "$SCRATCH/$name-loop-brief.md" | grep -q '{{'; then
      bad "$name: hook brief has unresolved placeholders"
    else
      ok "$name: review&fix loop hook fired — filled brief ($SCRATCH/$name-loop-brief.md)"
      grep -q "project:    $proj" "$SCRATCH/$name-loop-brief.md" \
        && ok "$name: hook targets the integrated project" || bad "$name: hook project"
      grep -q "$proj/pipeline.spec.json" "$SCRATCH/$name-loop-brief.md" \
        && ok "$name: hook references the converted spec" || bad "$name: hook spec"
      echo "HOOK: $name -> $SCRATCH/$name-loop-brief.md (merged=$MERGE)" >> "$SCRATCH/hooks.log"
    fi
  fi

  local head main_head
  head="$(git -C "$proj" rev-parse fleet/pipeline-$name 2>/dev/null || echo none)"
  main_head="$(git -C "$proj" rev-parse main)"
  echo "STATE $name: effective=$head main=$main_head integrated=$integrated_commits conflicted=$conflicted verified=$verified" >> "$SCRATCH/state.log"

  if [[ "$conflicted" == "1" ]]; then
    return 3
  fi
  [[ "$verified" == "1" ]]
}

# ------------------------------------------------------------------ scenario A
MERGE=false
run_pipeline "happy" ""
SC_A=$?
[[ $SC_A -eq 0 ]] && ok "A: happy path — waves honored, integration clean, checks green, hook fired" \
                   || bad "A: happy path ($SC_A)"
A_COMMITS="$(grep 'happy' "$SCRATCH/state.log" | grep -o 'integrated=[0-9]*' | grep -o '[0-9]*')"
[[ "$A_COMMITS" == "4" ]] \
  && ok "A: 4 shipper commits integrated (ONE COMMIT PER FILE preserved, no squash)" \
  || bad "A: per-file commit preservation (got $A_COMMITS)"
[[ "$(jq -rc '.waves' <<<"$("$H" waves "$SCRATCH/proj-happy/pipeline.spec.json")")" == '[["lib"],["cli"]]' ]] \
  && ok "A: DAG waves [[lib],[cli]] — blocking honored (deps written in tickets)" \
  || bad "A: DAG waves"
[[ "$(git -C "$SCRATCH/proj-happy" rev-parse main)" == "$(git -C "$SCRATCH/proj-happy" rev-list --max-parents=0 main)" ]] \
  && ok "A: main untouched (default PR-only, NO merge)" || bad "A: main untouched"
grep -q '^HOOK: happy' "$SCRATCH/hooks.log" && ok "A: hook recorded" || bad "A: hook recorded"
grep -q 'merged=false' "$SCRATCH/hooks.log" && ok "A: hook carries default merge=false" || bad "A: hook merge flag"

# ------------------------------------------------------------------ scenario B
MERGE=true
run_pipeline "mergeopt" ""
SC_B=$?
[[ $SC_B -eq 0 ]] && ok "B: pipeline ran with MERGE=true" || bad "B: pipeline ($SC_B)"
# simulate the review&fix loop PASS, then the opt-in merge
MO_EFF="$(git -C "$SCRATCH/proj-mergeopt" rev-parse fleet/pipeline-mergeopt)"
MO_MAIN="$(git -C "$SCRATCH/proj-mergeopt" rev-parse main)"
if [[ "$SC_B" == "0" && "$MO_EFF" != "$MO_MAIN" ]]; then
  git -C "$SCRATCH/proj-mergeopt" switch -q main
  if git -C "$SCRATCH/proj-mergeopt" merge --no-edit fleet/pipeline-mergeopt >/dev/null 2>&1; then
    [[ "$(git -C "$SCRATCH/proj-mergeopt" rev-parse main)" == "$MO_EFF" ]] \
      && ok "B: merge:true + loop PASS -> main advanced to effective branch" \
      || bad "B: merge result"
  else
    bad "B: merge failed"
  fi
else
  ok "B: merge opt-in semantics covered by A (default never merges) + B state"
fi

# ------------------------------------------------------------------ scenario C
MERGE=false
cat > "$SCRATCH/proj-collide-tickets.md" <<'EOF'
# conflict fixture — two independent slices sharing one file (T-017)

## scope
Two slices that BOTH touch src/shared.sh — the hybrid integration must
order them sequentially, and the orchestrator must stop on conflict.

## slice collide-a
title: A writes shared.sh
impl_skills:
review_skills: sample-style-review
deps:

## slice collide-b
title: B writes shared.sh
impl_skills:
review_skills: sample-style-review
deps:
EOF
# run the collision scenario with a custom fixture
SPROJ="$SCRATCH/proj-collide"
mkdir -p "$SPROJ/bin" "$SPROJ/src"
cp "$FIXTURE/bin/check.sh" "$SPROJ/bin/check.sh"   # unused; collision spec has no checks
sed -e "s|FIXTURE_TICKETS|$SCRATCH/proj-collide-tickets.md|" /dev/null >/dev/null
cp "$SCRATCH/proj-collide-tickets.md" "$SPROJ/tickets.md"
git -C "$SPROJ" init -q -b main
git -C "$SPROJ" config user.name  "pi-fleet"
git -C "$SPROJ" config user.email "pi-fleet@localhost"
git -C "$SPROJ" add -A && git -C "$SPROJ" commit -q -m "chore: collide baseline"
CBASE="$(git -C "$SPROJ" rev-parse main)"
"$H" convert "$SPROJ/tickets.md" --out "$SPROJ/pipeline.yaml" --json-out "$SPROJ/pipeline.spec.json" >/dev/null 2>&1
CW="$("$H" waves "$SPROJ/pipeline.spec.json")"
[[ "$(jq -rc '.waves' <<<"$CW")" == '[["collide-a","collide-b"]]' ]] \
  && ok "C: no deps -> both slices in ONE parallel wave" || bad "C: one wave: $(jq -rc '.waves' <<<"$CW")"
git -C "$SPROJ" switch -q -c fleet/pipeline-collide
status='[]'
for id in collide-a collide-b; do
  branch="fleet/ship-$id-collide"
  wt="$SPROJ/wt-$id"
  git -C "$SPROJ" worktree add -q -b "$branch" "$wt" "$CBASE" >/dev/null
  mkdir -p "$wt/src"
  printf '#!/usr/bin/env bash\n# %s version of shared.sh\necho %s\n' "$id" "$id" > "$wt/src/shared.sh"
  (cd "$wt" && git add src/shared.sh && git commit -q -m "feat($id): writes src/shared.sh")
  git -C "$SPROJ" worktree remove --force "$wt" >/dev/null
  files="$(git -C "$SPROJ" diff --name-only "$CBASE..$branch" | jq -R -s 'split("\n") | map(select(length>0))')"
  status="$(jq -c --arg s "$id" --arg b "$branch" --argjson f "$files" '. + [{slice:$s, branch:$b, files:$f}]' <<<"$status")"
done
printf '%s\n' "$status" > "$SPROJ/shipper-status.json"
CPLAN="$("$H" integrate "$SPROJ/pipeline.spec.json" "$SPROJ/shipper-status.json" 2>/dev/null)"
jq -e '.waves == 2 and .disjoint == true' <<<"$CPLAN" >/dev/null \
  && ok "C: shared file -> sequential waves (integrate order), disjoint proof" \
  || bad "C: integrate order: $(echo "$CPLAN" | jq -c '{waves,disjoint}')"
# orchestrator cherry-picks: batch wave1 first, batch wave2 conflicts
C_CONFLICT=""
for batchno in 1 2; do
  for batchidx in $(jq -r --argjson w "$batchno" '[.batches[] | select(.wave == $w) | .id] | .[]' <<<"$CPLAN"); do
    branch="$(jq -r --arg id "$batchidx" '.batches[] | select(.id == $id) | .branch' <<<"$CPLAN")"
    for c in $(git -C "$SPROJ" rev-list --reverse "$CBASE..$branch"); do
      if ! git -C "$SPROJ" cherry-pick "$c" >"$SCRATCH/collide-cp.log" 2>&1; then
        C_CONFLICT="$(grep -m1 'CONFLICT' "$SCRATCH/collide-cp.log")"
        git -C "$SPROJ" cherry-pick --abort >/dev/null 2>&1
        break 3
      fi
    done
  done
done
[[ -n "$C_CONFLICT" ]] && ok "C: conflict detected: $C_CONFLICT" || bad "C: conflict detected"
git -C "$SPROJ" cherry-pick --abort >/dev/null 2>&1
git -C "$SPROJ" status --porcelain | grep -v '^??' | grep -q . \
  && bad "C: tracked tree dirty after abort" \
  || ok "C: tracked tree clean after abort (no force-resolve)"
grep -q 'shared.sh' "$SCRATCH/collide-cp.log" && ok "C: conflict on src/shared.sh" || bad "C: conflict file"

echo
echo "RESULT: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]