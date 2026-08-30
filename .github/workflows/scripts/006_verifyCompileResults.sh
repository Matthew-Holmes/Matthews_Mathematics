#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# Work out, per source file, whether it actually built.
#
# The compile steps run with continue_on_error, so a single broken document no
# longer stops the ones after it -- but that also means the step's exit status
# tells us nothing about which files are safe to publish. This script inspects
# what each compile left behind and sorts the sources into "ok" and "failed",
# so only the good PDFs get uploaded and the bad ones can be reported at the end.
#
# A file counts as compiled only if all of the following hold:
#   * latexmk left a .log next to the source (otherwise it never ran)
#   * that log contains no TeX errors
#   * a .pdf exists and really is a PDF
#
# The error check matters as much as the missing-PDF check: with -halt-on-error
# a document can stop part way through and still leave a truncated PDF on disk,
# which is exactly the kind of bad file we do not want in the bucket.
#
# Usage: 006_verifyCompileResults.sh <latexCompileEngines.ndjson> [latex_root] [failed_log_dir]
# Emits NDJSON on stdout, one object per line:
#   {"path": "...", "engine": "...", "status": "ok|failed", "reason": "...", "errors": [...]}
# Always exits 0 -- reporting and failing the build is 008's job.
# -----------------------------------------------------------------------------
if [[ $# -lt 1 || $# -gt 3 ]]; then
  echo "Usage: $0 <latexCompileEngines.ndjson> [latex_root] [failed_log_dir]" >&2
  exit 1
fi

ENGINES_JSON="$1"
LATEX_ROOT="${2:-latex}"
FAILED_LOG_DIR="${3:-compileFailureLogs}"

# Number of error lines kept per file. Enough to see the cause, few enough that
# one pathological document cannot bury the report.
MAX_ERROR_LINES=12

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
TMP_ERRORS=$(mktemp)

trap '
  ELAPSED=$(( SECONDS - START_SECONDS ))
  debug "Script completed in ${ELAPSED}s"
  rm -f "$TMP_ERRORS"
' EXIT

debug "Engine classification: $ENGINES_JSON"
debug "LaTeX root:            $LATEX_ROOT"
debug "Failed log directory:  $FAILED_LOG_DIR"

mkdir -p "$FAILED_LOG_DIR"

# -----------------------------------------------------------------------------
# What an error looks like in a TeX log.
#
# The compile steps use -file-line-error, so errors are reported as
# "./file.tex:57: Undefined control sequence." Anything TeX could not recover
# from at all still comes through in the classic "! ..." form, including
# "!  ==> Fatal error occurred, no output PDF file produced!".
# -----------------------------------------------------------------------------
ERROR_RE='^(!|[^[:space:]].*\.(tex|sty|cls|clo|def|ldf|cfg|fd|lua|bbx|cbx|bst):[0-9]+:)'

OK_COUNT=0
FAILED_COUNT=0

while IFS=$'\t' read -r REL_PATH ENGINE; do
  [[ -z "$REL_PATH" ]] && continue

  BASE="${REL_PATH%.tex}"
  PDF_PATH="$LATEX_ROOT/$BASE.pdf"
  LOG_PATH="$LATEX_ROOT/$BASE.log"

  # Collect the errors first: they are the most useful reason we can give,
  # whichever of the checks below ends up rejecting the file.
  : > "$TMP_ERRORS"
  if [[ -f "$LOG_PATH" ]]; then
    grep -aE "$ERROR_RE" "$LOG_PATH" | head -n "$MAX_ERROR_LINES" > "$TMP_ERRORS" || true
  fi

  ERROR_COUNT=$(wc -l < "$TMP_ERRORS")
  FIRST_ERROR=$(head -n 1 "$TMP_ERRORS")

  STATUS="ok"

  if [[ ! -f "$LOG_PATH" ]]; then
    STATUS="failed"
    REASON="no compile log found -- the document was never built"
  elif [[ "$ERROR_COUNT" -gt 0 ]]; then
    STATUS="failed"
    REASON="$FIRST_ERROR"
  elif [[ ! -f "$PDF_PATH" ]]; then
    STATUS="failed"
    REASON="no PDF was produced"
  elif [[ "$(head -c 4 "$PDF_PATH")" != "%PDF" ]]; then
    STATUS="failed"
    REASON="output file is not a valid PDF"
  else
    REASON="compiled with $ENGINE"
  fi

  if [[ "$STATUS" == "ok" ]]; then
    let "OK_COUNT+=1"
    debug "OK     $REL_PATH ($ENGINE)"
  else
    let "FAILED_COUNT+=1"
    debug "FAILED $REL_PATH ($ENGINE): $REASON"

    # Keep the log so it can be uploaded as an artifact and read after the run.
    if [[ -f "$LOG_PATH" ]]; then
      mkdir -p "$FAILED_LOG_DIR/$(dirname "$BASE")"
      cp "$LOG_PATH" "$FAILED_LOG_DIR/$BASE.log"
    fi

    # A truncated PDF is worse than no PDF: leaving it on disk risks some later
    # step picking it up and publishing it.
    if [[ -f "$PDF_PATH" ]]; then
      debug "Removing unusable PDF: $PDF_PATH"
      rm -f "$PDF_PATH"
    fi
  fi

  jq -cn \
    --arg path "$REL_PATH" \
    --arg engine "$ENGINE" \
    --arg status "$STATUS" \
    --arg reason "$REASON" \
    --arg log "$LOG_PATH" \
    --argjson errors "$(jq -R -s -c 'split("\n") | map(select(length > 0))' "$TMP_ERRORS")" \
    '{path: $path, engine: $engine, status: $status, reason: $reason, log: $log, errors: $errors}'

done < <(jq -r '[.path, .engine] | @tsv' "$ENGINES_JSON")

debug "Compiled OK: $OK_COUNT"
debug "Failed:      $FAILED_COUNT"
