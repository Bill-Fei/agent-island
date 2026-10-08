from pathlib import Path
from PIL import Image, ImageDraw, ImageFont, ImageFilter, ImageOps

OUT = Path(__file__).resolve().parent
MEDIA = OUT.parent
FONT = '/System/Library/Fonts/Hiragino Sans GB.ttc'
SIGNATURE = 'Designed by Bill · GitHub @Bill-Fei'


def text(draw, xy, value, size, color):
    draw.multiline_text(xy, value, font=ImageFont.truetype(FONT, size, index=0),
                        fill=color, spacing=18)


def capture(path, box):
    with Image.open(path) as source:
        shot = source.convert('RGBA').crop(box)
    px = shot.load()
    for y in range(shot.height):
        for direction in (range(shot.width), range(shot.width - 1, -1, -1)):
            for x in direction:
                if min(px[x, y][:3]) <= 235:
                    break
                px[x, y] = (0, 0, 0, 0)
    return shot


def poster(name, label, heading, body, note, shot, dark=False):
    bg = (12, 16, 18) if dark else (244, 245, 241)
    fg = (242, 245, 244) if dark else (21, 28, 28)
    muted = (149, 158, 157) if dark else (104, 112, 110)
    canvas = Image.new('RGBA', (1920, 1080), bg + (255,))
    x, y, w = 855, 257, 990
    h = round(w * 1964 / 3024)
    shadow = Image.new('RGBA', canvas.size)
    ImageDraw.Draw(shadow).rounded_rectangle(
        (x - 14, y - 14, x + w + 14, y + h), 42, fill=(0, 0, 0, 60))
    canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(22)))
    draw = ImageDraw.Draw(canvas)
    draw.rounded_rectangle((x - 8, y - 8, x + w + 8, y + h + 8), 24,
                           fill=(91, 97, 95), outline=(166, 171, 168), width=2)
    draw.rounded_rectangle((x - 4, y - 4, x + w + 4, y + h + 4), 21,
                           fill=(11, 15, 15))
    base = 'states-base-v1.png' if dark else 'focus-base-v1.png'
    with Image.open(MEDIA / 'alpha-covers-20261007-v1' / base) as source:
        # Wallpaper only; all product UI comes from the original captures.
        wallpaper = ImageOps.fit(source.convert('RGBA').crop((290, 650, 1080, 1080)),
                                 (w, h), method=Image.Resampling.LANCZOS)
    mask = Image.new('L', (w, h))
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, w, h), 18, fill=255)
    wallpaper.putalpha(mask)
    canvas.alpha_composite(wallpaper, (x, y))
    scale = w / 3024  # One physical display scale for all three 2x captures.
    shot = shot.resize((round(shot.width * scale), round(shot.height * scale)),
                       Image.Resampling.LANCZOS)
    canvas.alpha_composite(shot, (x + (w - shot.width) // 2, y))
    draw = ImageDraw.Draw(canvas)
    base_y = y + h + 12
    draw.polygon([(x - 28, base_y), (x + w + 28, base_y),
                  (x + w + 15, base_y + 20), (x - 15, base_y + 20)],
                 fill=(112, 118, 116))
    draw.line((x - 26, base_y, x + w + 26, base_y), fill=(196, 200, 198), width=2)
    draw.rounded_rectangle((x + w // 2 - 70, base_y,
                            x + w // 2 + 70, base_y + 7), 4, fill=(65, 70, 68))
    text(draw, (84, 86), 'Agent 灵动岛', 29, fg)
    text(draw, (84, 133), 'MULTI-AGENT · macOS', 16, muted)
    text(draw, (88, 220), label, 22, muted)
    text(draw, (84, 300), heading, 76, fg)
    text(draw, (88, 600), body, 29, muted)
    text(draw, (88, 807), note, 22, muted)
    text(draw, (84, 1000), SIGNATURE, 23, muted)
    text(draw, (1480, 1005), '真实产品界面合成 · 非整屏实拍', 18, muted)
    result = canvas.convert('RGB')
    result.save(OUT / f'{name}.png')
    result.save(OUT / f'{name}.jpg', quality=95, subsampling=0)
    return result


if __name__ == '__main__':
    small = capture(MEDIA / 'real-product-ui/01-small-state-20261008.jpg',
                    (465, 0, 1055, 80))
    medium = capture(MEDIA / 'real-product-ui/02-middle-state-preview-20261008.jpg',
                     (300, 0, 1220, 80))
    overview = capture(MEDIA / 'real-product-ui/03-task-overview-20261008.jpg',
                       (100, 0, 1420, 910))
    # Visual order is light / full / medium so the black panel sits in the middle.
    panels = [
        poster('01-light-presence', '轻 · 安静陪伴', '在场，\n不打扰。',
               '多个 Agent 的运行状态，\n安静留在 Mac 顶部。',
               '任务进行时，保持轻量呈现。', small),
        poster('02-full-overview', '重 · 完整展开', '轻轻悬停，\n一览全局。',
               '展开最近 24 小时的任务，\n状态与细节，清楚呈现。',
               '悬停查看，移开收起。', overview, True),
        poster('03-timely-awareness', '中 · 适时提醒', '重要时刻，\n自然浮现。',
               '关键变化，及时看见。\n提示收起，任务仍在。',
               '重要变化横向展开。\n此图为应用内置「中态预览」。', medium),
    ]
    sheet = Image.new('RGB', (1080, 1824))
    for index, panel in enumerate(panels):
        sheet.paste(panel.resize((1080, 608), Image.Resampling.LANCZOS),
                    (0, index * 608))
    sheet.save(OUT / '00-moments-triptych.jpg', quality=95, subsampling=0)
