#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# Required environment variables
# -----------------------------------------------------------------------------
: "${AWS_S3_BUCKET:?AWS_S3_BUCKET is required}"

# -----------------------------------------------------------------------------
# Input arguments
# -----------------------------------------------------------------------------

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <s3.ndjson> <repo.ndjson>"
  exit 1
fi

S3_JSON="$1"
REPO_JSON="$2"

# -----------------------------------------------------------------------------
# Optional debug flag
#   Enable with: DEBUG=1 ./script.sh
#   >&2 indicates standard error, so this doesn't interfere with output piping
# -----------------------------------------------------------------------------
DEBUG="${DEBUG:-0}"

debug() {
  if [[ "$DEBUG" == "1" ]]; then
    echo "[DEBUG] $*" >&2
  fi
}

START_SECONDS=$SECONDS

# -----------------------------------------------------------------------------
# Create list of active pdf files from LaTeX source files
# Since filenames contain git hashes, we will delete any files with
# recent modifications
# -----------------------------------------------------------------------------

TMP_REPO_PDFS=$(mktemp)
TMP_S3_PDFS=$(mktemp)
TMP_DELETE=$(mktemp)

debug "Created temp files:"
debug "  TMP_REPO_PDFS=$TMP_REPO_PDFS"
debug "  TMP_S3_PDFS=$TMP_S3_PDFS"
debug "  TMP_DELETE=$TMP_DELETE"

# Cleanup temp files on exit
trap '
  ELAPSED=$(( SECONDS - START_SECONDS ))
  debug "Script completed in ${ELAPSED}s"
  debug "Cleaning up temp files"
  rm -f "$TMP_REPO_PDFS" "$TMP_S3_PDFS" "$TMP_DELETE"
' EXIT

# 1) Repo: PDF filenames from JSON (already include git hash)
jq -r '
  select(.extension == "tex") |
  .pdf_path
' "$REPO_JSON" | sort -u > "$TMP_REPO_PDFS"

debug "Repo PDF count: $(wc -l < "$TMP_REPO_PDFS")"

# 2) S3: existing PDFs
jq -r '
  select(.Key | endswith(".pdf")) |
  .Key
' "$S3_JSON" | sort -u > "$TMP_S3_PDFS"

debug "S3 PDF count: $(wc -l < "$TMP_S3_PDFS")"

# 3) PDFs in S3 but NOT in repo
comm -23 "$TMP_S3_PDFS" "$TMP_REPO_PDFS" > "$TMP_DELETE"

debug "PDFs to delete: $(wc -l < "$TMP_DELETE")"

# 4) Delete
while read -r key; do
  [[ -z "$key" ]] && continue
  debug "Deleting s3://$AWS_S3_BUCKET/$key"
  aws s3 rm "s3://$AWS_S3_BUCKET/$key"
done < "$TMP_DELETE"