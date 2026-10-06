#!/usr/bin/env python3
"""Isolated process smoke tests for an already built hook observer; no models."""

import argparse
import base64
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import threading
import time


PROVIDERS = {"codex": "Codex", "claude": "Claude", "work-buddy": "WorkBuddy"}
PRIVATE = "PROCESS_SMOKE_PRIVATE_CONTENT"
ALLOWED = {
    "type", "id", "agent", "title", "status", "detail", "model",
    "requiresApproval", "colorHex", "createdAt", "sourceEvent",
    "sessionID", "turnID", "legacySessionID", "replacesTaskID",
    "toolLabel", "toolStepID",
}


class Smoke:
    def __init__(self, ctl):
        self.ctl = ctl
        self.checks = 0
        self.processes = 0
        self.events = 0
        self.lock = threading.Lock()

    def check(self, name, condition):
        with self.lock:
            self.checks += 1
        if not condition:
            raise AssertionError(name)

    def hook(self, directory, provider, event, session, turn=None):
        payload = {
            "hook_event_name": event, "session_id": session,
            "prompt": PRIVATE, "transcript_path": "/private/" + PRIVATE,
            "tool_input": {"command": PRIVATE}, "tool_response": PRIVATE,
            "message": PRIVATE, "environment": {"TOKEN": PRIVATE},
        }
        if turn is not None:
            payload["turn_id"] = turn
        with self.lock:
            self.processes += 1
        result = subprocess.run(
            [str(self.ctl), "hook", "--provider", provider, "--data-dir", str(directory)],
            input=json.dumps(payload).encode(), capture_output=True, timeout=15,
        )
        self.check("observer process succeeds silently", result.returncode == 0 and not result.stdout and not result.stderr)

    def records(self, directory):
        raw = (directory / "events.jsonl").read_bytes()
        self.check("event stream ends at a complete line", not raw or raw.endswith(b"\n"))
        rows = [json.loads(line) for line in raw.splitlines()]
        self.check("no blank or damaged records", len(rows) == raw.count(b"\n"))
        self.check("events contain only metadata fields", all(set(row) <= ALLOWED for row in rows))
        self.check("no fabricated progress", all("progress" not in row for row in rows))
        self.check("all sessions are hashed", all(re.fullmatch(r"s_[0-9a-f]{64}", row["sessionID"]) for row in rows))
        self.check("all present rounds are hashed", all(re.fullmatch(r"[tl]_[0-9a-f]{64}", row["turnID"]) for row in rows if "turnID" in row))
        sidecar = (directory / "hook-turns.json").read_bytes()
        self.check("raw ids and conversation content never persist", all(
            marker not in raw + sidecar for marker in [PRIVATE.encode(), b"raw-session-", b"raw-turn-", b"transcript_path", b"tool_input"]
        ))
        state = json.loads(sidecar)
        self.check("journal is committed without a pending batch", state.get("version") == 2 and state.get("pending") is None)
        self.check("sidecar permissions restrict access", (directory / "hook-turns.json").stat().st_mode & 0o077 == 0)
        return rows

    def serial(self, directory):
        names = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse", "Stop",
                 "UserPromptSubmit", "PostToolUseFailure", "StopFailure", "SessionEnd"]
        for provider in PROVIDERS:
            for name in names:
                self.hook(directory, provider, name, "raw-session-shared-serial")
        rows = self.records(directory)
        self.check("three providers produce ten serial callbacks each", len(rows) == 30)
        task_ids = set()
        for label in PROVIDERS.values():
            events = [row for row in rows if row["agent"] == label]
            self.check(label + " lifecycle order", [row["sourceEvent"] for row in events] == names)
            first, second = events[1]["id"], events[6]["id"]
            task_ids.update([first, second])
            self.check(label + " first turn persists across processes", all(row["id"] == first for row in events[1:6]))
            self.check(label + " next prompt starts a new independent turn", first != second and all(row["id"] == second for row in events[6:9]))
            self.check(label + " approval and terminal states", events[3]["status"] == "waiting" and events[3]["requiresApproval"] is True
                       and events[5]["status"] == "completed" and events[8]["status"] == "failed" and events[9]["type"] == "end-session")
        self.check("same upstream session across providers cannot collide", len(task_ids) == 6)
        self.events += len(rows)

    def native(self, directory):
        callbacks = [("UserPromptSubmit", "raw-turn-a"), ("UserPromptSubmit", "raw-turn-b"),
                     ("PreToolUse", "raw-turn-a"), ("Stop", "raw-turn-a"),
                     ("PreToolUse", "raw-turn-a"), ("UserPromptSubmit", "raw-turn-a"),
                     ("PermissionRequest", "raw-turn-b"), ("Stop", None),
                     ("StopFailure", "raw-turn-b"), ("SessionEnd", None)]
        for provider in PROVIDERS:
            for event, turn in callbacks:
                self.hook(directory, provider, event, "raw-session-native", turn)
        rows = self.records(directory)
        self.check("native late duplicate events are suppressed", len(rows) == 24)
        for label in PROVIDERS.values():
            events = [row for row in rows if row["agent"] == label]
            self.check(label + " native two rounds retain independent ids", events[0]["id"] == events[2]["id"] == events[3]["id"]
                       and events[1]["id"] == events[4]["id"] == events[6]["id"] and events[0]["id"] != events[1]["id"])
            self.check(label + " untagged stop cannot close overlapping peer", events[5]["type"] == "ambiguous-turn"
                       and "status" not in events[5] and "id" not in events[5])
        self.events += len(rows)

    def concurrent(self, directory):
        gate = threading.Barrier(18)
        jobs = [(provider, number) for provider in PROVIDERS for number in range(12)]

        def run(job):
            provider, number = job
            gate.wait(timeout=15)
            for _ in range(2):
                for name in ["UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop"]:
                    self.hook(directory, provider, name, "raw-session-concurrent-" + str(number))

        with ThreadPoolExecutor(max_workers=18) as pool:
            list(pool.map(run, jobs))
        rows = self.records(directory)
        self.check("parallel shared log loses no callback", len(rows) == 288)
        self.check("parallel providers each have 96 callbacks", Counter(row["agent"] for row in rows) == Counter({p: 96 for p in PROVIDERS.values()}))
        sessions = defaultdict(list)
        for row in rows:
            sessions[row["sessionID"]].append(row)
        self.check("parallel sessions remain separate", len(sessions) == 36)
        all_turns = set()
        for events in sessions.values():
            self.check("parallel session preserves causal order", [row["sourceEvent"] for row in events] == ["UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop"] * 2)
            ids = [row["id"] for row in events]
            self.check("parallel turns never use another session mapping", len(set(ids[:4])) == 1 and len(set(ids[4:])) == 1 and ids[0] != ids[4])
            all_turns.update(ids)
        self.check("parallel run has exactly 72 distinct rounds", len(all_turns) == 72)
        self.events += len(rows)

    def journal_recovery(self, directory, cut):
        session = "raw-session-journal"
        self.hook(directory, "codex", "UserPromptSubmit", session)
        prefix = (directory / "events.jsonl").read_bytes()
        self.hook(directory, "codex", "Stop", session)
        stop_bytes = (directory / "events.jsonl").read_bytes()[len(prefix):]
        state = json.loads((directory / "hook-turns.json").read_bytes())
        state["pending"] = {"offset": len(prefix), "data": base64.b64encode(stop_bytes).decode()}
        fraction = {"none": 0, "partial": len(stop_bytes) // 2, "complete": len(stop_bytes)}[cut]
        # Deterministic crash-cut fixture from real CLI output. No timing race,
        # process killing, or personal sidecar/log is involved.
        (directory / "hook-turns.json").write_text(json.dumps(state))
        (directory / "events.jsonl").write_bytes(prefix + stop_bytes[:fraction])
        self.hook(directory, "codex", "SessionStart", session)
        rows = self.records(directory)
        self.check("journal " + cut + " recovers exactly one stop before next callback", len(rows) == 3
                   and [row["sourceEvent"] for row in rows] == ["UserPromptSubmit", "Stop", "SessionStart"])
        self.check("journal " + cut + " preserves committed event bytes", (directory / "events.jsonl").read_bytes().startswith(prefix + stop_bytes))
        self.events += len(rows)

    def run(self, root):
        self.serial(root / "serial")
        self.native(root / "native")
        self.concurrent(root / "parallel")
        for cut in ["none", "partial", "complete"]:
            self.journal_recovery(root / ("journal-" + cut), cut)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ctl", type=Path, default=Path(__file__).resolve().parents[1] / ".build/out/Products/Debug/linglongtaictl")
    parser.add_argument("--repeat", type=int, default=1)
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    if args.repeat < 1 or not args.ctl.is_file():
        parser.error("provide an existing CLI and a positive repeat count")
    smoke = Smoke(args.ctl.resolve())
    root = Path(tempfile.mkdtemp(prefix="linglongtai-hook-smoke-"))
    started = time.monotonic()
    report = {"binary": str(args.ctl.resolve()), "binarySHA256": hashlib.sha256(args.ctl.read_bytes()).hexdigest()}
    try:
        for index in range(args.repeat):
            smoke.run(root / str(index))
            print("PASS iteration " + str(index + 1), flush=True)
        report.update(status="PASS", repetitions=args.repeat, checks=smoke.checks,
                      cliProcesses=smoke.processes, validEventRecords=smoke.events,
                      parallelSessions=36 * args.repeat, parallelTurns=72 * args.repeat,
                      journalCrashCutCases=3 * args.repeat,
                      elapsedSeconds=round(time.monotonic() - started, 3))
        shutil.rmtree(root)
    except Exception as error:
        report.update(status="FAIL", error=str(error), artifacts=str(root), checks=smoke.checks, cliProcesses=smoke.processes)
    if args.report:
        args.report.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    return 0 if report["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
