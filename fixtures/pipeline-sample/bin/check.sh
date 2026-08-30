#!/usr/bin/env bash
# pipeline-sample · functional check (T-017)
#
# Deterministic, exit-0 command used as the pipeline `checks` of the
# converted pipeline.spec.json. Verifies the slice OUTPUTS of the
# implementation pipeline: every script under src/ must parse (bash -n)
# and the slice-created files must exist with their content markers.
# The pipeline is complete ONLY when both slices shipped their files.
#
# Usage:
#   bash bin/check.sh syntax      # exit 0 = pass; non-zero = fail
set -u

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/src"
err=0

for f in "$SRC_DIR"/*.sh; do
  [[ -f "$f" ]] || continue
  if ! bash -n "$f" 2>&1; then
    echo "SYNTAX FAIL: $f"
    err=1
  fi
done

# slice outputs must exist and carry their markers (lib = wave 1, cli = wave 2)
while IFS= read -r spec; do
  marker="${spec#*:}"
  file="$SRC_DIR/${spec%%:*}"
  if [[ ! -f "$file" ]]; then
    echo "MISSING SLICE OUTPUT: $file"
    err=1
  elif ! grep -q "$marker" "$file" 2>/dev/null; then
    echo "MISSING MARKER '$marker' in $file"
    err=1
  fi
done <<'EOF'
lib.sh:lib
cli.sh:cli
EOF

[[ $err -eq 0 ]] && echo "syntax: ok (lib + cli shipped)"
exit $err