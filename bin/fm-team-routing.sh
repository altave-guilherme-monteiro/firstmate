#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
MAP_FILE="$CONFIG/team-routing"

usage() {
  cat <<'USAGE'
fm-team-routing.sh - resolve the tracker team an issue firstmate creates
should be filed against.

The captain set the category-to-team mapping himself; this script only
looks it up and refuses to hand back a team name the live tracker does not
actually have, since firstmate must never invent an enum value.

Usage:
  fm-team-routing.sh resolve <category>
      Print "team=<Team enum value>" on stdout. When <category> has no
      mapped entry, print the configured fallback team AND
      "assignee=<login>" on a second line, per the captain's ruling: when
      nothing fits, fall back to the AI team and assign the issue to him.
      The resolved team is validated against the live enum values of the
      configured project's Team custom field before being printed; an
      unresolvable or stale mapping refuses loudly rather than guessing.
  fm-team-routing.sh -h|--help

Config, LOCAL and gitignored under the effective firstmate home
(FM_HOME, config/team-routing). Absent means routing is not configured for
this home: the command exits 1 with one line on stderr and makes no
network call - callers treat that as "skip routing", not an error to
surface. One "key=value" pair per line, blank lines and a leading-hash-mark
line ignored:
  project=<tracker project short name>   e.g. project=DEV
  <category>=<Team enum value>           one line per known category, e.g.
                                            frontend=Team Digital
                                            backend=Team Digital
                                            infrastructure=Team DevX
                                            inference=Team AI
                                            computer-vision=Team AI
                                            ai=Team AI
  fallback=<Team enum value>             required
  fallback_assignee=<tracker login>      required

Delegates every tracker read to bin/fm-youtrack.sh, which owns
authentication; this script performs no auth of its own.
USAGE
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

if [ "$#" -ne 2 ] || [ "$1" != "resolve" ] || [ -z "$2" ]; then
  usage >&2
  exit 2
fi
CATEGORY=$2

if [ ! -f "$MAP_FILE" ] || [ -L "$MAP_FILE" ]; then
  echo "fm-team-routing: not configured (no config/team-routing)" >&2
  exit 1
fi

command -v jq >/dev/null 2>&1 || { echo "fm-team-routing: jq not found" >&2; exit 1; }

YT="$SCRIPT_DIR/fm-youtrack.sh"
HASH='#'
PROJECT=""
FALLBACK_TEAM=""
FALLBACK_ASSIGNEE=""
MATCHED_TEAM=""
while IFS='=' read -r key value || [ -n "$key" ]; do
  case "$key" in
    '') continue ;;
    "$HASH"*) continue ;;
  esac
  case "$key" in
    project) PROJECT=$value ;;
    fallback) FALLBACK_TEAM=$value ;;
    fallback_assignee) FALLBACK_ASSIGNEE=$value ;;
  esac
  if [ "$key" = "$CATEGORY" ]; then
    MATCHED_TEAM=$value
  fi
done < "$MAP_FILE"

[ -n "$PROJECT" ] || { echo "fm-team-routing: config/team-routing has no project= line" >&2; exit 1; }
[ -n "$FALLBACK_TEAM" ] && [ -n "$FALLBACK_ASSIGNEE" ] || {
  echo "fm-team-routing: config/team-routing has no fallback=/fallback_assignee= line" >&2
  exit 1
}

RESOLVED_TEAM=$MATCHED_TEAM
IS_FALLBACK=0
if [ -z "$RESOLVED_TEAM" ]; then
  RESOLVED_TEAM=$FALLBACK_TEAM
  IS_FALLBACK=1
fi

PROJECT_ID=$("$YT" get "/api/admin/projects?fields=id,shortName&\$top=300" 2>/dev/null \
  | jq -r --arg sn "$PROJECT" '(.[] | select(.shortName == $sn) | .id) // empty') \
  || { echo "fm-team-routing: could not read the tracker's project list" >&2; exit 1; }
[ -n "$PROJECT_ID" ] || {
  echo "fm-team-routing: project '$PROJECT' (config/team-routing) does not exist on the live tracker" >&2
  exit 1
}

BUNDLE_ID=$("$YT" get "/api/admin/projects/${PROJECT_ID}/customFields?fields=field(name),bundle(id)&\$top=200" 2>/dev/null \
  | jq -r '(.[] | select(.field.name == "Team") | .bundle.id) // empty') \
  || { echo "fm-team-routing: could not read the project's Team field" >&2; exit 1; }
[ -n "$BUNDLE_ID" ] || {
  echo "fm-team-routing: project '$PROJECT' has no Team enum field on the live tracker" >&2
  exit 1
}

VALID_TEAMS=$("$YT" get "/api/admin/customFieldSettings/bundles/enum/${BUNDLE_ID}/values?fields=name&\$top=200" 2>/dev/null \
  | jq -r '.[].name') \
  || { echo "fm-team-routing: could not read the Team field's live enum values" >&2; exit 1; }

if ! grep -qxF "$RESOLVED_TEAM" <<<"$VALID_TEAMS"; then
  echo "fm-team-routing: '$RESOLVED_TEAM' is not a current Team value on the live tracker - refusing to invent it" >&2
  exit 1
fi

echo "team=$RESOLVED_TEAM"
[ "$IS_FALLBACK" -eq 0 ] || echo "assignee=$FALLBACK_ASSIGNEE"
