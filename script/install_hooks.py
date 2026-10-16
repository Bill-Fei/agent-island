#!/usr/bin/env python3
"""Install only this app's lifecycle observer, preserving every existing setting."""
import argparse
import datetime
import fcntl
import json
import os
from pathlib import Path
import shlex
import re
import tempfile


COMMON_EVENTS = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse", "Stop", "SessionEnd"]
PROVIDERS = {
    "codex": (".codex/hooks.json", COMMON_EVENTS + ["Interrupt"]),
    "claude": (".claude/settings.json", COMMON_EVENTS + ["Notification", "StopFailure", "PostToolUseFailure"]),
    "work-buddy": (".workbuddy/settings.json", COMMON_EVENTS + ["Notification"]),
}


# Hook timeouts above each relay's own deadline (ApprovalRelay.lifetime). Codex
# shows its own card only after the hook returns, so its relay is short.
RELAY_TIMEOUTS = {"claude": 50, "codex": 30}


def owned_command(value, provider, support):
    """Recognize exact island argv only; never remove another hook by substring."""
    if not isinstance(value, str):
        return False
    try:
        parts = shlex.split(value)
    except ValueError:
        return False
    if len(parts) not in (4, 5) or parts[1:4] != ["hook", "--provider", provider]:
        return False
    if len(parts) == 5 and parts[4] != "--approval-relay":
        return False
    path = Path(parts[0])
    return path.parent == support / "bin" and bool(re.fullmatch(r"linglongtaictl(?:-[0-9a-f]{16})?", path.name))


def atomic_write(path, content, mode=0o600, expected=None, compare=False):
    check_path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".linglongtai-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as output:
            output.write(content)
            output.flush()
            os.fsync(output.fileno())
        os.chmod(temporary, mode)
        if compare and (path.read_bytes() if path.exists() else None) != expected:
            raise ValueError(f"Configuration changed before replacement: {path}")
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def check_path(path):
    for candidate in [path, *path.parents]:
        if candidate.is_symlink():
            raise ValueError(f"Refusing symlinked path: {candidate}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--uninstall", action="store_true")
    parser.add_argument("--approval-relay", action="store_true", help="Opt in to single-use island approval (Claude Code, Codex); other providers remain observers")
    parser.add_argument("--providers", nargs="+", choices=list(PROVIDERS), default=list(PROVIDERS))
    args = parser.parse_args()
    task_home = Path.home()
    support = task_home / "Library/Application Support/LinglongtaiHUD"
    check_path(support)
    binary = args.binary.resolve(strict=True)
    binary_data = binary.read_bytes()
    installed_binary = support / "bin/linglongtaictl"
    lock = None
    if args.apply:
        support.mkdir(parents=True, exist_ok=True)
        lock_fd = os.open(support / ".alpha-setup.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        lock = os.fdopen(lock_fd, "rb")
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    plans = []
    for provider in args.providers:
        relative, events = PROVIDERS[provider]
        config = task_home / relative
        check_path(config)
        if config.is_symlink():
            raise ValueError(f"Refusing to replace symlink: {config}")
        original = config.read_bytes() if config.exists() else None
        settings = json.loads(original) if original is not None else {}
        if not isinstance(settings, dict):
            raise ValueError(f"Expected a JSON object: {config}")
        hooks = settings.setdefault("hooks", {})
        if not isinstance(hooks, dict):
            raise ValueError(f"Expected hooks object: {config}")
        command = shlex.quote(str(installed_binary)) + " hook --provider " + provider
        keeps_relay = args.approval_relay or (provider in RELAY_TIMEOUTS and any(
            owned_command(h.get("command"), provider, support) and h.get("command", "").endswith(" --approval-relay")
            for g in hooks.get("PermissionRequest", []) for h in g.get("hooks", [])
        ))
        for event, groups in list(hooks.items()):
            if not isinstance(groups, list):
                raise ValueError(f"Expected hook event array: {config}, {event}")
            kept = []
            for group in groups:
                if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
                    raise ValueError(f"Unexpected hook group: {config}, {event}")
                new_group = dict(group)
                new_group["hooks"] = [hook for hook in group["hooks"] if not owned_command(hook.get("command"), provider, support)]
                if new_group["hooks"]:
                    kept.append(new_group)
            hooks[event] = kept
        if not args.uninstall:
            for event in events:
                group = {"hooks": [{"type": "command", "command": command, "timeout": 2}]}
                if keeps_relay and provider in RELAY_TIMEOUTS and event == "PermissionRequest":
                    group["hooks"][0].update(command=command + " --approval-relay", timeout=RELAY_TIMEOUTS[provider])
                if event == "Notification":
                    group["matcher"] = "permission_prompt|elicitation_dialog|agent_needs_input"
                hooks.setdefault(event, []).append(group)
        settings["hooks"] = {event: groups for event, groups in hooks.items() if groups}
        updated = (json.dumps(settings, ensure_ascii=False, indent=2) + "\n").encode()
        plans.append((config, original, updated))
        # Deliberately never print settings: they may contain credentials.
        print(f"{provider}: {config}; {'remove' if args.uninstall else 'merge'} observer ({len(events)} events)")
    if not args.apply:
        print("Preview only. Use --apply to install; existing settings are backed up locally.")
        return
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    if not args.uninstall:
        aliases_file = support / "bin/legacy-bridges.json"
        check_path(aliases_file)
        registry = json.loads(aliases_file.read_bytes()) if aliases_file.exists() else []
        if not isinstance(registry, list) or any(not isinstance(name, str) or not re.fullmatch(r"linglongtaictl-[0-9a-f]{16}", name) for name in registry):
            raise ValueError("Invalid legacy bridge registry")
        aliases = set(registry)
        if installed_binary.is_symlink():
            raise ValueError("Refusing a symlinked bridge")
        if not installed_binary.exists() or installed_binary.read_bytes() != binary_data or not os.access(installed_binary, os.X_OK):
            if installed_binary.exists():
                atomic_write(installed_binary.with_name("linglongtaictl.previous"), installed_binary.read_bytes(), 0o700)
            atomic_write(installed_binary, binary_data, 0o755)
        for _, original, _ in plans:
            if original is None:
                continue
            original_hooks = json.loads(original).get("hooks", {})
            for provider in args.providers:
                for groups in original_hooks.values():
                    for group in groups:
                        for hook in group.get("hooks", []):
                            command = hook.get("command", "")
                            if owned_command(command, provider, support):
                                name = Path(shlex.split(command)[0]).name
                                if name != "linglongtaictl":
                                    aliases.add(name)
        for name in aliases:
            if not isinstance(name, str) or not re.fullmatch(r"linglongtaictl-[0-9a-f]{16}", name):
                raise ValueError("Invalid legacy bridge registry")
        atomic_write(aliases_file, (json.dumps(sorted(aliases)) + "\n").encode())
        for name in aliases:
            alias = support / "bin" / name
            check_path(alias)
            if not alias.exists() or alias.read_bytes() != binary_data or not os.access(alias, os.X_OK):
                if alias.exists():
                    atomic_write(alias.with_name(name + ".previous"), alias.read_bytes(), 0o700)
                atomic_write(alias, binary_data, 0o700)
    for config, original, updated in plans:
        if config.is_symlink() or (config.read_bytes() if config.exists() else None) != original:
            raise ValueError(f"Configuration changed during installation; refusing to overwrite: {config}")
        if original == updated:
            continue
        if original is not None:
            backup = config.with_name(config.name + ".linglongtai-backup-" + stamp)
            atomic_write(backup, original)
            print(f"Backup: {backup}")
        atomic_write(config, updated, expected=original, compare=True)
    print("Installed. Codex hook trust must be reviewed in /hooks; this installer never changes trust or permission policy.")


if __name__ == "__main__":
    main()
