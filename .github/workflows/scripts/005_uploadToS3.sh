#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# Required environment variables
# -----------------------------------------------------------------------------
: "${AWS_S3_BUCKET:?AWS_S3_BUCKET is required}"

# -----------------------------------------------------------------------------
# Input arguments
# -----------------------------------------------------------------------------
if [[ $# -ne 3 ]]; then
  echo "Usage: $0 <latexSource.txt> <repo.ndjson> <objects.txt>"
  exit 1
fi

LATEX_SRC="$1"
REPO_JSON="$2"
OBJECTS_TXT="$3"

# -----------------------------------------------------------------------------
# Optional debug flag
# -----------------------------------------------------------------------------
DEBUG="${DEBUG:-0}"

debug() {
  if [[ "$DEBUG" == "1" ]]; then
    echo "[DEBUG] $*" >&2
  fi
}

# -----------------------------------------------------------------------------
# Temp files
# -----------------------------------------------------------------------------
TMP_NEW_KEYS=$(mktemp)
TMP_UPDATED_MANIFEST=$(mktemp)

trap '
  rm -f "$TMP_NEW_KEYS" "$TMP_UPDATED_MANIFEST"
' EXIT

# -----------------------------------------------------------------------------
# Main loop
# -----------------------------------------------------------------------------
line_number=0

while IFS= read -r tex_path; do
  line_number=$((line_number+1))

  debug "----------------------------------------"
  debug "Processing TEX line $line_number: $tex_path"

  [[ -z "$tex_path" ]] && continue

  tex_name="$(basename "$tex_path")"
  debug "tex_name = $tex_name"

  pdf_path=$(
    jq -r --arg tex "$tex_name" '
      select(.path | endswith($tex)) | .pdf_path
    ' "$REPO_JSON" | head -n 1
  )

  local_pdf_path=$(
    jq -r --arg tex "$tex_name" '
      select(.path | endswith($tex))
      | .pdf_path
      | sub("_[^.]{12}\\.pdf$"; ".pdf")
    ' "$REPO_JSON" | head -n 1
  )

  debug "pdf_path = $pdf_path"
  debug "local_pdf_path = $local_pdf_path"

  if [[ -z "$local_pdf_path" || "$local_pdf_path" == "null" ]]; then
    debug "No PDF match found for $tex_name"
    continue
  fi

  debug "Uploading latex/$local_pdf_path -> s3://$AWS_S3_BUCKET/$pdf_path"
  aws s3 cp "latex/$local_pdf_path" "s3://$AWS_S3_BUCKET/$pdf_path"

  # Track newly added object
  echo "$pdf_path" >> "$TMP_NEW_KEYS"

done < "$LATEX_SRC"

debug "Finished uploading PDFs"

# -----------------------------------------------------------------------------
# Update manifest (add new keys)
# -----------------------------------------------------------------------------
debug "Updating manifest"

cat "$OBJECTS_TXT" "$TMP_NEW_KEYS" \
  | sort -u \
  > "$TMP_UPDATED_MANIFEST"

debug "Old manifest count: $(wc -l < "$OBJECTS_TXT")"
debug "New keys added: $(sort -u "$TMP_NEW_KEYS" | wc -l)"
debug "Updated manifest count: $(wc -l < "$TMP_UPDATED_MANIFEST")"

# -----------------------------------------------------------------------------
# Upload updated manifest to S3
# -----------------------------------------------------------------------------
debug "Uploading updated manifest to s3://$AWS_S3_BUCKET/latex/manifest.txt"
aws s3 cp "$TMP_UPDATED_MANIFEST" "s3://$AWS_S3_BUCKET/latex/manifest.txt"

debug "Manifest update complete"
