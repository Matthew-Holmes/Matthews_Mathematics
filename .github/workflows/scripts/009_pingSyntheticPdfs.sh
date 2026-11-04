#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# Ask the website to start a generation run, now that this build has finished.
#
# The site passes the request on to the SyntheticPDFs generator, which only
# listens on the droplet's loopback, so this is the one way to reach it from here.
#
# A missing key fails the run, because generation can never start until the
# secret is set. Nothing else here may fail the build. The PDFs have already been
# published, and without the generator the pipeline still works, it just stops
# writing derived files. So every other problem is reported as a warning, in two
# places:
#   * the step log, as a ::warning annotation on the run's front page
#   * the job summary, with what to do about it
#
# Usage: WEBSHEETS_TRIGGER_KEY=<key> 009_pingSyntheticPdfs.sh
# Exits 1 if the key is missing, otherwise 0.
# -----------------------------------------------------------------------------
PING_URL="${SYNTHETIC_PDFS_PING_URL:-https://matthewsmathematics.uk/api/public/syntheticPDFs/ping}"
KEY_HEADER="X-WebSheets-Trigger-Key"
SECRET_NAME="WEBSHEETS_TRIGGER_KEY"
SECRET_PAGE="https://github.com/Matthew-Holmes/Matthews_Mathematics/settings/secrets/actions"

TRIGGER_KEY="${WEBSHEETS_TRIGGER_KEY:-}"

# Append a line to the job summary, when running inside GitHub Actions.
summary() {
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '%s\n' "$1" >> "$GITHUB_STEP_SUMMARY"
  fi
}

# The same escaping as 008: server and curl text can hold anything.
html_escape() {
  local text="$1"
  text="${text//&/\&amp;}"
  text="${text//</\&lt;}"
  text="${text//>/\&gt;}"
  text="${text//|/\&#124;}"
  printf '%s' "$text"
}

# warn <short title> <what happened, for the summary>
#
# Only the title goes in the annotation, so that nothing the server sent can be
# read as a workflow command.
warn() {
  echo "::warning title=Generation ping::$1"

  summary ""
  summary "## Generation ping"
  summary ""
  summary ":warning: **$1**"
  summary ""
  summary "$2"
  summary ""
  summary "This does not affect the PDFs above."
}

if [[ -z "$TRIGGER_KEY" ]]; then
  echo "::error title=Generation ping::The $SECRET_NAME secret is not set"

  summary ""
  summary "## Generation ping"
  summary ""
  summary ":x: **The $SECRET_NAME secret is not set**"
  summary ""
  summary "The generator was not asked to run, because the ping needs a key. Add it as a repository secret named <code>$SECRET_NAME</code> at $SECRET_PAGE."
  summary ""
  summary "This does not affect the PDFs above."
  exit 1
fi

BODY_FILE=$(mktemp)
ERROR_FILE=$(mktemp)

trap 'rm -f "$BODY_FILE" "$ERROR_FILE"' EXIT

CURL_STATUS=0

HTTP_CODE=$(curl -sS --max-time 30 \
  -o "$BODY_FILE" \
  -w '%{http_code}' \
  -X POST "$PING_URL" \
  -H "Content-Type: application/json" \
  -H "$KEY_HEADER: $TRIGGER_KEY" \
  -d '{}' 2>"$ERROR_FILE") || CURL_STATUS=$?

if [[ "$CURL_STATUS" -ne 0 ]]; then
  warn "The website could not be reached" \
    "The generator was not asked to run. curl exited with $CURL_STATUS: <code>$(html_escape "$(head -c 300 "$ERROR_FILE")")</code>"
  exit 0
fi

# An error from the site carries its reason in "detail". Anything else, such as a
# Cloudflare error page, is not JSON and leaves this empty.
DETAIL=$(jq -r '.detail // empty' "$BODY_FILE" 2>/dev/null || true)

case "$HTTP_CODE" in
  2*)
    # the site writes the outcome as the number of the enum member
    case "$(jq -r '.outcome // empty' "$BODY_FILE" 2>/dev/null || true)" in
      0) OUTCOME="A generation run has started." ;;
      1) OUTCOME="A run was already going, so another has been queued after it." ;;
      2) OUTCOME="A run is already going, with another queued, so nothing changed." ;;
      *) OUTCOME="The website accepted the request." ;;
    esac

    echo "Generation ping accepted: $OUTCOME"
    summary ""
    summary "## Generation ping"
    summary ""
    summary ":white_check_mark: $OUTCOME"
    ;;

  401)
    warn "The website rejected the key (HTTP 401)" \
      "The generator was not asked to run, because the <code>$SECRET_NAME</code> secret does not match the key on the server. Update it at $SECRET_PAGE."
    ;;

  *)
    if [[ -n "$DETAIL" ]]; then
      # the site cannot tell these apart: it answers 500 whether the generator
      # failed or queued the work and then reported a file it could not read
      warn "The website returned an error (HTTP $HTTP_CODE)" \
        "Server said: <code>$(html_escape "$DETAIL")</code>. Either the generator could not be reached, or it found a dictionary file it cannot read, in which case the run still went ahead. The generator's log on the droplet says which."
    else
      warn "The website returned an error (HTTP $HTTP_CODE)" \
        "The reply had no detail, so it came from Cloudflare, nginx or an unhandled error in the website. The website's log on the droplet says which, and the generator may still have been asked to run."
    fi
    ;;
esac

exit 0
