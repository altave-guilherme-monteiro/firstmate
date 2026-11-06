# 0001 - Decisions and Work panels, version 2

Status: accepted by the user on 2026-11-05.
Sources: the user-approved reports `decisions-panel-ux` (version 1) and `decisions-work-v2` (version 2) in the Orchestrator `data/` folder.

## Decision

The held backlog task is the only record of a decision for the user.
The Herdr Decisions panel reads only that record, through `bin/fm-captain-hold.sh list --json --all-homes`.
The Herdr Work panel reads `bin/fm-fleet-snapshot.sh --json` and the scheduled-workflow collector.
A triage step sorts each question into a quadrant.
The Orchestrator decides or applies each question that is cheap to undo and not in a never-auto class.
Only real user calls wait for the user.

## Backend contract

| Mechanism | Owner | Behavior |
|---|---|---|
| Typed hold spec | `hold --spec <file>` | The spec is a JSON file with kind, questions, options, one recommendation per question, links, and triage fields. The script stores it as one `Hold spec (fm-hold-v2):` line in the task body. A topic list or a missing recommendation for a quadrant 3 or 4 question is refused. |
| Adopt | `adopt <status-file> <key>` | Turns an open `needs-decision` status line into a held task. It closes the key with `captain-held [key=...]`. A line with no parsable question stays unfiled. |
| Read API | `list --json [--all-homes] [--decided-since <time>]` | Prints typed decisions with the computed quadrant, the due time, and drift rows. The panel renders this JSON only. |
| Panel text | `context`, `details` per question | `context` is one line that the panel shows under the options. `details` holds `text` (paragraphs), `table` (rows, the first row is the header), and `links` (label and URL pairs). The panel shows `details` in a section that opens on request. `list --json` returns both. |
| Triage fields | `class`, `undo_cost`, `blocks`, `deadline` per question | The script computes `quadrant` and `ttl_at`. Only an Orchestrator override with a reason changes the quadrant. |
| TTL | `due [--json]` and the watcher check `decision-ttl` | Prints each question whose `ttl_at` has passed. The watcher raises `check: decision-ttl <home> <task>`. |
| Auto decision | `decide <task> <question> --auto` | Records the recommendation with mode `auto`, a veto time, and the rule. It refuses a never-auto class. It closes the task when no question stays open. |
| Veto | `veto <task> <question>` | Inside the veto window it re-holds the question as quadrant 2 in a new task, and it relays the reversal to the origin worker. |
| Drift rows | `list --json` and `diverged` | Adds "answered by events" and "stale summary" to the version 1 rows. |
| Stopped work | `fm-fleet-snapshot.sh` | A task that is in flight with no endpoint gets `current_state` `stopped` and an elapsed time from `spawn_gen`. |
| Queue hygiene | `answer --release` | A released task of kind `captain` closes and leaves Queued. |
| Dependencies | `hold --blocks <task>` | Records `depends_on` on the task that the call blocks. |

## Triage rules

Quadrant is per question, not per held task.

| Axis | Rule |
|---|---|
| Important | True when the class is a never-auto class, or `undo_cost` is `days` or `irreversible`, or the question has no recommendation. |
| Urgent | True when `blocks` names work that could start now, or `deadline` is less than 48 hours away. |
| Wait-cost test | `undo_cost` of `minutes` or `hours` with class `none` is not important. The user must not wait longer for a choice than the work takes. |

| Quadrant | Important | Urgent | Group in the panel | Action and time limit |
|---|---|---|---|---|
| 1 | yes | yes | Now | User decides. Re-remind every 4 hours. |
| 2 | yes | no | This week | User decides. Re-check after 3 days. |
| 3 | no | yes | Applied - you can veto | The Orchestrator applies the recommendation at once. Veto window 24 hours. |
| 4 | no | no | Decided for you | The Orchestrator decides. The decision appears in the digest. |

## Never-auto classes

The Orchestrator never applies a question in these classes: merge, delete or irreversible change, credential, outward-facing action, and money.
These questions are always important, so they can not reach quadrant 3 or 4.
`decide --auto` refuses them.

## Panel layouts

Decisions panel: groups Now, This week, Applied (you can veto), and Decided for you.
Each user call shows the question, its options with the recommendation first, the context line, an Accept button, an optional Details section, and the age.
The panel renders the approved preview `data/decisions-panel-v2/preview.html` exactly: same fonts, sizes, colors, and animations.
Quadrant 1 items raise a Herdr toast and a `notify-send` message at hold time and every 4 hours.

Work panel: one panel with these groups in order.

1. Orchestrator now: the main pane title and status.
2. Running now: every worker in all homes, with the task it works on.
3. Stopped: tasks in flight with no endpoint.
4. Finished in 7 days: each with its report or PR link.
5. Can start: queued tasks with no open dependency.
6. Scheduled: each workflow with its newest output file and time.

## Consequences

- A lead raises a user call only through `hold`, so the panel has no second source.
- The decision inventory stays correct when a lead summary is stale, because the panel reads held tasks live.
- A user veto costs one new task, because a closed task can not reopen.
- Version 2 does not use any external task service.
