#!/usr/bin/env python3
"""Isolated subprocess protocol checks. No provider API, no real approvals."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import threading

ctl = Path(sys.argv[1]).resolve(strict=True)
checks = 0
heartbeat_roots = set()
heartbeat_lock = threading.Lock()

def heartbeat(root):
    directory = root / "pending-approvals"
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    temporary = directory / "fixture-heartbeat-tmp"
    temporary.write_text(json.dumps({"processID": os.getpid(), "updatedAt": time.time() - 978307200, "canPresent": True}))
    temporary.chmod(0o600)
    temporary.replace(directory / "hud.heartbeat")

def maintain_heartbeats():
    while True:
        with heartbeat_lock:
            for root in list(heartbeat_roots):
                if root.exists():
                    heartbeat(root)
        time.sleep(0.5)

threading.Thread(target=maintain_heartbeats, daemon=True).start()

def check(label, condition):
    global checks
    assert condition, label
    checks += 1
    print("PASS:", label)

def payload(provider="codex", session="session", event="PermissionRequest", arguments=None):
    return {"hook_event_name": event, "session_id": session, "turn_id": "turn",
            "cwd": "/tmp/release-fixture", "tool_name": "Bash", "tool_input": arguments or {"command": "printf harmless-fixture"}}

def start(root, data, provider="codex", relay=True, hud=True):
    if hud:
        with heartbeat_lock:
            heartbeat(root)
            heartbeat_roots.add(root)
    args = [str(ctl), "hook", "--provider", provider, "--data-dir", str(root)]
    if relay:
        args += ["--approval-relay"]
    process = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    process.stdin.write(json.dumps(data).encode())
    process.stdin.close()
    process.stdin = None
    return process

def pending(root):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        paths = list((root / "pending-approvals").glob("*.json"))
        if paths:
            try:
                return paths[0], json.loads(paths[0].read_text())
            except json.JSONDecodeError:
                pass
        time.sleep(0.02)
    raise AssertionError("request not published")

with tempfile.TemporaryDirectory(prefix="island-approval-") as temporary:
    base = Path(temporary)
    for provider in ["codex", "claude", "work-buddy"]:
        for decision in ["allow", "deny"]:
            root = base / (provider + decision)
            proc = start(root, payload(), provider=provider)
            try:
                file, request = pending(root)
                check("pending request private", file.stat().st_mode & 0o777 == 0o600)
                check("pending directory private", file.parent.stat().st_mode & 0o777 == 0o700)
                other = start(root, payload(session="other", event="UserPromptSubmit"), provider=provider)
                out, _ = other.communicate(timeout=5)
                check("approval wait does not lock another session", other.returncode == 0 and out == b"")
                reply = file.with_suffix(".reply")
                reply.write_text(json.dumps({"id": request["id"], "decision": decision}))
                reply.chmod(0o600)
                out, err = proc.communicate(timeout=5)
                expected = {"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": {"behavior": decision}}}
                check(provider + " returns exactly one " + decision, json.loads(out) == expected and not err)
                check("one-shot files removed", not file.exists() and not reply.exists())
                journal = (root / "events.jsonl").read_text()
                check("tool input excluded from durable journal", "harmless-fixture" not in journal and "approvalRequestID" in journal)
            finally:
                if proc.poll() is None:
                    proc.kill()
                    proc.communicate()

    for label, data, provider, enabled in [
        ("observer default", payload(), "codex", False),
        ("notification not approval", payload(event="Notification"), "codex", True),
        ("Doubao not integrated", payload(), "doubao", True),
        ("sensitive input fallback", payload(arguments={"command": "echo $API_TOKEN"}), "codex", True),
        ("oversized input fallback", payload(arguments={"command": "x" * 9000}), "codex", True),
    ]:
        root = base / label.replace(" ", "-")
        proc = start(root, data, provider, enabled)
        out, err = proc.communicate(timeout=5)
        check(label + " emits no approval decision", proc.returncode == 0 and out == b"" and err == b"")
        check(label + " retains no request context", not list((root / "pending-approvals").glob("*.json")))

    root = base / "timeout"
    proc = start(root, payload())
    file, request = pending(root)
    # A stale reply belonging to another request must not satisfy this one.
    file.with_suffix(".reply").write_text(json.dumps({"id": "00000000-0000-0000-0000-000000000000", "decision": "allow"}))
    file.with_suffix(".reply").chmod(0o600)
    out, err = proc.communicate(timeout=50)
    check("wrong request id never approves; timeout returns normal flow", proc.returncode == 0 and out == b"" and err == b"")
    check("timeout clears transient context", not file.exists() and not file.with_suffix(".reply").exists())

    root = base / "no-hud"
    began = time.monotonic()
    proc = start(root, payload(), hud=False)
    out, err = proc.communicate(timeout=3)
    check("HUD absent immediately falls back without an approval decision", time.monotonic() - began < 3 and out == b"" and err == b"")
    check("HUD absent never retains context", not list((root / "pending-approvals").glob("*.json")))

    root = base / "hud-disappears"
    proc = start(root, payload())
    file, request = pending(root)
    with heartbeat_lock:
        heartbeat_roots.discard(root)
        (root / "pending-approvals/hud.heartbeat").unlink()
    out, err = proc.communicate(timeout=3)
    check("HUD exit stops waiting and clears context", out == b"" and err == b"" and not file.exists())

    for mode in ["hidden-island", "auto-pop-disabled", "no-panel"]:
        root = base / mode
        heartbeat(root)
        beat = root / "pending-approvals/hud.heartbeat"
        record = json.loads(beat.read_text())
        record["canPresent"] = False
        beat.write_text(json.dumps(record))
        proc = start(root, payload(), hud=False)
        out, err = proc.communicate(timeout=3)
        check(mode + " immediately retains provider permission UI", out == b"" and err == b"" and not list(beat.parent.glob("*.json")))
print(f"{checks} approval relay process checks passed (fixtures, not provider end-to-end)")
