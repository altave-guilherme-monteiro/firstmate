#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
YT="$SCRIPT_DIR/fm-youtrack.sh"

usage() {
  cat <<'USAGE'
fm-architecture-sync.sh - mirror a repository's architecture/decision docs
onto a tracker issue.

The repository is the single source of truth for architecture (docs/
architecture/) and decision records (docs/decisions/). The tracker card is
a MIRROR, never a second original: this script renders one or more of those
markdown files, plus a link back to the source file at the commit it was
read from, into a single clearly-marked comment on the issue - creating it
on first run, updating that same comment (never appending a new one) on
every later run against the same issue and file set. Sync is one-way,
repository to card; nothing this script does ever writes to the repository.

Usage:
  fm-architecture-sync.sh <issue-id> <file>... [--pr <url>]
  fm-architecture-sync.sh -h|--help

<issue-id>  a tracker issue id, e.g. FM-123.
<file>...   one or more committed markdown files, each at a path matching
            docs/architecture/*.md or docs/decisions/*.md within its own
            git repository. Repeatable; every file lands in the same
            mirror comment, keyed by the exact set of files given.
--pr <url>  the pull request that changed the document(s); included in the
            mirror comment when supplied, omitted otherwise.

Behavior:
  Refuses, with no tracker call, when any given file is missing, is not
  inside a git repository, is not tracked, has uncommitted changes (staged
  or unstaged), or does not live under docs/architecture/ or
  docs/decisions/ - a mirror of unlanded or out-of-contract content is a
  lie. The source link points at the file's current HEAD commit in its
  repository's origin remote (GitHub-style /blob/<sha>/<path> URLs).

  The mirror comment is found by a marker line encoding the exact set of
  (origin remote, path-within-repository) pairs given - never a local
  filesystem path, so the same document synced from a different worktree,
  clone, or machine still resolves to the same marker. Running this script
  twice with the same issue and file set - from any checkout of that
  repository - updates that one comment in place rather than posting a
  second copy. A different file set for the same issue mirrors to its own
  comment.

  Refuses cleanly, with no network call, when the tracker is not
  configured (no config/youtrack-token) - exactly as fm-youtrack.sh does,
  since this script performs no authentication of its own and always
  routes through it.
USAGE
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

[ "$#" -ge 1 ] || { usage >&2; exit 2; }

ISSUE_ID=$1
shift

PR_URL=""
FILES=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --pr)
      [ "$#" -ge 2 ] && [ -n "$2" ] || { echo "fm-architecture-sync: --pr needs a url" >&2; exit 2; }
      PR_URL=$2
      shift 2
      ;;
    -*)
      echo "fm-architecture-sync: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      FILES+=("$1")
      shift
      ;;
  esac
done

[ -n "$ISSUE_ID" ] || { usage >&2; exit 2; }
[ "${#FILES[@]}" -ge 1 ] || { echo "fm-architecture-sync: at least one markdown file is required" >&2; exit 2; }

command -v jq >/dev/null 2>&1 || { echo "fm-architecture-sync: jq not found" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "fm-architecture-sync: git not found" >&2; exit 1; }

to_https_base() {
  local url=$1
  url=${url%.git}
  case "$url" in
    git@*:*)
      local host=${url#git@}
      host=${host%%:*}
      local path=${url#*:}
      printf 'https://%s/%s' "$host" "$path"
      ;;
    ssh://git@*)
      local rest=${url#ssh://git@}
      local host=${rest%%/*}
      local path=${rest#*/}
      printf 'https://%s/%s' "$host" "$path"
      ;;
    *)
      printf '%s' "$url"
      ;;
  esac
}

KEYS=()
SECTIONS=()

for f in "${FILES[@]}"; do
  [ -f "$f" ] || { echo "fm-architecture-sync: file not found: $f" >&2; exit 1; }

  dir=$(cd "$(dirname "$f")" && pwd) || { echo "fm-architecture-sync: cannot resolve directory of $f" >&2; exit 1; }
  abs_file="$dir/$(basename "$f")"

  repo=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || {
    echo "fm-architecture-sync: not inside a git repository: $f" >&2
    exit 1
  }
  relpath=${abs_file#"$repo"/}

  case "$relpath" in
    docs/architecture/*.md|docs/decisions/*.md) ;;
    *)
      echo "fm-architecture-sync: $f is not under docs/architecture/ or docs/decisions/ (resolved to $relpath)" >&2
      exit 1
      ;;
  esac

  git -C "$repo" ls-files --error-unmatch -- "$relpath" >/dev/null 2>&1 || {
    echo "fm-architecture-sync: $relpath is not committed in $repo - refusing to mirror unlanded content" >&2
    exit 1
  }

  dirty=$(git -C "$repo" status --porcelain -- "$relpath")
  [ -z "$dirty" ] || {
    echo "fm-architecture-sync: $relpath has uncommitted changes in $repo - refusing to mirror unlanded content" >&2
    exit 1
  }

  sha=$(git -C "$repo" rev-parse HEAD)
  remote=$(git -C "$repo" config --get remote.origin.url 2>/dev/null) || {
    echo "fm-architecture-sync: $repo has no origin remote - cannot build a source link" >&2
    exit 1
  }
  base=$(to_https_base "$remote")
  blob_url="${base}/blob/${sha}/${relpath}"

  identity=${base#https://}
  identity=${identity#http://}
  KEYS+=("${identity}:${relpath}")

  section="### ${relpath}"$'\n\n'
  section+="Source: [${relpath} @ ${sha:0:7}](${blob_url})"$'\n\n'
  section+="$(cat "$abs_file")"$'\n\n---'
  SECTIONS+=("$section")
done

KEY=$(printf '%s\n' "${KEYS[@]}" | sort | paste -sd, -)
MARKER="<!-- fm-architecture-sync:${KEY} -->"

BODY="${MARKER}"$'\n\n'
BODY+="**Architecture / decision mirror** - synced from the repository; edit the source file, never this comment."$'\n\n'
[ -z "$PR_URL" ] || BODY+="PR: ${PR_URL}"$'\n\n'
for section in "${SECTIONS[@]}"; do
  BODY+="${section}"$'\n\n'
done

COMMENTS_JSON=$("$YT" get "/api/issues/${ISSUE_ID}/comments?fields=id,text") || exit $?
EXISTING_ID=$(printf '%s' "$COMMENTS_JSON" | jq -r --arg m "$MARKER" '[.[] | select(.text | startswith($m))] | .[0].id // empty')

COMMENT_JSON=$(jq -Rs '{text: .}' <<<"$BODY")
if [ -n "$EXISTING_ID" ]; then
  "$YT" post "/api/issues/${ISSUE_ID}/comments/${EXISTING_ID}?fields=id,text" "$COMMENT_JSON"
else
  "$YT" post "/api/issues/${ISSUE_ID}/comments?fields=id,text" "$COMMENT_JSON"
fi
