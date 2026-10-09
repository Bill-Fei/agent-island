from pathlib import Path

from PIL import Image, ImageDraw, ImageFont, ImageFilter


ROOT = Path(__file__).resolve().parent
FONT = "/System/Library/Fonts/Hiragino Sans GB.ttc"
OUT = ROOT


def font(size: int, bold: bool = False):
    # Hiragino Sans GB is a system font collection with a clean Chinese sans texture.
    return ImageFont.truetype(FONT, size=size, index=1 if bold else 0)


def fit_square(base: Image.Image, dark: bool = False) -> Image.Image:
    base = base.convert("RGB").resize((1080, 1080), Image.Resampling.LANCZOS)
    return base


def paste_square(canvas: Image.Image, base_path: Path, x: int, y: int, dark: bool = False):
    base = fit_square(Image.open(base_path), dark=dark)
    # A barely perceptible feather at the left seam keeps the photographic crop quiet.
    canvas.paste(base, (x, y))


def text(draw, xy, value, size, fill, bold=False, spacing=10, anchor=None):
    draw.multiline_text(xy, value, font=font(size, bold), fill=fill, spacing=spacing, anchor=anchor)


def footer(draw, value, fill):
    text(draw, (84, 1000), value, 20, fill)


def cover_hero():
    canvas = Image.new("RGB", (1920, 1080), (244, 245, 241))
    # Compact state: narrow wings hugging the physical notch.
    paste_square(canvas, ROOT / "focus-base-v1.png", 840, 0)
    draw = ImageDraw.Draw(canvas)
    charcoal = (21, 28, 28)
    muted = (104, 112, 110)
    text(draw, (84, 86), "Agent 灵动岛", 29, charcoal, bold=True)
    text(draw, (84, 133), "MULTI-AGENT · macOS", 16, muted, bold=True)
    text(draw, (84, 285), "你的 Agent，\n在忙什么？\n一眼看见。", 82, charcoal, bold=True, spacing=18)
    text(draw, (88, 626), "把多个 Agent 的任务状态\n收进 Mac 顶部的一座岛。", 30, muted, spacing=11)
    text(draw, (88, 807), "Codex / Claude Code / WorkBuddy", 19, muted, bold=True)
    footer(draw, "最小态 · 持续执行 · 功能示意", muted)
    canvas.save(OUT / "01-hero-agent-island.png", quality=96)


def cover_status():
    canvas = Image.new("RGB", (1920, 1080), (244, 245, 241))
    # Medium state: horizontal wings, fixed notch height, no expanded detail surface.
    paste_square(canvas, ROOT / "hero-base-v1.png", 840, 0)
    draw = ImageDraw.Draw(canvas)
    charcoal = (21, 28, 28)
    muted = (104, 112, 110)
    blue = (75, 123, 225)
    mint = (24, 155, 113)
    text(draw, (84, 86), "Agent 灵动岛", 29, charcoal, bold=True)
    text(draw, (84, 133), "MULTI-AGENT · macOS", 16, muted, bold=True)
    text(draw, (84, 285), "少切窗口，\n看清关键状态。", 82, charcoal, bold=True, spacing=18)
    text(draw, (88, 548), "谁在执行，谁需要你，\n不用挨个打开窗口。", 30, muted, spacing=11)
    # Quiet fictional examples: descriptive labels only, never real session data.
    text(draw, (88, 742), "Codex", 22, blue, bold=True)
    text(draw, (88, 778), "检查构建", 23, charcoal)
    text(draw, (290, 778), "执行中", 21, blue, bold=True)
    text(draw, (88, 837), "Claude Code", 22, (190, 164, 255), bold=True)
    text(draw, (88, 873), "整理文档", 23, charcoal)
    text(draw, (290, 873), "等待输入", 21, muted, bold=True)
    text(draw, (88, 932), "WorkBuddy", 22, mint, bold=True)
    text(draw, (88, 968), "汇总工作", 23, charcoal)
    text(draw, (290, 968), "本轮结束", 21, muted, bold=True)
    footer(draw, "中态 · 新事件 · 示例任务 · 功能示意", muted)
    canvas.save(OUT / "02-status-awareness.png", quality=96)


def cover_focus():
    canvas = Image.new("RGB", (1920, 1080), (12, 16, 18))
    # Hover state: the island grows from the physical notch into one detail surface.
    paste_square(canvas, ROOT / "states-base-v1.png", 840, 0, dark=True)
    draw = ImageDraw.Draw(canvas)
    white = (242, 245, 244)
    muted = (149, 158, 157)
    blue = (143, 176, 255)
    mint = (125, 226, 184)
    text(draw, (84, 86), "Agent 灵动岛", 29, white, bold=True)
    text(draw, (84, 133), "MULTI-AGENT · macOS", 16, muted, bold=True)
    text(draw, (84, 274), "悬停展开，\n看清详情。", 82, white, bold=True, spacing=18)
    text(draw, (88, 558), "连续悬停 0.2 秒展开，\n移开后回到对应状态。", 30, muted, spacing=11)
    # These are fictional labels for a conceptual cover, not personal task data.
    text(draw, (88, 742), "任务状态", 20, white, bold=True)
    text(draw, (88, 790), "Codex    检查构建", 22, blue, bold=True)
    text(draw, (88, 835), "Claude Code    整理文档", 22, (190, 164, 255), bold=True)
    text(draw, (88, 880), "WorkBuddy    汇总工作", 22, mint, bold=True)
    text(draw, (88, 948), "示例任务 · 非真实会话", 17, muted)
    footer(draw, "Hover 展开态 · 最近 24 小时 · 功能示意", muted)
    canvas.save(OUT / "03-ambient-states.png", quality=96)


if __name__ == "__main__":
    cover_hero()
    cover_status()
    cover_focus()
