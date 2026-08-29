#!/usr/bin/env bash
# pi-fleet · wake drain — drains the durable wake queue (~/.pi/fleet/.wake-queue)
# L3.5 group barrier: also shows STATE/.wake-groups/*.json as GROUP pending
#
# Queue record format (written by fleet-watch.sh):
#   {"seq": 1234567890123, "taskId": "abc-123", "reason": "signal: abc.done", "createdAt": 1724800000}
# Each record is a JSON file in $QUEUE/*.json sorted by numeric seq.
#
# Modes:
#   (default drain)                list all records sorted, print WAKE <seq> <taskId> <reason>
#   --ack-through <SEQ>            delete records with seq <= SEQ (after chat delivery)
#   --recovery-generation <GEN>    verify generation (compatibility, warning if mismatch)
#   --json                         JSON array output instead of lines
#   --count                        print only the pending count
#
# Idempotent and safe for concurrent calls (extension + manual) via mkdir lock.
set -u

STATE="${FLEET_STATE_HOME:-$HOME/.pi/fleet}"
QUEUE="$STATE/.wake-queue"
GENERATION_FILE="$STATE/.watcher-generation"
WATCHER_DOWN="$STATE/.watcher-down"
LOCK_DIR="$STATE/.wake-queue.lock"

ACK_THROUGH=""
RECOVERY_GEN=""
OUTPUT_JSON=0
OUTPUT_COUNT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ack-through)
      ACK_THROUGH="${2:-}"
      case "$ACK_THROUGH" in ''|*[!0-9]*) echo "wake drain: invalid --ack-through sequence" >&2; exit 2 ;; esac
      shift 2
      ;;
    --recovery-generation)
      RECOVERY_GEN="${2:-}"
      case "$RECOVERY_GEN" in ''|*[!A-Za-z0-9._-]*) echo "wake drain: invalid recovery generation" >&2; exit 2 ;; esac
      shift 2
      ;;
    --json)
      OUTPUT_JSON=1
      shift
      ;;
    --count)
      OUTPUT_COUNT=1
      shift
      ;;
    --help|-h)
      sed -n '1,40p' "$0"
      exit 0
      ;;
    *)
      echo "usage: $(basename "$0") [--ack-through SEQ] [--recovery-generation GEN] [--json] [--count]" >&2
      exit 2
      ;;
  esac
done

mkdir -p "$QUEUE"

# L3.5 group info (best-effort, does not block drain)
GROUP_DIR="$STATE/.wake-groups"
if [[ -d "$GROUP_DIR" ]]; then
  for gf in "$GROUP_DIR"/*.json; do
    [[ -e "$gf" ]] || continue
    gid=$(jq -r '.groupId // empty' "$gf" 2>/dev/null || echo "")
    [[ -n "$gid" ]] || gid=$(basename "$gf" .json)
    pending=$(jq -r '.pending | length // 0' "$gf" 2>/dev/null || echo "?")
    expected=$(jq -r '.expected // "?"' "$gf" 2>/dev/null || echo "?")
    # print to stderr not to break --json/--count, but visible in default drain
    if [[ "$OUTPUT_JSON" != 1 && "$OUTPUT_COUNT" != 1 ]]; then
      echo "GROUP $gid pending $pending/$expected" >&2
    fi
  done
fi

# Recovery generation check (compatibility, does not block)
if [[ -n "$RECOVERY_GEN" ]]; then
  current_gen=$(cat "$GENERATION_FILE" 2>/dev/null | tr -d '[:space:]' || true)
  if [[ -n "$current_gen" && "$current_gen" != "$RECOVERY_GEN" ]]; then
    echo "wake drain: warning recovery generation mismatch: current=$current_gen ack=$RECOVERY_GEN" >&2
  fi
fi

# Acquire queue lock via mkdir with retry (5 volte, sleep 0.1)
acquire_queue_lock() {
  local i=0
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    if [[ $i -ge 5 ]]; then
      echo "wake drain: queue lock busy, retry exhausted" >&2
      return 1
    fi
    sleep 0.1
    i=$((i+1))
  done
  return 0
}

release_queue_lock() {
  rmdir "$LOCK_DIR" 2>/dev/null || true
}

# Ensure lock is released on exit
trap 'release_queue_lock' EXIT INT TERM

if ! acquire_queue_lock; then
  exit 1
fi

# Collect queue files sorted numerically by seq (filename or content)
# We sort by numeric value in filename first, then validate with jq seq.
queue_files=()
while IFS= read -r -d '' f; do
  queue_files+=("$f")
done < <(find "$QUEUE" -maxdepth 1 -name "*.json" -type f -print0 2>/dev/null | sort -z -n)

count=${#queue_files[@]}

# --count mode
if [[ "$OUTPUT_COUNT" == 1 ]]; then
  echo "$count"
  # Still handle ack if requested
  if [[ -n "$ACK_THROUGH" ]]; then
    removed=0
    for f in "${queue_files[@]}"; do
      seq=$(jq -r '.seq // empty' "$f" 2>/dev/null || echo "")
      # Fallback: extract numeric from filename
      if [[ -z "$seq" || ! "$seq" =~ ^[0-9]+$ ]]; then
        base=$(basename "$f" .json)
        if [[ "$base" =~ ^[0-9]+$ ]]; then seq="$base"; else continue; fi
      fi
      if [[ "$seq" -le "$ACK_THROUGH" ]] 2>/dev/null; then
        rm -f "$f" 2>/dev/null && removed=$((removed+1)) || true
      fi
    done
    # Optional watcher-down cleanup
    if [[ ! -e "$QUEUE" ]] || [[ -z "$(ls -A "$QUEUE" 2>/dev/null)" ]]; then
      : # queue empty, optional cleanup of watcher-down marker handled below
    fi
  fi
  exit 0
fi

# Empty queue
if [[ "$count" -eq 0 ]]; then
  echo "no pending wakes"
  # Optional cleanup: if the queue is empty and watcher-down exists, we do not delete automatically
  # (the recovery generation contract wants an explicit ack), but leave the marker intact.
  # Ack-through on an empty queue is still valid: if watcher-down exists, the ack can retire it,
  # but this script does not do it without --ack-through + generation.
  exit 0
fi

# Build validated records
valid_records=()
invalid_count=0
for f in "${queue_files[@]}"; do
  if ! jq -e . "$f" >/dev/null 2>&1; then
    echo "wake drain: warning invalid JSON in $f, skipping" >&2
    invalid_count=$((invalid_count+1))
    continue
  fi
  # Extract fields
  seq=$(jq -r '.seq // empty' "$f" 2>/dev/null || echo "")
  taskId=$(jq -r '.taskId // empty' "$f" 2>/dev/null || echo "")
  reason=$(jq -r '.reason // empty' "$f" 2>/dev/null || echo "")
  if [[ -z "$seq" || ! "$seq" =~ ^[0-9]+$ ]]; then
    # Try filename fallback
    base=$(basename "$f" .json)
    if [[ "$base" =~ ^[0-9]+$ ]]; then seq="$base"; else seq="0"; fi
  fi
  valid_records+=("$f|$seq|$taskId|$reason")
done

# Sort valid_records by seq numeric
if [[ ${#valid_records[@]} -gt 0 ]]; then
  IFS=$'\n' sorted_records=($(printf '%s\n' "${valid_records[@]}" | sort -t'|' -k2 -n))
  unset IFS
else
  sorted_records=()
fi

# Handle --ack-through before or after print? Spec: drain then ack. We print then ack.
# For --json, output JSON array; for default, print lines.

if [[ "$OUTPUT_JSON" == 1 ]]; then
  # Output JSON array of objects
  json_array="["
  first=1
  for rec in "${sorted_records[@]}"; do
    f=$(printf '%s' "$rec" | cut -d'|' -f1)
    content=$(cat "$f" 2>/dev/null || echo "{}")
    # Validate it's JSON object
    if ! jq -e . >/dev/null 2>&1 <<<"$content"; then continue; fi
    if [[ "$first" == 1 ]]; then first=0; else json_array+=", "; fi
    # Compact JSON
    compact=$(jq -c . <<<"$content" 2>/dev/null || printf '%s' "$content")
    json_array+="$compact"
  done
  json_array+="]"
  # Pretty print via jq if possible
  if printf '%s' "$json_array" | jq . >/dev/null 2>&1; then
    printf '%s\n' "$json_array" | jq .
  else
    printf '%s\n' "$json_array"
  fi
else
  # Default: print WAKE lines
  for rec in "${sorted_records[@]}"; do
    f=$(printf '%s' "$rec" | cut -d'|' -f1)
    seq=$(printf '%s' "$rec" | cut -d'|' -f2)
    taskId=$(printf '%s' "$rec" | cut -d'|' -f3)
    reason=$(printf '%s' "$rec" | cut -d'|' -f4)
    # Pretty print: WAKE <seq> <taskId> <reason>
    printf 'WAKE %s %s %s\n' "$seq" "$taskId" "$reason"
    # Also print raw JSON for completeness if reason empty
    if [[ -z "$reason" ]]; then
      cat "$f" 2>/dev/null | jq -c . 2>/dev/null || cat "$f" 2>/dev/null || true
      echo
    fi
  done
fi

# Handle --ack-through: remove files with seq <= cutoff
if [[ -n "$ACK_THROUGH" ]]; then
  removed=0
  for rec in "${sorted_records[@]}"; do
    f=$(printf '%s' "$rec" | cut -d'|' -f1)
    seq=$(printf '%s' "$rec" | cut -d'|' -f2)
    if [[ "$seq" -le "$ACK_THROUGH" ]] 2>/dev/null; then
      rm -f "$f" 2>/dev/null && removed=$((removed+1)) || true
    fi
  done
  if [[ "$OUTPUT_JSON" != 1 ]]; then
    echo "acked $removed records through $ACK_THROUGH" >&2
  fi
fi

# After drain, if the queue is empty and .watcher-down exists, optional cleanup (non-destructive)
# Only if the ack drained the queue and the recovery generation has been verified
if [[ -n "$ACK_THROUGH" ]]; then
  remaining=$(find "$QUEUE" -maxdepth 1 -name "*.json" -type f 2>/dev/null | wc -l | tr -d '[:space:]')
  case "$remaining" in ''|*[!0-9]*) remaining=0 ;; esac
  if [[ "$remaining" -eq 0 && -f "$WATCHER_DOWN" && -n "$RECOVERY_GEN" ]]; then
    # Recovery marker can be considered handled; leave it for explicit ack via fleet-watch-arm handling-delivered
    : # no auto-remove; firstmate semantics keep marker until ack-through with generation
  fi
fi

exit 0
