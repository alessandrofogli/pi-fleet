#!/usr/bin/env bash
# loop-sample · functional checks (T-015)
#
# Deterministic, exit-0 commands used as the pipeline `checks` of
# pipeline.spec.json. These verify FUNCTIONAL correctness only (the style
# checklist is the review domain of sample-style-review / bin/audit.sh).
#
# Usage:
#   bash bin/check.sh syntax      # bash -n on every script under src/
#   bash bin/check.sh behavior    # shapes calculator smoke (rectangle area + perimeter)
# Exit 0 = pass; non-zero = fail (message on stdout/stderr).
set -u

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/src"
shapes="$SRC_DIR/shapes.sh"

case "${1:-}" in
  syntax)
    err=0
    for f in "$SRC_DIR"/*.sh; do
      [[ -f "$f" ]] || continue
      if ! bash -n "$f" 2>&1; then
        echo "SYNTAX FAIL: $f"
        err=1
      fi
    done
    [[ $err -eq 0 ]] && echo "syntax: ok"
    exit $err
    ;;
  behavior)
    [[ -x "$shapes" ]] || shapes="bash $shapes"
    r1="$($shapes rectangle 3 4)"
    r2="$($shapes rectangle 5 2)"
    p1="$($shapes perimeter 3 4)"
    [[ "$r1" == "12" && "$r2" == "10" && "$p1" == "14" ]] || {
      echo "behavior fail: rectangle 3 4 -> '$r1' (want 12), rectangle 5 2 -> '$r2' (want 10), perimeter 3 4 -> '$p1' (want 14)"
      exit 1
    }
    echo "behavior: ok (12 10 14)"
    exit 0
    ;;
  *)
    echo "usage: bash bin/check.sh syntax|behavior" >&2
    exit 2
    ;;
esac