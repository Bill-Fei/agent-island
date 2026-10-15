#!/usr/bin/env python3
"""Keep the app's translations complete and in sync. Run before every release:

    python3 script/check_localization.py          # report missing English, refresh zh tables
    python3 script/check_localization.py --check  # same, but exit 1 if anything is missing (CI)

Chinese is the text written in code; en.lproj maps it to English. The zh-Hans / zh-Hant
tables are generated here as identity copies of every key, so a Chinese system always resolves
each string to its Chinese source even though the bundle's development region is English
(which is what lets Japanese, French, ... systems fall back to English instead of Chinese).
Never edit the zh tables by hand.
"""
import pathlib
import plistlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
LOC = ROOT / "Resources/Localization"
EN = LOC / "en.lproj"
CHINESE = ("zh-Hans", "zh-Hant")

# User-facing files translated so far. Phase 2 (SettingsView, ClaudeChatObserver status text)
# joins this list when it is done; see docs/APP_LOCALIZATION.md.
UI_FILES = [
    "Sources/LinglongtaiHUD/HUDController.swift",
    "Sources/LinglongtaiHUD/AlphaOnboardingView.swift",
    "Sources/LinglongtaiHUD/AlphaIntegrationSetup.swift",
    "Sources/LinglongtaiHUD/HUDView.swift",
    "Sources/LinglongtaiHUD/TaskVisualState.swift",
    "Sources/LinglongtaiHUD/TodayUsageBar.swift",
    "Sources/LinglongtaiHUD/AIWorkDurationRow.swift",
    "Sources/LinglongtaiHUD/AgentPresence.swift",
    "Sources/LinglongtaiHUD/ApprovalReviewView.swift",
    "Sources/LinglongtaiShared/AIWorkDuration.swift",
    "Sources/LinglongtaiShared/Models.swift",
    "Sources/LinglongtaiShared/ToolStep.swift",
    "Sources/LinglongtaiShared/HookEventMapper.swift",
    "Sources/LinglongtaiShared/ApprovalRisk.swift",
    "Sources/LinglongtaiShared/IntegrationConfiguration.swift",
]
# TaskStore.swift mixes display text with internal notices, demo fixtures and acceptance
# previews, so only these display strings are required from it.
TASKSTORE_REQUIRED = {
    "未提交决定 · 请在原应用核实", "已提交决定 · 等待回执", "尚未收到回执 · 请核实", "岛内单次审批",
    "权限检查 · 无岛内操作", "原应用通知 · 岛内仅观察", "岛内单次审批 · 请核对本次工具操作",
    "未收到结束信号，无法确认结果", "当前无进行中的会话", "等待首次任务回调", "已收到连接 · 等待任务",
    "刚刚", "更新于 %@", "读本地轨迹", "未收到回调", "收到过回调", "历史记录 · 不再跟踪", "结果未知",
    "正在生成", "权限检查中", "等待回执", "确认通知观察中", "等待权限结果", "%lld项待确认",
    "1项结束 · %lld项进行中", "%lld项进行中", "等待事件", "中态预览", "不到 1 分钟", "%lld 分钟前",
    "%lld 小时前", "未命名任务", "等待 Agent 提供下一步", "会话已关闭",
}
# Literals that are matched against input or other apps and must never be translated, plus
# " 会话", a fragment appended to an agent name; the complete titles have their own entries.
NEVER = {"豆包", "停止", "停止回复", "停止生成", "发送", " 会话"}

ENTRY = re.compile(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";', re.M)


def swift_literals(src):
    """Yield each single-line string literal with its interpolations replaced by %@.

    A regex cannot do this: an interpolation may itself contain quoted strings, as in
    "a\\(xs.joined(separator: "、"))b". This walks the text and tracks interpolation depth.
    """
    i, n = 0, len(src)
    while i < n:
        if src[i] == "/" and src.startswith("//", i):  # skip line comments
            i = src.find("\n", i)
            i = n if i < 0 else i
            continue
        if src[i] != '"' or src.startswith('"""', i):
            i += 1
            continue
        i += 1
        out = []
        while i < n and src[i] not in '"\n':
            if src.startswith("\\(", i):
                depth, i = 1, i + 2
                while i < n and depth:
                    c = src[i]
                    if c == '"':  # nested literal inside the interpolation
                        i += 1
                        while i < n and src[i] != '"':
                            i += 2 if src[i] == "\\" else 1
                    elif c == "(":
                        depth += 1
                    elif c == ")":
                        depth -= 1
                    i += 1
                out.append("%@")
            elif src[i] == "\\":
                out.append(src[i:i + 2])
                i += 2
            else:
                out.append(src[i])
                i += 1
        i += 1
        yield "".join(out)


def code_keys(path):
    """Chinese literals in a Swift file, with interpolations folded to %@."""
    return {s for s in swift_literals(path.read_text()) if re.search(r"[一-鿿]", s)}


def matches(code_key, table):
    if code_key in table:
        return True
    # SwiftUI turns an interpolated Int into %lld; the scan above cannot tell types apart.
    pattern = re.escape(code_key).replace("%@", "%(?:@|lld|\\d\\$@)")
    return any(re.fullmatch(pattern, k) for k in table)


def main():
    en = dict(ENTRY.findall((EN / "Localizable.strings").read_text()))
    plural = plistlib.loads((EN / "Localizable.stringsdict").read_bytes())

    missing = []
    for rel in UI_FILES:
        for key in sorted(code_keys(ROOT / rel)):
            if key in NEVER or matches(key, en):
                continue
            missing.append((rel, key))
    for key in sorted(TASKSTORE_REQUIRED):
        if key not in en:
            missing.append(("Sources/LinglongtaiHUD/TaskStore.swift", key))
    unknown_plural = [k for k in plural if k not in en]

    # Identity tables for Chinese systems, regenerated from the English keys every run.
    header = "/* Generated by script/check_localization.py. Do not edit; edit en.lproj instead. */\n"
    for lang in CHINESE:
        d = LOC / f"{lang}.lproj"
        d.mkdir(exist_ok=True)
        body = "".join(f'"{k}" = "{k}";\n' for k in en)
        (d / "Localizable.strings").write_text(header + body)
        # No zh stringsdict: Chinese has no plural forms, so the identity entry above already
        # formats correctly for every count.

    print(f"English entries: {len(en)}, plural rules: {len(plural)}")
    if unknown_plural:
        print("Plural rules without a .strings entry:", *unknown_plural, sep="\n  ")
    if missing:
        print(f"Missing English ({len(missing)}):")
        for rel, key in missing:
            print(f"  {rel}: {key}")
    else:
        print("Every user-facing string has English.")
    if "--check" in sys.argv and (missing or unknown_plural):
        sys.exit(1)


if __name__ == "__main__":
    main()
