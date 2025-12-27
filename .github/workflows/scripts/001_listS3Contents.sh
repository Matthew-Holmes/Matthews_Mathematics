#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# Required environment variables
# -----------------------------------------------------------------------------
: "${AWS_S3_BUCKET:?AWS_S3_BUCKET is required}"

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
# Pagination state
# -----------------------------------------------------------------------------
CONTINUATION_TOKEN=""
PAGE=1

debug "Starting S3 listing for bucket: $AWS_S3_BUCKET"

while :; do
  debug "Requesting page $PAGE"

  if [[ -n "$CONTINUATION_TOKEN" ]]; then
    debug "Using continuation token: $CONTINUATION_TOKEN"
    RESPONSE=$(aws s3api list-objects-v2 \
      --bucket "$AWS_S3_BUCKET" \
      --continuation-token "$CONTINUATION_TOKEN")
  else
    debug "No continuation token (first page)"
    RESPONSE=$(aws s3api list-objects-v2 \
      --bucket "$AWS_S3_BUCKET")
  fi

  OBJECT_COUNT=$(echo "$RESPONSE" | jq '.Contents | length // 0')
  debug "Objects in this page: $OBJECT_COUNT"

  # -----------------------------------------------------------------------------
  # Output each object key (one per line)
  # -----------------------------------------------------------------------------
  echo "$RESPONSE" | jq -r '.Contents[]?.Key'

  # -----------------------------------------------------------------------------
  # Check if more pages exist
  # -----------------------------------------------------------------------------
  IS_TRUNCATED=$(echo "$RESPONSE" | jq -r '.IsTruncated // false')
  debug "IsTruncated: $IS_TRUNCATED"

  if [[ "$IS_TRUNCATED" != "true" ]]; then
    debug "No more pages. Finished."
    break
  fi

  CONTINUATION_TOKEN=$(echo "$RESPONSE" | jq -r '.NextContinuationToken // empty')
  if [[ -z "$CONTINUATION_TOKEN" ]]; then
    debug "WARNING: IsTruncated=true but no continuation token found"
    break
  fi

  ((PAGE++))
done
