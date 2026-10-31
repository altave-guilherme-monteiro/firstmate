#!/usr/bin/env bash
# fm-board.sh - live fleet dashboard for the captain.
#
# Writes data/fleet-board/fleet.json from GROUND TRUTH and serves a static page
# that polls it. Ground truth means each ship task's pipeline state is read by
# running `no-mistakes axi status` INSIDE that task's own worktree, never from
# the firstmate home: the home's own most-recent run is not the crew's run, and
# reading it there is what makes healthy workers report as failed.
#
# Usage:
#   fm-board.sh            write fleet.json once, print its path
#   fm-board.sh --serve    regenerate every refresh interval and serve the page
#   fm-board.sh --url      print the board URL
#
# Env: FM_BOARD_PORT (default 8787), FM_BOARD_REFRESH seconds (default 20)

set -uo pipefail

FM_HOME=${FM_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
BOARD_DIR="$FM_HOME/data/fleet-board"
PORT=${FM_BOARD_PORT:-8787}
REFRESH=${FM_BOARD_REFRESH:-20}

mkdir -p "$BOARD_DIR"

collect() {
  FM_HOME="$FM_HOME" BOARD_DIR="$BOARD_DIR" python3 "$FM_HOME/bin/fm-board-collect.py"
}

case "${1:-}" in
  --url)
    printf 'http://127.0.0.1:%s/\n' "$PORT"
    ;;
  --serve)
    # One process, no background refresh loop: the server collects when the page
    # asks for fleet.json. A detached loop died silently once and left the board
    # serving stale numbers, which is worse than serving none.
    exec env FM_HOME="$FM_HOME" BOARD_DIR="$BOARD_DIR" \
      python3 "$FM_HOME/bin/fm-board-collect.py" --serve "$PORT" "$REFRESH"
    ;;
  *)
    collect
    printf '%s/fleet.json\n' "$BOARD_DIR"
    ;;
esac
