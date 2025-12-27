#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# Input arguments
# -----------------------------------------------------------------------------
if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <objects.txt> <repo.ndjson>"
  exit 1
fi

OBJECTS_TXT="$1"
REPO_JSON="$2"

# -----------------------------------------------------------------------------
# Optional debug flag
# -----------------------------------------------------------------------------
DEBUG="${DEBUG:-0}"

debug() {
  if [[ "$DEBUG" == "1" ]]; then
    echo "[DEBUG] $*" >&2
  fi
}

START_SECONDS=$SECONDS

# -----------------------------------------------------------------------------
# Temporary files
# -----------------------------------------------------------------------------
TMP_REPO_PDFS=$(mktemp)
TMP_S3_PDFS=$(mktemp)
TMP_MISSING=$(mktemp)

debug "Created temp files:"
debug "  TMP_REPO_PDFS=$TMP_REPO_PDFS"
debug "  TMP_S3_PDFS=$TMP_S3_PDFS"
debug "  TMP_MISSING=$TMP_MISSING"

trap '
  ELAPSED=$(( SECONDS - START_SECONDS ))
  debug "Script completed in ${ELAPSED}s"
  debug "Cleaning up temp files"
  rm -f "$TMP_REPO_PDFS" "$TMP_S3_PDFS" "$TMP_MISSING"
' EXIT

# -----------------------------------------------------------------------------
# 1) Repo: PDF filenames from JSON (already include git hash)
# -----------------------------------------------------------------------------
jq -r '
  select(.extension == "tex") |
  .pdf_path
' "$REPO_JSON" | sort -u > "$TMP_REPO_PDFS"

debug "Repo PDF count: $(wc -l < "$TMP_REPO_PDFS")"

# -----------------------------------------------------------------------------
# 2) S3: existing PDFs (from objects.txt)
# -----------------------------------------------------------------------------
grep -E '\.pdf$' "$OBJECTS_TXT" | sort -u > "$TMP_S3_PDFS"

debug "S3 PDF count: $(wc -l < "$TMP_S3_PDFS")"

# -----------------------------------------------------------------------------
# 3) PDFs in repo but NOT in S3 → missing PDFs
# -----------------------------------------------------------------------------
comm -23 "$TMP_REPO_PDFS" "$TMP_S3_PDFS" > "$TMP_MISSING"

debug "Missing PDFs count: $(wc -l < "$TMP_MISSING")"

# -----------------------------------------------------------------------------
# 4) Map missing PDFs back to their .tex files and echo paths
# -----------------------------------------------------------------------------
MISSING_JSON=$(jq -R -s -c 'split("\n")[:-1]' "$TMP_MISSING")

jq -r --argjson missing "$MISSING_JSON" '
  select(.extension == "tex") |
  select(.pdf_path as $pdf | ($missing | index($pdf))) |
  .path
' "$REPO_JSON"
