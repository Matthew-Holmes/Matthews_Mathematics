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
  echo "Usage: $0 <latexSource.txt> <repo.ndjson>"
  exit 1
fi

LATEX_SRC="$1"
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

  # NDJSON-safe jq: select, do NOT map
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

  pdf_name="$(basename "$pdf_path")"
  debug "Uploading latex/$local_pdf_path -> s3://$AWS_S3_BUCKET/$pdf_name"

  aws s3 cp "latex/$pdf_path" "s3://$AWS_S3_BUCKET/$pdf_name"

done < "$LATEX_SRC"

debug "Finished processing all files"
