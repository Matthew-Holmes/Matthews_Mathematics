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
# Temp files
# -----------------------------------------------------------------------------
TMP_REPO_PDFS=$(mktemp)
TMP_S3_PDFS=$(mktemp)
TMP_DELETE=$(mktemp)
TMP_UPDATED_MANIFEST=$(mktemp)

debug "Created temp files:"
debug "  TMP_REPO_PDFS=$TMP_REPO_PDFS"
debug "  TMP_S3_PDFS=$TMP_S3_PDFS"
debug "  TMP_DELETE=$TMP_DELETE"
debug "  TMP_UPDATED_MANIFEST=$TMP_UPDATED_MANIFEST"

trap '
  ELAPSED=$(( SECONDS - START_SECONDS ))
  debug "Script completed in ${ELAPSED}s"
  debug "Cleaning up temp files"
  rm -f "$TMP_REPO_PDFS" "$TMP_S3_PDFS" "$TMP_DELETE" "$TMP_UPDATED_MANIFEST"
' EXIT

# -----------------------------------------------------------------------------
# 1) Repo: active PDF filenames (already include git hash)
# -----------------------------------------------------------------------------
jq -r '
  select(.extension == "tex") |
  .pdf_path
' "$REPO_JSON" | sort -u > "$TMP_REPO_PDFS"

debug "Repo PDF count: $(wc -l < "$TMP_REPO_PDFS")"

# -----------------------------------------------------------------------------
# 2) S3: existing PDFs from objects.txt
# -----------------------------------------------------------------------------
grep -E '\.pdf$' "$OBJECTS_TXT" | sort -u > "$TMP_S3_PDFS"

debug "S3 PDF count: $(wc -l < "$TMP_S3_PDFS")"

# -----------------------------------------------------------------------------
# 3) PDFs in S3 but NOT in repo (to be deleted)
# -----------------------------------------------------------------------------
comm -23 "$TMP_S3_PDFS" "$TMP_REPO_PDFS" > "$TMP_DELETE"

debug "PDFs to delete: $(wc -l < "$TMP_DELETE")"

# -----------------------------------------------------------------------------
# 4) Create UPDATED manifest (remove files that will be deleted)
# -----------------------------------------------------------------------------
comm -23 <(sort -u "$OBJECTS_TXT") "$TMP_DELETE" > "$TMP_UPDATED_MANIFEST"

debug "Updated manifest count: $(wc -l < "$TMP_UPDATED_MANIFEST")"

# -----------------------------------------------------------------------------
# 5) Upload updated manifest BEFORE deleting objects
# -----------------------------------------------------------------------------
debug "Uploading updated manifest to s3://$AWS_S3_BUCKET/manifest.txt"
aws s3 cp "$TMP_UPDATED_MANIFEST" "s3://$AWS_S3_BUCKET/manifest.txt"

# -----------------------------------------------------------------------------
# 6) Delete obsolete PDFs
# -----------------------------------------------------------------------------
while read -r key; do
  [[ -z "$key" ]] && continue
  debug "Deleting s3://$AWS_S3_BUCKET/$key"
  aws s3 rm "s3://$AWS_S3_BUCKET/$key"
done < "$TMP_DELETE"
