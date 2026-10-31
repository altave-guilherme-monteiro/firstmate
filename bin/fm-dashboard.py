#!/usr/bin/env python3
# Live fleet dashboard. Renders current state on every request, so a browser
# refresh always shows truth rather than a cached snapshot.
# Usage: fm-dashboard.py [port]   (default 8790)
import html
import os
import re
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

HOME = Path(os.environ.get("FM_HOME", "/home/altave/firstmate"))
STATE = HOME / "state"
REFRESH_SECONDS = 20

DONE_HEADS = {"done", "passed", "checks-passed", "merged"}
BAD_HEADS = {"failed", "cancelled", "blocked", "needs-decision"}


def run(cmd, timeout=15):
    try:
        out = subprocess.run(
            cmd, shell=True, capture_output=True, text=True, timeout=timeout, cwd=HOME
        )
        return out.stdout.strip()
    except Exception:
        return ""


def read_meta(task):
    meta = {}
    path = STATE / f"{task}.meta"
    if not path.exists():
        return meta
    for line in path.read_text(errors="replace").splitlines():
        if "=" in line:
            key, _, value = line.partition("=")
            meta[key.strip()] = value.strip()
    return meta


def status_tail(task, count=40):
    path = STATE / f"{task}.status"
    if not path.exists():
        return []
    return path.read_text(errors="replace").splitlines()[-count:]


def classify(line):
    head = line.split(":", 1)[0].strip().lower()
    if head in BAD_HEADS:
        return "bad"
    if head in DONE_HEADS:
        return "done"
    if head == "paused":
        return "paused"
    return "working"


def live_window_names():
    raw = run("tmux list-windows -t firstmate -F '#W' 2>/dev/null")
    return set(raw.splitlines())


def task_rows():
    windows = live_window_names()
    rows = []
    for meta_path in STATE.glob("*.meta"):
        task = meta_path.stem
        meta = read_meta(task)
        lines = status_tail(task)
        last = lines[-1] if lines else ""
        status_path = STATE / f"{task}.status"
        mtime = status_path.stat().st_mtime if status_path.exists() else 0
        rows.append(
            {
                "task": task,
                "kind": meta.get("kind", ""),
                "repo": (meta.get("project", "") or "").rsplit("/", 1)[-1],
                "mode": meta.get("mode", ""),
                "model": meta.get("model", ""),
                "pr": meta.get("pr", ""),
                "issue": meta.get("issue", ""),
                "last": last,
                "tone": classify(last),
                "mtime": mtime,
                "alive": f"fm-{task}" in windows,
            }
        )
    rows.sort(key=lambda row: row["mtime"], reverse=True)
    return rows


def open_decisions():
    found = []
    for status_path in STATE.glob("*.status"):
        opened, resolved = {}, set()
        for line in status_path.read_text(errors="replace").splitlines():
            match = re.search(r"\[key=([^\]]+)\]", line)
            key = match.group(1) if match else None
            if line.startswith("resolved"):
                resolved.add(key)
            elif line.startswith(("needs-decision", "blocked")):
                opened[key] = line
        for key, line in opened.items():
            if key not in resolved:
                found.append(
                    {"task": status_path.stem, "key": key or "unkeyed", "line": line}
                )
    return found


def captain_held():
    raw = run("tasks-axi list --file data/backlog.md --state held 2>/dev/null")
    rows = []
    for line in raw.splitlines():
        stripped = line.strip()
        if stripped.count(",") >= 3 and not stripped.startswith(
            ("count:", "tasks[", "help[")
        ):
            rows.append(stripped)
    return rows


def recent_landed():
    raw = run("tasks-axi list --file data/backlog.md --state done 2>/dev/null")
    return [line.strip() for line in raw.splitlines() if ",done," in line][:12]


def bridge_code():
    return (
        run(
            "curl -s -o /dev/null -w '%{http_code}' --max-time 4 http://127.0.0.1:18081/"
        )
        or "000"
    )


def esc(text):
    return html.escape(text or "")


def clip(text, limit):
    text = text or ""
    return text if len(text) <= limit else text[: limit - 1] + "…"


def first_field(line):
    return line.split(",")[0].strip() if "," in line else line[:70]


PAGE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="refresh" content="{refresh}">
<title>Fleet</title>
<style>
:root{{--bg:#0d1117;--panel:#161b22;--line:#272e38;--ink:#e6edf3;--dim:#8b949e;
--ok:#3fb950;--bad:#f85149;--info:#58a6ff;--pause:#a371f7}}
*{{box-sizing:border-box}}
body{{margin:0;background:var(--bg);color:var(--ink);padding:16px;
font:14px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace}}
h1{{font-size:15px;margin:0;letter-spacing:.08em;text-transform:uppercase;color:var(--dim)}}
h2{{font-size:13px;margin:22px 0 8px;letter-spacing:.08em;text-transform:uppercase;
color:var(--dim);border-bottom:1px solid var(--line);padding-bottom:5px}}
header{{display:flex;justify-content:space-between;align-items:baseline;gap:12px;
flex-wrap:wrap;border-bottom:1px solid var(--line);padding-bottom:10px}}
.meta{{color:var(--dim);font-size:12px}}
.card{{background:var(--panel);border:1px solid var(--line);border-left:3px solid var(--line);
border-radius:5px;padding:9px 11px;margin-bottom:7px}}
.card.working{{border-left-color:var(--info)}}
.card.done{{border-left-color:var(--ok)}}
.card.bad{{border-left-color:var(--bad)}}
.card.paused{{border-left-color:var(--pause)}}
.row1{{display:flex;gap:9px;align-items:baseline;flex-wrap:wrap}}
.name{{font-weight:600}}
.tag{{font-size:11px;color:var(--dim);border:1px solid var(--line);border-radius:3px;padding:0 5px}}
.dot{{width:7px;height:7px;border-radius:50%;display:inline-block}}
.dot.on{{background:var(--ok)}}
.dot.off{{background:var(--bad)}}
.last{{color:var(--dim);font-size:12.5px;margin-top:4px;word-break:break-word}}
a{{color:var(--info)}}
.empty{{color:var(--dim);font-style:italic}}
.grid{{display:grid;grid-template-columns:repeat(auto-fit,minmax(330px,1fr));gap:14px;
align-items:start}}
.pill{{font-size:11px;padding:1px 7px;border-radius:9px;background:#21262d;color:var(--dim)}}
.pill.bad{{background:#3d1517;color:#ff9c96}}
.pill.ok{{background:#12321b;color:#6fdd8b}}
</style></head><body>
<header><h1>Fleet</h1><div class="meta">{clock} &middot; refreshes every {refresh}s
&middot; bridge <span class="pill {bridge_class}">{bridge}</span></div></header>
{body}
</body></html>"""


def section_needs_you(held):
    out = ["<h2>Needs you</h2>"]
    if not held:
        out.append('<p class="empty">Nothing is waiting on you.</p>')
        return out
    for line in held:
        out.append(
            f'<div class="card bad"><div class="row1">'
            f'<span class="name">{esc(clip(first_field(line), 70))}</span></div>'
            f'<div class="last">{esc(clip(line, 320))}</div></div>'
        )
    return out


def section_agents(active):
    out = [f"<h2>Agents &mdash; {len(active)} running</h2>"]
    if not active:
        out.append('<p class="empty">No agents running.</p>')
        return out
    for row in active:
        pr = f' <a href="{esc(row["pr"])}">PR</a>' if row["pr"] else ""
        tags = " ".join(
            f'<span class="tag">{esc(v)}</span>'
            for v in (row["kind"], row["repo"], row["mode"], row["model"], row["issue"])
            if v
        )
        out.append(
            f'<div class="card {row["tone"]}"><div class="row1">'
            f'<span class="dot on"></span><span class="name">{esc(row["task"])}</span>'
            f"{tags}{pr}</div>"
            f'<div class="last">{esc(clip(row["last"], 420))}</div></div>'
        )
    return out


def section_questions(decisions):
    out = [f"<div><h2>Open questions &mdash; {len(decisions)}</h2>"]
    if not decisions:
        out.append('<p class="empty">None open.</p>')
    for item in decisions:
        out.append(
            f'<div class="card bad"><div class="row1">'
            f'<span class="name">{esc(item["task"])}</span>'
            f'<span class="tag">{esc(item["key"])}</span></div>'
            f'<div class="last">{esc(clip(item["line"], 320))}</div></div>'
        )
    out.append("</div>")
    return out


def section_landed(landed):
    out = ["<div><h2>Recently landed</h2>"]
    if not landed:
        out.append('<p class="empty">Nothing in the recent window.</p>')
    for line in landed:
        out.append(
            f'<div class="card done"><div class="last">{esc(clip(line, 230))}</div></div>'
        )
    out.append("</div>")
    return out


def section_idle(idle):
    if not idle:
        return []
    out = [f"<h2>Recorded, not running &mdash; {len(idle)}</h2>"]
    for row in idle:
        out.append(
            f'<div class="card {row["tone"]}"><div class="row1">'
            f'<span class="dot off"></span><span class="name">{esc(row["task"])}</span>'
            f'<span class="tag">{esc(row["kind"])}</span></div>'
            f'<div class="last">{esc(clip(row["last"], 230))}</div></div>'
        )
    return out


def render():
    rows = task_rows()
    active = [row for row in rows if row["alive"]]
    idle = [row for row in rows if not row["alive"]]
    code = bridge_code()

    body = section_needs_you(captain_held())
    body += section_agents(active)
    body += ['<div class="grid">']
    body += section_questions(open_decisions())
    body += section_landed(recent_landed())
    body += ["</div>"]
    body += section_idle(idle)

    return PAGE.format(
        refresh=REFRESH_SECONDS,
        clock=time.strftime("%H:%M:%S"),
        bridge=("up" if code == "200" else f"down {code}"),
        bridge_class=("ok" if code == "200" else "bad"),
        body="\n".join(body),
    )


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        body = render().encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    HTTPServer(
        ("127.0.0.1", int(sys.argv[1]) if len(sys.argv) > 1 else 8790), Handler
    ).serve_forever()
