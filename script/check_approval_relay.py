#!/usr/bin/env python3
"""Isolated Claude-only single-use relay and observer fallback checks."""
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

def heartbeat(root, can_present=True):
    directory = root / "pending-approvals"
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    temporary = directory / "fixture-heartbeat-tmp"
    temporary.write_text(json.dumps({"processID": os.getpid(), "updatedAt": time.time() - 978307200, "canPresent": can_present}))
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

def start(root, data, provider="claude", relay=True, hud=True, entrypoint="cli", host_session=None):
    if hud:
        with heartbeat_lock:
            heartbeat(root)
            heartbeat_roots.add(root)
    args = [str(ctl), "hook", "--provider", provider, "--data-dir", str(root)]
    if relay:
        args += ["--approval-relay"]
    env = {k: v for k, v in os.environ.items() if k not in ("CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_HOST_SESSION_ID")}
    if host_session is not None:
        env["CLAUDE_CODE_HOST_SESSION_ID"] = host_session
    if entrypoint is not None:
        env["CLAUDE_CODE_ENTRYPOINT"] = entrypoint
    process = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
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

def approve_pending(root, decision="allow"):
    path, request = pending(root)
    reply = path.with_suffix(".reply")
    fd = os.open(reply, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as output:
        json.dump({"id": request["id"], "decision": decision}, output)
    return request

def finish(proc, timeout=5):
    try:
        out, err = proc.communicate(timeout=timeout)
    except Exception:
        proc.kill()
        proc.communicate()
        raise
    check("bridge exits cleanly", proc.returncode == 0 and err == b"")
    return out

with tempfile.TemporaryDirectory(prefix="island-approval-") as temporary:
    base = Path(temporary)
    for provider in ["codex", "claude", "work-buddy"]:
        for flag in [False, True]:
            root = base / (provider + ("-legacy-flag" if flag else ""))
            proc = start(root, payload(provider=provider), provider=provider, relay=flag, hud=True)
            if provider == "claude" and flag:
                request = approve_pending(root)
            out = finish(proc)
            if provider == "claude" and flag:
                result = json.loads(out.decode())
                check("Claude returns only one-shot allow, never updated permissions", result == {"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": {"behavior": "allow"}}})
                event = json.loads((root / "events.jsonl").read_text().splitlines()[-1])
                check("request is bound to exact routed task and protocol", event.get("approvalRequestID") == request["id"] and event["id"] == request["taskID"] and request["provider"] == "claude" and request["protocolVersion"] == 2)
                check("tool arguments never enter event journal", "harmless-fixture" not in (root / "events.jsonl").read_text())
            else:
                check(provider + " PermissionRequest emits no approval decision", out == b"")
            check(provider + " PermissionRequest writes lifecycle metadata only", (root / "events.jsonl").exists())
            check(provider + " retains no transient approval context", not list((root / "pending-approvals").glob("*.json")))

    def trace(root):
        path = root / "approval-trace.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    root = base / "claude-legacy-flag"
    stages = [entry["stage"] for entry in trace(root)]
    check("trace records publish, consume and output in order", stages == ["published", "reply-consumed", "decision-output"])
    check("trace is private metadata only", (root / "approval-trace.jsonl").stat().st_mode & 0o777 == 0o600
          and "harmless-fixture" not in (root / "approval-trace.jsonl").read_text()
          and all(set(entry) <= {"request", "stage", "at", "pid", "heartbeatAge"} for entry in trace(root)))

    root = base / "hud-brief-stall"
    proc = start(root, payload(provider="claude"))
    path, _ = pending(root)
    with heartbeat_lock:
        heartbeat_roots.discard(root)  # live HUD process, heartbeat stops updating
    time.sleep(6)
    check("brief HUD stall keeps the published request", proc.poll() is None and path.exists())
    approve_pending(root)
    check("decision after a brief stall is still delivered", json.loads(finish(proc))["hookSpecificOutput"]["decision"]["behavior"] == "allow")

    root = base / "hud-long-stall"
    began = time.monotonic()
    proc = start(root, payload(provider="claude"))
    path, _ = pending(root)
    with heartbeat_lock:
        heartbeat_roots.discard(root)
    check("prolonged HUD stall releases native flow", finish(proc, timeout=20) == b"" and not path.exists() and time.monotonic() - began < 16)
    check("trace explains a stall release", trace(root)[-1]["stage"] == "released-hud-unavailable" and trace(root)[-1]["heartbeatAge"] >= 12)

    host_session = "local_0f0e0d0c-0b0a-4908-8706-050403020100"
    for label, entrypoint in [("desktop-host", "claude-desktop-3p"), ("vscode-host", "claude-vscode"), ("sdk-host", "sdk-ts")]:
        root = base / label
        began = time.monotonic()
        proc = start(root, payload(provider="claude"), entrypoint=entrypoint, host_session=host_session)
        out = finish(proc)
        check(label + " hook returns at once and never answers for the host", out == b"" and time.monotonic() - began < 3)
        files = list((root / "pending-approvals").glob("*.json"))
        request = json.loads(files[0].read_text()) if len(files) == 1 else {}
        check(label + " request is bound to the host session and raw tool", request.get("hostSessionID") == host_session and request.get("toolName") == "Bash" and request.get("protocolVersion") == 2)
        check(label + " request outlives the hook process for the card's lifetime", 590 < request.get("expiresAt", 0) - request.get("createdAt", 0) <= 600)
        proc = start(root, payload(provider="claude"), entrypoint=entrypoint, host_session=host_session)
        finish(proc)
        newer = list((root / "pending-approvals").glob("*.json"))
        check(label + " newer check supersedes the session's earlier request", len(newer) == 1 and newer[0] != files[0])
    root = base / "desktop-presser"
    proc = start(root, payload(provider="claude"), entrypoint="claude-desktop-3p", host_session=host_session)
    finish(proc)
    path, request = pending(root)
    fd = os.open(path.with_suffix(".reply"), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as output:
        json.dump({"id": request["id"], "decision": "allow", "promptID": "7b10c756-a17d-436d-ba4e-a9233f56a313"}, output)
    result = path.with_suffix(".result")
    deadline = time.monotonic() + 3
    while not result.exists() and time.monotonic() < deadline:
        time.sleep(0.05)
    check("detached presser picks up the island's decision after the hook has exited", result.exists() and result.read_text() == "isolated")
    root = base / "desktop-host"
    proc = start(root, payload(provider="claude", arguments={"token": "private-fixture"}), entrypoint="claude-desktop-3p", host_session=host_session)
    finish(proc)
    check("an unpublished Desktop check still retires the session's earlier request", not list((root / "pending-approvals").glob("*.json")))
    for label, session in [("desktop-no-session", None), ("desktop-bad-session", "local_../../etc")]:
        root = base / label
        proc = start(root, payload(provider="claude"), entrypoint="claude-desktop-3p", host_session=session)
        check(label + " stays observation-only", finish(proc) == b"" and not list((root / "pending-approvals").glob("*.json")))
    root = base / "cli-host"
    proc = start(root, payload(provider="claude"), entrypoint="cli")
    _, request = pending(root)
    check("terminal CLI request keeps the hook relay", "hostSessionID" not in request and request["expiresAt"] - time.time() + 978307200 < 46)
    approve_pending(root)
    finish(proc)
    root = base / "unset-entrypoint"
    proc = start(root, payload(provider="claude"), entrypoint=None)
    approve_pending(root)
    check("terminal CLI without entrypoint keeps the relay", json.loads(finish(proc))["hookSpecificOutput"]["decision"]["behavior"] == "allow")

    root = base / "deny"
    proc = start(root, payload(provider="claude"))
    approve_pending(root, "deny")
    check("Claude explicit denial remains one-shot", json.loads(finish(proc)) == {"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": {"behavior": "deny"}}})

    for provider in ["codex", "claude", "work-buddy"]:
        root = base / (provider + "-notification")
        data = payload(provider=provider, event="Notification")
        data["notification_type"] = "permission_prompt"
        proc = start(root, data, provider=provider)
        check(provider + " Notification cannot grant permission", finish(proc) == b"")
        check(provider + " Notification retains no context", not list((root / "pending-approvals").glob("*.json")))

    for label, data, hud in [
        ("no-hud", payload(provider="claude"), False),
        ("sensitive", payload(provider="claude", arguments={"token": "private-fixture"}), True),
        ("oversized", payload(provider="claude", arguments={"command": "x" * 9000}), True),
        ("subagent", dict(payload(provider="claude"), agent_id="child"), True),
        ("missing-input", {k:v for k,v in payload(provider="claude").items() if k != "tool_input"}, True),
    ]:
        root = base / label
        proc = start(root, data, hud=hud)
        check(label + " falls back without decision", finish(proc) == b"")
        check(label + " stores no approval context", not list((root / "pending-approvals").glob("*.json")))

    root = base / "hud-disappears"
    proc = start(root, payload(provider="claude"))
    path, _ = pending(root)
    with heartbeat_lock:
        heartbeat_roots.discard(root)
        heartbeat(root, can_present=False)
    check("hidden HUD immediately releases native flow", finish(proc) == b"" and not path.exists())

    root = base / "concurrent"
    first = start(root, payload(provider="claude", session="first"))
    path, _ = pending(root)
    other = start(root, payload(provider="codex", session="other"), provider="codex", relay=False)
    check("pending approval never holds global journal lock", finish(other) == b"" and first.poll() is None)
    approve_pending(root)
    check("concurrent request still accepts its exact reply", json.loads(finish(first))["hookSpecificOutput"]["decision"]["behavior"] == "allow")

    # Exercise the real 45-second deadline (not a shortened production limit).
    root = base / "timeout"
    began = time.monotonic()
    proc = start(root, payload(provider="claude"))
    path, _ = pending(root)
    check("no user choice returns no permission decision", finish(proc, timeout=50) == b"")
    check("45-second timeout removes transient context", 43 <= time.monotonic() - began < 50 and not path.exists())
    check("trace explains a timeout release", trace(root)[-1]["stage"] == "released-expired")

    with heartbeat_lock:
        heartbeat_roots.clear()
print(f"{checks} Claude-only permission checks passed (fixtures, not provider end-to-end)")
