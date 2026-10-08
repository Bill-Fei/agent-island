from pathlib import Path
import argparse
import runpy
from PIL import Image, ImageDraw, ImageFont, ImageFilter, ImageOps

OUT = Path(__file__).resolve().parent
MEDIA = OUT.parent
HELPERS = runpy.run_path(str(MEDIA / 'alpha-covers-20261008-v6-4k/compose_covers.py'))
FONT = '/System/Library/Fonts/Hiragino Sans GB.ttc'
BG = (244, 245, 241)
INK = (21, 28, 28)
MUTED = (104, 112, 110)
SIZE = (2880, 3840)


def import_screenshot(path):
    """Save only the real island pixels; never copy the user's whole desktop."""
    with Image.open(path) as source:
        assert source.size == (3456, 2234), source.size
        shot = source.convert('RGBA').crop((1066, 0, 2388, 910))
    pixels = shot.load()
    for y in range(shot.height):
        # Desktop wallpaper is bright/chromatic; the actual island edge is dark.
        left = next((x for x in range(shot.width) if max(pixels[x, y][:3]) <= 40), None)
        right = next((x for x in range(shot.width - 1, -1, -1)
                      if max(pixels[x, y][:3]) <= 40), None)
        # The dark desktop menu icon outside the right flare is not island UI.
        # Bound the edge by the island's bilateral geometry (source center x=1726).
        if left is not None:
            right = min(right, 1320 - left)
        if left is None:
            for x in range(shot.width):
                pixels[x, y] = (0, 0, 0, 0)
        else:
            for x in range(left):
                pixels[x, y] = (0, 0, 0, 0)
            for x in range(right + 1, shot.width):
                pixels[x, y] = (0, 0, 0, 0)
    shot.save(OUT / 'assets/four-agent-overview-20261008-210709.png')


def text(draw, position, value, size, color=INK, spacing=28):
    font = ImageFont.truetype(FONT, size, index=0)
    bounds = draw.multiline_textbbox(position, value, font=font, spacing=spacing)
    assert bounds[2] < SIZE[0] - 100 and bounds[3] < SIZE[1] - 20, bounds
    draw.multiline_text(position, value, font=font, fill=color, spacing=spacing)


def screen_detail(canvas, top, height, shot, dark=False):
    left, width = 160, 1630
    base = 'states-base-v1.png' if dark else 'focus-base-v1.png'
    with Image.open(MEDIA / 'alpha-covers-20261007-v1' / base) as source:
        wallpaper = ImageOps.fit(source.convert('RGBA').crop((290, 650, 1080, 1080)),
                                 (width, height), method=Image.Resampling.LANCZOS)
    # This is a close-up viewport, not a whole Mac display. Keep UI at native pixels.
    tint = (12, 20, 21, 76) if dark else (238, 241, 233, 62)
    wallpaper.alpha_composite(Image.new('RGBA', (width, 74), tint), (0, 0))
    draw = ImageDraw.Draw(wallpaper)
    menu_ink = (232, 239, 237, 208) if dark else (28, 39, 36, 202)
    apple = ImageFont.truetype('/System/Library/Fonts/Helvetica.ttc', 32)
    menu_font = ImageFont.truetype(FONT, 25, index=0)
    draw.text((30, 34), '\uf8ff', font=apple, fill=menu_ink, anchor='lm')
    draw.text((70, 37), 'Finder', font=menu_font, fill=menu_ink, anchor='lm')
    draw.text((width - 30, 37), '10:08', font=menu_font, fill=menu_ink, anchor='rm')
    # Source screenshot only: no new UI, task text or progress is drawn.
    wallpaper.alpha_composite(shot, ((width - shot.width) // 2, 0))
    local_mask = Image.new('L', (width, height), 0)
    ImageDraw.Draw(local_mask).rounded_rectangle((0, 0, width - 1, height + 40),
                                                42, fill=255)
    wallpaper.putalpha(local_mask)
    frame = Image.new('RGBA', (width + 16, height + 8))
    frame_draw = ImageDraw.Draw(frame)
    frame_draw.rounded_rectangle((0, 0, width + 15, height + 60), 50,
                                 fill=(15, 20, 20), outline=(116, 126, 121), width=3)
    frame.alpha_composite(wallpaper, (8, 8))
    # Fade the crop bottom into the page, not a rounded screenshot card.
    fade = Image.new('L', frame.size, 255)
    fade_draw = ImageDraw.Draw(fade)
    fade_height = 160
    for line in range(fade_height):
        opacity = round(255 * (1 - line / (fade_height - 1)))
        fade_draw.line((0, frame.height - fade_height + line,
                        frame.width, frame.height - fade_height + line), fill=opacity)
    frame.putalpha(fade)
    shadow = Image.new('RGBA', canvas.size)
    ImageDraw.Draw(shadow).rounded_rectangle((left - 10, top - 10,
                                              left + width + 10, top + height - 160),
                                             54, fill=(0, 0, 0, 32))
    canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(24)))
    canvas.alpha_composite(frame, (left - 8, top - 8))


def compose():
    canvas = Image.new('RGBA', SIZE, BG + (255,))
    draw = ImageDraw.Draw(canvas)
    text(draw, (160, 130), 'Agent 灵动岛', 68)
    text(draw, (164, 236), 'MULTI-AGENT · macOS', 34, MUTED)
    text(draw, (150, 370), '恰到好处地在场。', 180)
    text(draw, (164, 620), '多个 Agent 的任务状态，在 Mac 顶部，一眼看见。', 55, MUTED)
    capture = HELPERS['capture']
    small = capture(MEDIA / 'real-product-ui/01-small-state-20261008.jpg',
                    (465, 0, 1055, 80))
    medium = capture(MEDIA / 'real-product-ui/02-middle-state-preview-20261008.jpg',
                     (300, 0, 1220, 80))
    with Image.open(OUT / 'assets/four-agent-overview-20261008-210709.png') as source:
        overview = source.convert('RGBA')
    screen_detail(canvas, 910, 540, small)
    screen_detail(canvas, 1680, 540, medium)
    screen_detail(canvas, 2450, 1130, overview, dark=True)
    draw = ImageDraw.Draw(canvas)
    rows = (
        (860, '轻 · 安静陪伴', '在场，\n不打扰。',
         '任务进行时，\n状态安静留在顶部。', '小态 · 真实产品截图'),
        (1630, '中 · 适时提醒', '重要时刻，\n自然浮现。',
         '关键变化主动呈现，\n随后轻轻收起。', '此图为应用内置「中态预览」。'),
        (2430, '重 · 完整展开', '轻轻悬停，\n一览全局。',
         '展开最近 24 小时的任务，\n查看状态与细节。', '悬停查看，移开收起。'),
    )
    for top, label, heading, body, note in rows:
        text(draw, (1950, top), label, 38, MUTED)
        text(draw, (1945, top + 118), heading, 90)
        text(draw, (1950, top + 385), body, 49, MUTED, spacing=20)
        text(draw, (1950, top + 585), note, 31, MUTED)
    for top in (1510, 2290):
        draw.line((160, top, 2720, top), fill=(215, 221, 213), width=2)
    text(draw, (160, 3690), 'Designed by Bill · GitHub @Bill-Fei', 40, MUTED)
    text(draw, (160, 3768), '真实产品界面合成 · 局部展示，非整屏实拍 · 菜单栏为示意', 24, MUTED)
    result = canvas.convert('RGB')
    result.save(OUT / 'agent-island-overview-4k.png')
    result.save(OUT / 'agent-island-overview-4k.jpg', quality=98, subsampling=0)
    result.resize((1080, 1440), Image.Resampling.LANCZOS).save(
        OUT / 'agent-island-overview-preview.jpg', quality=95, subsampling=0)
    print('Saved 2880 × 3840 product overview, PNG / JPG / preview')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--import-screenshot', type=Path)
    args = parser.parse_args()
    if args.import_screenshot:
        import_screenshot(args.import_screenshot)
    compose()
