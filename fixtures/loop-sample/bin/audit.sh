#!/usr/bin/env bash
# loop-sample · deterministic reviewer companion (T-015)
#
# Implements the sample-style-review checklist programmatically and emits the
# findings in the review-loop-protocol machine contract (the `findings` array
# of a reviewer's state file). Same input tree -> identical output (stable ids,
# deterministic locations). This is a TOOL for reviewers and the loop smoke
# test: the final review verdict belongs to the reviewer task, audit only
# provides objective evidence.
#
# Usage (from the loop-sample project root):
#   bash bin/audit.sh                # findings array on stdout (JSON)
#   bash bin/audit.sh --json         # same, explicit
#
# Emitted finding ids are stable across cycles (FINDING-SAMPLE-01..04): the
# same underlying issue keeps the same id, per review-loop-protocol.
set -u

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/src"

findings="[]"
add() {
  # add <id> <severity> <checklist> <location> <rule> <problem> <evidence> <requiredFix> <verification>
  local id="$1" sev="$2" cl="$3" loc="$4" rule="$5" prob="$6" ev="$7" rf="$8" ver="$9"
  findings="$(jq -nc --arg id "$id" --arg sev "$sev" --arg cl "$cl" --arg loc "$loc" \
    --arg rule "$rule" --arg prob "$prob" --arg ev "$ev" --arg rf "$rf" --arg ver "$ver" \
    --argjson base "$findings" \
    '$base + [{ id: $id, severity: $sev, domain: "SAMPLE", checklist: $cl,
                location: $loc, rule: $rule, problem: $prob, evidence: $ev,
                requiredFix: $rf, verification: $ver }]')"
}

[[ -d "$SRC_DIR" ]] || { printf '%s\n' "$findings"; exit 0; }

for f in "$SRC_DIR"/*.sh; do
  [[ -f "$f" ]] || continue
  # repo-relative location (review-loop-protocol contract: "src/parser.py:42")
  rel="src/${f#"$SRC_DIR"/}"
  lineno=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))

    # ---- SAMPLE-2: shebang on line 1, set -u anywhere before first command --
    if [[ "$lineno" -eq 1 ]]; then
      [[ "$line" == "#!/usr/bin/env bash" ]] || add "FINDING-SAMPLE-02" "BLOCKING" \
        "SAMPLE-2: shebang + set -u" "$rel:1" \
        "every script starts with the #!/usr/bin/env bash shebang and an unconditional set -u" \
        "missing #!/usr/bin/env bash shebang" \
        "first line is: $line" \
        "put #!/usr/bin/env bash on line 1 and add set -u before the first command" \
        "line 1 starts with #!/usr/bin/env bash and set -u is present"
    fi

    # ---- SAMPLE-3: TODO / FIXME markers -----------------------------------
    if [[ "$line" =~ TODO|FIXME ]]; then
      add "FINDING-SAMPLE-03" "BLOCKING" "SAMPLE-3: no TODO/FIXME markers" "$rel:$lineno" \
        "no line may contain TODO or FIXME" \
        "marker found: $(echo "$line" | tr -s ' ' | cut -c1-40)" \
        "grep found the marker at $rel:$lineno" \
        "remove the marker line (implement the item or delete the line)" \
        "bash bin/audit.sh no longer emits FINDING-SAMPLE-03"
    fi
  done < "$f"

  # ---- SAMPLE-1: header comment (first non-blank line after the shebang) ---
  firstcode="$(awk 'NR==1 && /^#!/ { next } NR>1 && NF>0 { print NR ":" $0; exit }' "$f")"
  if [[ -n "$firstcode" ]]; then
    line_no="${firstcode%%:*}"
    text="${firstcode#*:}"; text="${text# }"
    if [[ "$text" != \#* ]]; then
      add "FINDING-SAMPLE-01" "BLOCKING" "SAMPLE-1: header comment" "$rel:$line_no" \
        "the script starts (right after the shebang) with a # comment describing its purpose" \
        "no header comment: first code line is '$text'" \
        "first non-comment line at $rel:$line_no" \
        "add a # comment describing the script's purpose right after the shebang" \
        "bash bin/audit.sh no longer emits FINDING-SAMPLE-01"
    fi
  fi

  # ---- SAMPLE-2b: set -u present -------------------------------------------
  if ! grep -qE '^\s*set\s+-[a-z]*u([[:space:]]|$)' "$f"; then
    add "FINDING-SAMPLE-02" "BLOCKING" "SAMPLE-2: shebang + set -u" "$rel:1" \
      "every script contains an unconditional set -u (or set -eu)" \
      "missing set -u" \
      "grep -E '^\\s*set\\s+-[a-z]*u' found nothing in $rel" \
      "add set -u right after the shebang/header" \
      "bash bin/audit.sh no longer emits FINDING-SAMPLE-02"
  fi

  # ---- SAMPLE-4: functions immediately preceded by a one-line comment ------
  # walk lines; when a line matches NAME() {, the previous line must be a # comment
  prev=""
  prevno=0
  n=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n + 1))
    if [[ "$line" =~ ^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*\(\)[[:space:]]*\{ ]]; then
      fnname="$(echo "$line" | sed -nE 's/^[[:space:]]*([a-zA-Z_][a-zA-Z0-9_]*)\(\).*/\1/p')"
      if [[ -z "$prev" || "$prev" != \#* ]]; then
        add "FINDING-SAMPLE-04" "BLOCKING" "SAMPLE-4: documented functions" "$rel:$n" \
          "every function definition is immediately preceded by a one-line # comment" \
          "function '$fnname' has no comment directly above it" \
          "line above $rel:$n is blank or not a comment" \
          "add a one-line # comment directly above $fnname()" \
          "bash bin/audit.sh no longer emits FINDING-SAMPLE-04 for this location"
      fi
    fi
    prev="$line"
  done < "$f"
done

printf '%s\n' "$findings"