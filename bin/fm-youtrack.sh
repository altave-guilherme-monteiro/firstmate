#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

TOKEN_FILE="$CONFIG/youtrack-token"
URL_FILE="$CONFIG/youtrack-url"
QUERIES_FILE="$CONFIG/youtrack-queries"

usage() {
  cat <<'USAGE'
fm-youtrack.sh - thin read/write client for a YouTrack issue tracker.

Firstmate is board-aware: work resolves to a tracker issue at intake
(AGENTS.md section 7), and the session-start digest reports what the board
and the local fleet disagree about. This script is the one place that talks
to the YouTrack REST API, so every caller shares one auth path, one config
format, and one guarantee that a home without a tracker sees zero behavior
change.

Usage:
  fm-youtrack.sh get <api-path>
      GET https://<url><api-path>; print the raw JSON response body.
      <api-path> starts with / (e.g. /api/issues/FM-123?fields=summary).
  fm-youtrack.sh post <api-path> <json>
      POST <json> to https://<url><api-path>; print the raw JSON response
      body. <json> must be a valid JSON document.
  fm-youtrack.sh queries
      Resolve every entry in config/youtrack-queries (a saved-query name
      first, falling back to the entry itself as a raw YouTrack query) and
      print the matching issues as tab-separated id, type, state, team,
      summary - one line per issue, one query at a time, in file order.
      Exits non-zero when every configured query fails to read from the
      tracker, so a read failure is never mistaken for a genuinely empty
      result; a partial failure still prints what succeeded and exits 0.
  fm-youtrack.sh -h|--help

Config, all LOCAL and gitignored under the effective firstmate home
(FM_HOME, defaulting to this script's own repo root):
  config/youtrack-token     required. First non-blank, non-comment line is
                             used verbatim when it starts with "perm-" or
                             "perm:" (a bare permanent token legitimately
                             contains further = characters); otherwise a
                             NAME= prefix before the first = is stripped.
  config/youtrack-url       optional. Default https://altave.youtrack.cloud
  config/youtrack-queries   optional. One saved-query name or raw YouTrack
                             query per line; blank lines and comment lines
                             (leading hash mark) are ignored. Only consulted
                             by the queries command.

Not configured: an absent or symlinked config/youtrack-token means the
tracker integration is off for this home. Every command then exits non-zero
with one diagnostic line on stderr and makes NO network call - test with
"-f config/youtrack-token", never by parsing this script's error text.

Secrecy: the token is never printed, never placed in an error message, and
never written to a log or a wide-permission temp file - it reaches curl
through a 0600 Authorization-header file removed before this script exits.
USAGE
}

yt_configured() {
  [ -f "$TOKEN_FILE" ] && [ ! -L "$TOKEN_FILE" ]
}

yt_token() {
  local line
  line=$(grep -vE '^[[:space:]]*(#|$)' "$TOKEN_FILE" 2>/dev/null | head -1) || return 1
  [ -n "$line" ] || return 1
  case "$line" in
    perm-*|perm:*) printf '%s' "$line" ;;
    *=*) printf '%s' "${line#*=}" ;;
    *) printf '%s' "$line" ;;
  esac
}

yt_url() {
  local line=
  if [ -f "$URL_FILE" ] && [ ! -L "$URL_FILE" ]; then
    line=$(grep -vE '^[[:space:]]*(#|$)' "$URL_FILE" 2>/dev/null | head -1)
  fi
  line=${line:-https://altave.youtrack.cloud}
  printf '%s' "${line%/}"
}

yt_auth_header_file() {
  local token file
  token=$(yt_token) || return 1
  case "$token" in
    ''|*$'\n'*|*$'\r'*) return 1 ;;
  esac
  file=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-youtrack-auth.XXXXXX") || return 1
  chmod 600 "$file" 2>/dev/null || { rm -f "$file"; return 1; }
  printf 'Authorization: Bearer %s\n' "$token" > "$file" || { rm -f "$file"; return 1; }
  printf '%s\n' "$file"
}

require_configured() {
  yt_configured || {
    echo "fm-youtrack: tracker not configured (no config/youtrack-token)" >&2
    exit 1
  }
}

yt_request() {
  local method=$1 path=$2 body=${3:-} auth_file url code out rc=0
  command -v curl >/dev/null 2>&1 || { echo "fm-youtrack: curl not found" >&2; exit 1; }
  auth_file=$(yt_auth_header_file) || {
    echo "fm-youtrack: no usable token in config/youtrack-token" >&2
    exit 1
  }
  url="$(yt_url)$path"
  out=$(mktemp "${TMPDIR:-/tmp}/fm-youtrack-body.XXXXXX") || { rm -f "$auth_file"; exit 1; }
  case "$method" in
    GET)
      code=$(curl -m 20 -s -o "$out" -w '%{http_code}' \
        -H "@$auth_file" -H 'Accept: application/json' \
        "$url" 2>/dev/null) || code=000
      ;;
    POST)
      code=$(curl -m 20 -s -o "$out" -w '%{http_code}' -X POST \
        -H "@$auth_file" -H 'Content-Type: application/json' -H 'Accept: application/json' \
        --data "$body" "$url" 2>/dev/null) || code=000
      ;;
  esac
  rm -f "$auth_file"
  case "$code" in
    2??) cat "$out" ;;
    *)
      echo "fm-youtrack: $method $path -> HTTP ${code:-000}" >&2
      cat "$out" >&2
      rc=1
      ;;
  esac
  rm -f "$out"
  return "$rc"
}

cmd_get() {
  [ "$#" -eq 1 ] && [ -n "$1" ] || { usage >&2; exit 2; }
  require_configured
  yt_request GET "$1"
}

cmd_post() {
  [ "$#" -eq 2 ] && [ -n "$1" ] || { usage >&2; exit 2; }
  require_configured
  command -v jq >/dev/null 2>&1 || { echo "fm-youtrack: jq not found" >&2; exit 1; }
  jq -e . >/dev/null 2>&1 <<<"$2" || {
    echo "fm-youtrack: post body is not valid JSON" >&2
    exit 2
  }
  yt_request POST "$1" "$2"
}

yt_resolve_query() {
  local name=$1 saved match
  saved=$(yt_request GET "/api/savedQueries?fields=name,query&\$top=500" 2>/dev/null) || saved=
  if [ -n "$saved" ]; then
    match=$(printf '%s' "$saved" | jq -r --arg n "$name" \
      '(.[] | select(.name == $n) | .query) // empty' 2>/dev/null | head -1)
    [ -z "$match" ] || { printf '%s' "$match"; return 0; }
  fi
  printf '%s' "$name"
}

yt_print_query_issues() {
  local raw=$1 query encoded resp
  query=$(yt_resolve_query "$raw")
  encoded=$(jq -rn --arg s "$query" '$s|@uri')
  resp=$(yt_request GET "/api/issues?query=${encoded}&fields=idReadable,summary,customFields(name,value(name))&\$top=200") \
    || { echo "fm-youtrack: query failed: $raw" >&2; return 1; }
  printf '%s' "$resp" | jq -r '
    .[] |
    ( (.customFields[]? | select(.name=="Type")  | .value.name) // "-" ) as $type |
    ( (.customFields[]? | select(.name=="State") | .value.name) // "-" ) as $state |
    ( (.customFields[]? | select(.name=="Team")  | .value.name) // "-" ) as $team |
    [ .idReadable, $type, $state, $team, .summary ] | @tsv
  '
}

cmd_queries() {
  require_configured
  command -v jq >/dev/null 2>&1 || { echo "fm-youtrack: jq not found" >&2; exit 1; }
  if [ ! -f "$QUERIES_FILE" ] || [ -L "$QUERIES_FILE" ]; then
    echo "fm-youtrack: no queries configured (config/youtrack-queries)" >&2
    exit 1
  fi
  local line trimmed any=0 failed=0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    trimmed=$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [ -n "$trimmed" ] || continue
    any=$((any + 1))
    yt_print_query_issues "$trimmed" || failed=$((failed + 1))
  done < "$QUERIES_FILE"
  if [ "$any" -eq 0 ]; then
    echo "fm-youtrack: config/youtrack-queries has no usable entries" >&2
    exit 1
  fi
  if [ "$failed" -eq "$any" ]; then
    echo "fm-youtrack: every configured query failed to read from the tracker" >&2
    exit 1
  fi
}

CMD=${1:-}
[ "$#" -eq 0 ] || shift
case "$CMD" in
  get) cmd_get "$@" ;;
  post) cmd_post "$@" ;;
  queries) cmd_queries "$@" ;;
  -h|--help) usage ;;
  '') usage >&2; exit 2 ;;
  *) echo "fm-youtrack: unknown command: $CMD" >&2; usage >&2; exit 2 ;;
esac
