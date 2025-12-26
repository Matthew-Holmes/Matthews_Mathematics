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

# -----------------------------------------------------------------------------
# Main loop
# -----------------------------------------------------------------------------
# Extract .tex files from S3_JSON
jq -c '.[]' "$S3_JSON" | while IFS= read -r item; do
    tex_path=$(echo "$item" | jq -r '.path')
    tex_name=$(basename "$tex_path")

    # Lookup the correct pdf_path from REPO_JSON
    pdf_path=$(jq -r --arg tex "$tex_name" 'select(.path | endswith($tex)) | .pdf_path' "$REPO_JSON")
    
    if [[ -z "$pdf_path" || "$pdf_path" == "null" ]]; then
        debug "Skipping $tex_name, no matching PDF found"
        continue
    fi

    pdf_name=$(basename "$pdf_path")
    debug "Uploading $pdf_path -> s3://$AWS_S3_BUCKET/$pdf_name"

    # Upload to S3
    aws s3 cp "latex/$pdf_path" "s3://$AWS_S3_BUCKET/$pdf_name"
done
