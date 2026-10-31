#!/usr/bin/env python3
# fm-board-collect.py - gather true fleet state for the captain's board.
#
# Ground truth rule: a ship task's pipeline state is read by running
# `no-mistakes axi status` inside THAT TASK'S OWN WORKTREE. Reading it from the
# firstmate home returns the home's own most-recent run instead, which is what
# makes healthy workers report as failed and dead ones report as healthy.

import concurrent.futures
import csv
import glob
import io
import json
import os
import re
import subprocess
import sys
import time

FM_HOME = os.environ.get("FM_HOME", "/home/altave/firstmate")
BOARD_DIR = os.environ.get("BOARD_DIR", os.path.join(FM_HOME, "data", "fleet-board"))
STATE = os.path.join(FM_HOME, "state")
SECONDMATES = os.path.join(FM_HOME, "data", "secondmates.md")
TRANSCRIPTS = os.path.expanduser("~/.claude/projects")
AXI_TIMEOUT = 25
ACTIVE_GATES = ("awaiting_approval", "fix_review")
TERMINAL = ("failed", "cancelled")


def run(args, cwd=None, timeout=AXI_TIMEOUT):
    try:
        done = subprocess.run(
            args, cwd=cwd, capture_output=True, text=True, timeout=timeout
        )
        return done.stdout
    except (subprocess.TimeoutExpired, OSError):
        return ""


def read_meta(path):
    meta = {}
    try:
        with open(path, errors="ignore") as handle:
            for line in handle:
                if "=" in line and not line.startswith(("endpoint:", "status ")):
                    key, value = line.split("=", 1)
                    meta[key.strip()] = value.strip()
    except OSError:
        pass
    return meta


def toon_scalar(text, key):
    found = re.search(rf"^\s*{re.escape(key)}:\s*(.+?)\s*$", text, re.M)
    return found.group(1).strip().strip('"') if found else ""


def worktree_branch(worktree):
    out = run(
        ["git", "-C", worktree, "rev-parse", "--abbrev-ref", "HEAD"], timeout=8
    ).strip()
    return "" if out in ("", "HEAD") else out


def pipeline_truth(worktree):
    if not worktree or not os.path.isdir(worktree):
        return {"known": False}
    out = run(["no-mistakes", "axi", "status"], cwd=worktree)
    if not out.strip():
        return {"known": False}
    # A pooled worktree keeps the previous task's run, so a run whose branch is
    # not the branch this worktree is actually on belongs to a different task.
    # Reporting it attributes a stranger's failure to fresh work.
    here = worktree_branch(worktree)
    ran = toon_scalar(out, "branch")
    if here and ran and here != ran:
        return {"known": False}
    steps = re.findall(r"^\s{4}([a-z_]+),([a-z_]+),", out, re.M)
    gate = next(((n, s) for n, s in steps if s in ACTIVE_GATES), ("", ""))
    running = next((n for n, s in steps if s == "running"), "")
    log = re.search(r'log:\s*(.+?)"', out)
    return {
        "known": True,
        "branch": toon_scalar(out, "branch"),
        "status": toon_scalar(out, "status"),
        "outcome": toon_scalar(out, "outcome"),
        "pr": toon_scalar(out, "pr"),
        "findings": toon_scalar(out, "findings"),
        "gate": gate[1],
        "gate_step": gate[0],
        "running_step": running,
        "activity": log.group(1).strip()[:180] if log else "",
    }


def capacity_blocked(window):
    if not window:
        return False
    out = run(["tmux", "capture-pane", "-p", "-t", window, "-S", "-12"], timeout=8)
    return "session limit" in out or "usage limit" in out


def live_windows():
    out = run(
        ["tmux", "list-windows", "-a", "-F", "#{session_name}:#{window_name}"],
        timeout=8,
    )
    return set(out.split())


def homes():
    found = [("main", FM_HOME)]
    try:
        text = io.open(SECONDMATES, errors="ignore").read()
    except OSError:
        return found
    for line in text.splitlines():
        entry = re.match(r"^-\s+(\S+)\s+-", line)
        home = re.search(r"\bhome:\s*([^;)]+)", line)
        if entry and home and os.path.isdir(home.group(1).strip()):
            found.append((entry.group(1), home.group(1).strip()))
    return found


def open_decision(task_id, state_dir):
    try:
        with open(os.path.join(state_dir, f"{task_id}.status"), errors="ignore") as handle:
            lines = [line.strip() for line in handle if line.strip()]
    except OSError:
        return ""
    asked = {}
    for line in lines:
        key = re.search(r"\[key=([^\]]+)\]", line)
        name = key.group(1) if key else "default"
        if line.startswith(("needs-decision", "blocked", "captain-held")):
            asked[name] = line[:400]
        elif line.startswith("resolved"):
            asked.pop(name, None)
    return next(iter(asked.values()), "")


def token_spend(worktree):
    if not worktree:
        return 0
    slug = worktree.replace("/", "-").replace(".", "-")
    total = 0
    for jsonl in glob.glob(os.path.join(TRANSCRIPTS, slug, "*.jsonl")):
        try:
            with open(jsonl, errors="ignore") as handle:
                for line in handle:
                    if '"usage"' not in line:
                        continue
                    try:
                        obj = json.loads(line)
                    except ValueError:
                        continue
                    usage = (obj.get("message") or {}).get("usage") or obj.get("usage")
                    if isinstance(usage, dict):
                        total += usage.get("input_tokens") or 0
                        total += usage.get("cache_creation_input_tokens") or 0
                        total += usage.get("output_tokens") or 0
        except OSError:
            continue
    return total


def backlog_rows(home):
    # tasks-axi has no --json on `list`; it prints a TOON table whose header
    # names the columns. Asking for JSON silently yielded nothing, which cost
    # the board every title and every captain-held flag.
    out = run(
        [
            "tasks-axi", "list",
            "--fields", "held,hold_kind,hold_reason",
            "--limit", "1000",
        ],
        cwd=home,
        timeout=40,
    )
    header = re.search(r"^tasks\[\d+\]\{([^}]+)\}:", out, re.M)
    if not header:
        return {}
    fields = [f.strip() for f in header.group(1).split(",")]
    body = out[header.end():]
    rows = {}
    for line in body.splitlines():
        if not line.startswith("  ") or line.startswith("   "):
            continue
        try:
            cells = next(csv.reader([line.strip()], skipinitialspace=True))
        except (csv.Error, StopIteration):
            continue
        if len(cells) != len(fields):
            continue
        row = {k: ("" if v == "-" else v) for k, v in zip(fields, cells)}
        if row.get("id"):
            rows[row["id"]] = row
    return rows


def classify(task):
    pipeline = task["pipeline"]
    if task["capacity_blocked"]:
        return "out of capacity"
    if pipeline.get("outcome") in TERMINAL or pipeline.get("status") in TERMINAL:
        return "failed"
    running = pipeline.get("status") == "running" and not pipeline.get("gate")
    if task["held"]:
        return "waiting on you"
    if task["decision"] and not running:
        return "waiting on you"
    if not pipeline.get("known"):
        return "running" if task["alive"] else "stopped"
    if pipeline.get("gate"):
        return "stalled at gate"
    if running:
        return "working"
    if pipeline.get("outcome") in ("passed", "checks-passed"):
        return "done"
    return "running" if task["alive"] else "stopped"


def build_task(meta_path, backlog, windows, home_label, state_dir):
    task_id = os.path.basename(meta_path)[:-5]
    meta = read_meta(meta_path)
    worktree = meta.get("worktree", "")
    row = backlog.get(task_id, {})
    pipeline = (
        pipeline_truth(worktree) if meta.get("kind") == "ship" else {"known": False}
    )
    task = {
        "id": task_id,
        "home": home_label,
        "title": (row.get("title") or task_id)[:140],
        "repo": meta.get("project", "").rsplit("/", 1)[-1] or row.get("repo", ""),
        "kind": meta.get("kind", ""),
        "mode": meta.get("mode", ""),
        "yolo": meta.get("yolo", ""),
        "issue": meta.get("issue", ""),
        "model": meta.get("model", ""),
        "effort": meta.get("effort", ""),
        "alive": meta.get("window", "") in windows,
        "capacity_blocked": capacity_blocked(meta.get("window", ""))
        if meta.get("window", "") in windows
        else False,
        "pipeline": pipeline,
        "decision": open_decision(task_id, state_dir),
        "held": row.get("held") in (True, "yes"),
        "hold_reason": (row.get("hold_reason") or "")[:400],
        "pr": pipeline.get("pr") or meta.get("pr", ""),
        "tokens": token_spend(worktree),
    }
    task["state"] = classify(task)
    return task


def quota():
    out = run(["quota-axi"], timeout=20)
    row = re.search(r"^\s*claude,all_models,(\d+),.*?(\d{4}-\d{2}-\d{2}T\d{2}:\d{2})", out, re.M)
    return {
        "percent": row.group(1) if row else "",
        "resets": row.group(2) if row else "",
    }


ORDER = {
    "waiting on you": 0,
    "out of capacity": 1,
    "failed": 1,
    "stalled at gate": 2,
    "working": 3,
    "running": 4,
    "done": 5,
    "stopped": 6,
}


def main():
    windows = live_windows()
    jobs = []
    for label, home in homes():
        backlog = backlog_rows(home)
        state_dir = os.path.join(home, "state")
        for meta in sorted(glob.glob(os.path.join(state_dir, "*.meta"))):
            jobs.append((meta, backlog, label, state_dir))
    with concurrent.futures.ThreadPoolExecutor(max_workers=12) as pool:
        tasks = list(
            pool.map(
                lambda j: build_task(j[0], j[1], windows, j[2], j[3]),
                jobs,
            )
        )
    tasks.sort(key=lambda t: (ORDER.get(t["state"], 9), -t["tokens"]))
    counts = {}
    for task in tasks:
        counts[task["state"]] = counts.get(task["state"], 0) + 1
    payload = {
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "counts": counts,
        "total": len(tasks),
        "alive": sum(1 for task in tasks if task["alive"]),
        "quota": quota(),
        "tasks": tasks,
    }
    os.makedirs(BOARD_DIR, exist_ok=True)
    target = os.path.join(BOARD_DIR, "fleet.json")
    with open(target + ".tmp", "w") as handle:
        json.dump(payload, handle, indent=1)
    os.replace(target + ".tmp", target)


def serve(port, ttl):
    import functools
    import http.server
    import threading

    last = [0.0]
    lock = threading.Lock()

    class Handler(http.server.SimpleHTTPRequestHandler):
        def do_GET(self):
            if self.path.split("?")[0].endswith("/fleet.json"):
                with lock:
                    if time.time() - last[0] > ttl:
                        main()
                        last[0] = time.time()
            return super().do_GET()

        def log_message(self, *args):
            pass

    main()
    last[0] = time.time()
    handler = functools.partial(Handler, directory=BOARD_DIR)
    print(f"fleet board: http://127.0.0.1:{port}/  collected on request, at most every {ttl}s", flush=True)
    http.server.ThreadingHTTPServer(("127.0.0.1", port), handler).serve_forever()


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--serve":
        serve(int(sys.argv[2]), float(sys.argv[3]))
    else:
        main()
