#!/usr/bin/env python3
"""Install only this app's lifecycle observer, preserving every existing setting."""
import argparse
import datetime
import hashlib
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


def atomic_write(path, content, mode=0o600):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".linglongtai-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as output:
            output.write(content)
            output.flush()
            os.fsync(output.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--uninstall", action="store_true")
    parser.add_argument("--approval-relay", action="store_true", help="Opt in to Claude Code single-use approval only; other providers remain observers")
    parser.add_argument("--providers", nargs="+", choices=list(PROVIDERS), default=list(PROVIDERS))
    args = parser.parse_args()
    task_home = Path.home()
    support = task_home / "Library/Application Support/LinglongtaiHUD"
    binary = args.binary.resolve(strict=True)
    binary_data = binary.read_bytes()
    installed_binary = support / ("bin/linglongtaictl-" + hashlib.sha256(binary_data).hexdigest()[:16])
    plans = []
    for provider in args.providers:
        relative, events = PROVIDERS[provider]
        config = task_home / relative
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
                if args.approval_relay and provider == "claude" and event == "PermissionRequest":
                    group["hooks"][0].update(command=command + " --approval-relay", timeout=50)
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
        if installed_binary.is_symlink():
            raise ValueError("Refusing a symlinked bridge")
        if installed_binary.exists():
            if installed_binary.read_bytes() != binary_data:
                raise ValueError("Existing immutable bridge content differs; configuration unchanged")
        else:
            atomic_write(installed_binary, binary_data, 0o755)
    for config, original, updated in plans:
        if config.is_symlink() or (config.read_bytes() if config.exists() else None) != original:
            raise ValueError(f"Configuration changed during installation; refusing to overwrite: {config}")
        if original == updated:
            continue
        if original is not None:
            backup = config.with_name(config.name + ".linglongtai-backup-" + stamp)
            atomic_write(backup, original)
            print(f"Backup: {backup}")
        atomic_write(config, updated)
    print("Installed. Codex hook trust must be reviewed in /hooks; this installer never changes trust or permission policy.")


if __name__ == "__main__":
    main()
