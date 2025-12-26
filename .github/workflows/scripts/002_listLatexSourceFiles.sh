#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# Optional debug flag
#   Enable with: DEBUG=1 ./script.sh [root_dir]
#   >&2 indicates standard error, so this doesn't interfere with output piping
# -----------------------------------------------------------------------------
DEBUG="${DEBUG:-0}"

debug() {
  if [[ "$DEBUG" == "1" ]]; then
    echo "[DEBUG] $*" >&2
  fi
}

# -----------------------------------------------------------------------------
# Timing helpers
# -----------------------------------------------------------------------------
now_ns() {
  date +%s%N
}

START_NS="$(now_ns)"

# -----------------------------------------------------------------------------
# Root directory passed as first argument (default: current directory)
# -----------------------------------------------------------------------------
ROOT_DIR="${1:-.}"
ROOT_DIR="$(cd "$ROOT_DIR" && pwd)"

debug "Root directory: $ROOT_DIR"

# -----------------------------------------------------------------------------
# Ensure we are inside a git repository
# -----------------------------------------------------------------------------
if ! git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Error: $ROOT_DIR is not inside a Git repository" >&2
  exit 1
fi

# -----------------------------------------------------------------------------
# Enumerate .tex files safely
# -----------------------------------------------------------------------------
FILE_COUNT=0

debug "Starting file enumeration"

while IFS= read -r -d '' FILE; do
  debug "Found .tex file: $FILE"

  # don't use ((...++)) here since can give exit code 1 in some bash versions
  let "FILE_COUNT+=1" 

  debug "Processing file #$FILE_COUNT"

  REL_PATH="$(realpath --relative-to="$ROOT_DIR" "$FILE")"
  debug "Processing file: $REL_PATH"

  FILE_START_NS="$(now_ns)"

  # -----------------------------------------------------------------------------
  # Get last modifying commit hash (empty if untracked)
  # -----------------------------------------------------------------------------
  if HASH="$(git -C "$ROOT_DIR" rev-list -1 HEAD -- "$REL_PATH" 2>/dev/null)"; then
    :
  else
    HASH=""
  fi

  # -----------------------------------------------------------------------------
  # File metadata
  # -----------------------------------------------------------------------------
  MTIME_EPOCH="$(stat -c %Y "$FILE")"
  SIZE_BYTES="$(stat -c %s "$FILE")"

  FILE_END_NS="$(now_ns)"
  ELAPSED_MS="$(( (FILE_END_NS - FILE_START_NS) / 1000000 ))"

  # ---------------------------------------------------------------------------
  # Generate PDF filename with git hash
  # e.g., file.tex -> file_<hash>.pdf
  # ---------------------------------------------------------------------------
  BASENAME="$(basename "$REL_PATH" .tex)"
  DIRNAME="$(dirname "$REL_PATH")"
  if [[ -n "$SHORT_HASH" ]]; then
    PDF_FILENAME="${BASENAME}_${SHORT_HASH}.pdf"
  else
    PDF_FILENAME="${BASENAME}.pdf"
  fi
  PDF_PATH="$DIRNAME/$PDF_FILENAME"

  # -----------------------------------------------------------------------------
  # Emit NDJSON (one object per line)
  # -----------------------------------------------------------------------------
  jq -cn \
    --arg path "$REL_PATH" \
    --arg git_commit "$HASH" \
    --arg root "$ROOT_DIR" \
    --arg ext "tex" \
    --argjson mtime "$MTIME_EPOCH" \
    --argjson size_bytes "$SIZE_BYTES" \
    --argjson processing_ms "$ELAPSED_MS" \
    '{
      path: $path,
      pdf_path: $pdf_path,
      extension: $ext,
      git_commit: ($git_commit | select(length > 0)),
      mtime_epoch: $mtime,
      size_bytes: $size_bytes,
      root: $root,
      processing_ms: $processing_ms
    }'

done < <(find "$ROOT_DIR" -type f -name '*.tex' -print0)

END_NS="$(now_ns)"
TOTAL_MS="$(( (END_NS - START_NS) / 1000000 ))"

debug "Processed $FILE_COUNT .tex files"
debug "Total time: ${TOTAL_MS} ms"
