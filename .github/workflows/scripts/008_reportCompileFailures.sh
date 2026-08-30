#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# Turn the compile results into something readable, then fail the build if any
# document did not compile.
#
# Everything that built has already been uploaded by the time this runs, so the
# only job left is to say clearly which sources need fixing. The report goes to
# three places, because each is useful in a different situation:
#   * the step log, for anyone already reading the run
#   * the job summary, so the failures are visible on the run's front page
#   * ::error annotations, which attach the message to the offending line
#
# Usage: 008_reportCompileFailures.sh <latexCompileResults.ndjson> [latex_root]
# Exits 1 if any document failed to compile.
# -----------------------------------------------------------------------------
if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 <latexCompileResults.ndjson> [latex_root]" >&2
  exit 1
fi

RESULTS_JSON="$1"
LATEX_ROOT="${2:-latex}"

# How much of a failing document's log to print into the step output. Enough to
# read the whole thing for anything normal, capped so that one runaway document
# cannot flood the run page. The artifact always holds the untruncated log.
MAX_LOG_LINES=500

# -----------------------------------------------------------------------------
# Optional debug flag
# -----------------------------------------------------------------------------
DEBUG="${DEBUG:-0}"

debug() {
  if [[ "$DEBUG" == "1" ]]; then
    echo "[DEBUG] $*" >&2
  fi
}

# Append a line to the job summary, when running inside GitHub Actions.
summary() {
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '%s\n' "$1" >> "$GITHUB_STEP_SUMMARY"
  fi
}

# LaTeX error text is full of characters a markdown table takes personally: a
# pipe splits the row, a backtick closes the code span (TeX quotes filenames as
# `foo.sty') and angle brackets read as HTML. A <code> cell plus entities for
# the lot is the only combination that survives.
html_escape() {
  local text="$1"
  # The backslashes matter: bash 5.1 onwards reads a bare & in a substitution
  # replacement as "the text that matched".
  text="${text//&/\&amp;}"
  text="${text//</\&lt;}"
  text="${text//>/\&gt;}"
  text="${text//|/\&#124;}"
  printf '%s' "$text"
}

RULE="========================================================================"

# -----------------------------------------------------------------------------
# Counts
# -----------------------------------------------------------------------------
TOTAL=$(jq -s 'length' "$RESULTS_JSON")
OK_COUNT=$(jq -s '[.[] | select(.status == "ok")] | length' "$RESULTS_JSON")
FAILED_COUNT=$(jq -s '[.[] | select(.status == "failed")] | length' "$RESULTS_JSON")

debug "total=$TOTAL ok=$OK_COUNT failed=$FAILED_COUNT"

# -----------------------------------------------------------------------------
# Nothing to compile, or everything compiled
# -----------------------------------------------------------------------------
if [[ "$TOTAL" -eq 0 ]]; then
  echo "$RULE"
  echo " LaTeX build report: no documents needed compiling."
  echo "$RULE"
  summary "## LaTeX build report"
  summary ""
  summary "No documents needed compiling -- every PDF in the bucket is already up to date."
  exit 0
fi

if [[ "$FAILED_COUNT" -eq 0 ]]; then
  echo "$RULE"
  printf ' LaTeX build report: all %s document(s) compiled and were uploaded.\n' "$TOTAL"
  echo "$RULE"
  summary "## LaTeX build report"
  summary ""
  summary ":white_check_mark: All **$TOTAL** document(s) compiled and were uploaded."
  exit 0
fi

# -----------------------------------------------------------------------------
# Plain-text report for the step log
# -----------------------------------------------------------------------------
echo "$RULE"
echo " LaTeX build report"
echo "$RULE"
printf ' Compiled and uploaded : %s\n' "$OK_COUNT"
printf ' Failed to compile     : %s\n' "$FAILED_COUNT"
echo
echo " The documents below did NOT compile and were NOT uploaded. Every other"
echo " document in this run was published as normal."
echo

while IFS=$'\t' read -r REL_PATH ENGINE REASON; do
  echo "$RULE"
  printf ' %s\n' "$LATEX_ROOT/$REL_PATH"
  printf '   engine : %s\n' "$ENGINE"
  printf '   reason : %s\n' "$REASON"

  if jq -e --arg p "$REL_PATH" \
       'select(.path == $p) | .errors | length > 0' "$RESULTS_JSON" >/dev/null; then
    echo
    jq -r --arg p "$REL_PATH" 'select(.path == $p) | .errors[] | "   | " + .' "$RESULTS_JSON"
  fi
  echo
done < <(jq -r 'select(.status == "failed") | [.path, .engine, .reason] | @tsv' "$RESULTS_JSON")

echo "$RULE"
echo " Each full log is expandable below, and also in the compile-failure-logs artifact."
echo "$RULE"

# -----------------------------------------------------------------------------
# The full logs, folded into collapsible groups.
#
# The report above is the summary; this is the detail, so a whole log can be
# read on the run page without downloading anything. Command processing is
# switched off around the contents, so no line of a TeX log can be mistaken for
# a workflow command.
# -----------------------------------------------------------------------------
while IFS=$'\t' read -r REL_PATH LOG_PATH; do
  [[ -f "$LOG_PATH" ]] || continue

  LOG_LINES=$(wc -l < "$LOG_PATH")
  STOP_TOKEN="endOfLatexLog-$RANDOM$RANDOM"

  echo "::group::Full log: $LATEX_ROOT/$REL_PATH"
  echo "::stop-commands::$STOP_TOKEN"

  # -halt-on-error stops at the first error, so when a log is too long to be
  # worth printing whole it is the end of it that matters.
  if [[ "$LOG_LINES" -gt "$MAX_LOG_LINES" ]]; then
    echo "[$(( LOG_LINES - MAX_LOG_LINES )) earlier lines omitted -- the whole log is in the compile-failure-logs artifact]"
    echo
    tail -n "$MAX_LOG_LINES" "$LOG_PATH"
  else
    cat "$LOG_PATH"
  fi

  echo "::$STOP_TOKEN::"
  echo "::endgroup::"
done < <(jq -r 'select(.status == "failed") | [.path, .log] | @tsv' "$RESULTS_JSON")

# -----------------------------------------------------------------------------
# ::error annotations, so each failure is attached to its source line
# -----------------------------------------------------------------------------
while IFS=$'\t' read -r REL_PATH REASON; do
  # -file-line-error reports "./name.tex:57: message". Only trust that line
  # number when the error is in the root file itself rather than a package.
  LINE=""
  if [[ "$REASON" =~ ^(\./)?([^:]+):([0-9]+): ]]; then
    if [[ "$(basename "${BASH_REMATCH[2]}")" == "$(basename "$REL_PATH")" ]]; then
      LINE="${BASH_REMATCH[3]}"
    fi
  fi

  if [[ -n "$LINE" ]]; then
    echo "::error file=$LATEX_ROOT/$REL_PATH,line=$LINE,title=LaTeX compile failed::$REASON"
  else
    echo "::error file=$LATEX_ROOT/$REL_PATH,title=LaTeX compile failed::$REASON"
  fi
done < <(jq -r 'select(.status == "failed") | [.path, .reason] | @tsv' "$RESULTS_JSON")

# -----------------------------------------------------------------------------
# Job summary
# -----------------------------------------------------------------------------
summary "## LaTeX build report"
summary ""
summary ":white_check_mark: **$OK_COUNT** compiled and uploaded &nbsp;&nbsp; :x: **$FAILED_COUNT** failed to compile"
summary ""
summary "The documents below were **not** uploaded. Everything else in this run was published as normal."
summary ""
summary "| Document | Engine | Error |"
summary "| --- | --- | --- |"

while IFS=$'\t' read -r REL_PATH ENGINE REASON; do
  summary "| <code>$REL_PATH</code> | $ENGINE | <code>$(html_escape "$REASON")</code> |"
done < <(jq -r 'select(.status == "failed") | [.path, .engine, .reason] | @tsv' "$RESULTS_JSON")

summary ""
summary "Full \`.log\` files are in the **compile-failure-logs** artifact."

while IFS= read -r REL_PATH; do
  summary ""
  summary "<details><summary><code>$REL_PATH</code></summary>"
  summary ""
  summary '```'
  jq -r --arg p "$REL_PATH" 'select(.path == $p) | .errors[]' "$RESULTS_JSON" \
    | while IFS= read -r line; do summary "$line"; done
  summary '```'
  summary ""
  summary "</details>"
done < <(jq -r 'select(.status == "failed") | select(.errors | length > 0) | .path' "$RESULTS_JSON")

exit 1
