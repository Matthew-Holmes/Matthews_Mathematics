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
    debug "Processing line $line_number: $tex_path"

    # Skip empty lines
    if [[ -z "$tex_path" ]]; then
        debug "Line $line_number: empty line, skipping"
        continue
    fi

    tex_name=$(basename "$tex_path")
    debug "Line $line_number: tex_name = $tex_name"

    # Lookup the correct PDF path in REPO_JSON
    pdf_path=$(jq -r --arg tex "$tex_name" 'map(select(.path | endswith($tex))) | .[0].pdf_path' "$REPO_JSON")
    debug "Line $line_number: pdf_path = $pdf_path"

    if [[ -z "$pdf_path" || "$pdf_path" == "null" ]]; then
        debug "Skipping $tex_name, no matching PDF found"
        continue
    fi

    pdf_name=$(basename "$pdf_path")
    debug "Uploading $pdf_path -> s3://$AWS_S3_BUCKET/$pdf_name"

    # Upload to S3
    if [[ "$DEBUG" == "1" ]]; then
        debug "aws s3 cp latex/$pdf_path s3://$AWS_S3_BUCKET/$pdf_name (simulated)"
    else
        aws s3 cp "latex/$pdf_path" "s3://$AWS_S3_BUCKET/$pdf_name"
    fi

done < "$LATEX_SRC"
