from pathlib import Path
from PIL import Image, ImageDraw, ImageFont, ImageFilter, ImageOps

OUT = Path(__file__).resolve().parent
MEDIA = OUT.parent
FONT = '/System/Library/Fonts/Hiragino Sans GB.ttc'
SIGNATURE = 'Designed by Bill · GitHub @Bill-Fei'
ICONS = (
    ('finder', '/System/Library/CoreServices/Finder.app/Contents/Resources/Finder.icns'),
    ('safari', '/Applications/Safari.app/Contents/Resources/AppIcon.icns'),
    ('messages', '/System/Applications/Messages.app/Contents/Resources/AppIcon.icns'),
    ('notes', '/System/Applications/Notes.app/Contents/Resources/AppIcon.icns'),
    ('photos', '/System/Applications/Photos.app/Contents/Resources/AppIcon.icns'),
    ('settings', '/System/Applications/System Settings.app/Contents/Resources/SystemSettings.icns'),
    ('trash', '/System/Library/CoreServices/Dock.app/Contents/Resources/trashempty@2x.png'),
)


def prepare_icons():
    for name, source in ICONS:
        destination = OUT / 'assets' / f'{name}.png'
        if not destination.exists():
            with Image.open(source) as icon:
                icon.convert('RGBA').save(destination)


def add_dock(wallpaper, dark=False):
    """Illustrative glass tray using genuine, locally installed system icons."""
    scale = wallpaper.width / 3024
    size, gap, pad = (round(value * scale) for value in (96, 12, 20))
    separator_gap = round(28 * scale)
    width = pad * 2 + size * 7 + gap * 6 + separator_gap
    height = round(126 * scale)
    left = (wallpaper.width - width) // 2
    top = wallpaper.height - height - round(16 * scale)
    radius = round(34 * scale)
    shape = Image.new('L', (width, height))
    ImageDraw.Draw(shape).rounded_rectangle((0, 0, width - 1, height - 1), radius, fill=255)
    glass = wallpaper.crop((left, top, left + width, top + height)).filter(
        ImageFilter.GaussianBlur(round(18 * scale)))
    tint = (35, 43, 43, 130) if dark else (248, 250, 246, 125)
    glass.alpha_composite(Image.new('RGBA', glass.size, tint))
    glass.putalpha(shape)
    wallpaper.alpha_composite(glass, (left, top))
    draw = ImageDraw.Draw(wallpaper)
    stroke = (230, 239, 236, 90) if dark else (255, 255, 255, 180)
    draw.rounded_rectangle((left, top, left + width - 1, top + height - 1),
                           radius, outline=stroke, width=1)
    cursor = left + pad
    for index, (name, _) in enumerate(ICONS):
        if index == 6:
            separator = cursor + separator_gap // 2 - gap // 2
            draw.line((separator, top + round(20 * scale),
                       separator, top + height - round(20 * scale)),
                      fill=(175, 185, 182, 120), width=1)
            cursor += separator_gap
        with Image.open(OUT / 'assets' / f'{name}.png') as original:
            icon = ImageOps.contain(original.convert('RGBA'), (size, size),
                                   method=Image.Resampling.LANCZOS)
        wallpaper.alpha_composite(icon, (cursor + (size - icon.width) // 2,
                                         top + (height - icon.height) // 2))
        cursor += size + gap


def menu_bar(dark=False):
    """Illustrative macOS menu bar at 2x native scale, never a live capture."""
    tint = (12, 20, 21, 76) if dark else (238, 241, 233, 62)
    ink = (232, 239, 237, 208) if dark else (28, 39, 36, 202)
    bar = Image.new('RGBA', (3024, 74), tint)
    draw = ImageDraw.Draw(bar)
    font = ImageFont.truetype(FONT, 26, index=0)
    # The Apple glyph comes from the installed system font, not a traced logo.
    apple_font = ImageFont.truetype('/System/Library/Fonts/Helvetica.ttc', 32)
    draw.text((36, 35), '\uf8ff', font=apple_font, fill=ink, anchor='lm')
    cursor = 98
    for word in ('Finder', '文件', '编辑', '显示', '前往', '窗口', '帮助'):
        draw.text((cursor, 37), word, font=font, fill=ink, anchor='lm')
        cursor += round(draw.textlength(word, font=font)) + 36
    # All system elements stay well outside the central camera/island region.
    assert cursor < 1052
    clock = '周四 10:08'
    clock_x = 3024 - 36 - round(draw.textlength(clock, font=font))
    draw.text((clock_x, 37), clock, font=font, fill=ink, anchor='lm')
    control_x = clock_x - 57
    for dy, thumb in ((-6, 6), (7, -5)):
        draw.rounded_rectangle((control_x - 13, 37 + dy - 3,
                                control_x + 13, 37 + dy + 3), 3,
                               outline=ink, width=2)
        draw.ellipse((control_x + thumb - 3, 37 + dy - 3,
                      control_x + thumb + 3, 37 + dy + 3), fill=ink)
    search_x = control_x - 54
    draw.ellipse((search_x - 10, 25, search_x + 6, 41), outline=ink, width=2)
    draw.line((search_x + 4, 39, search_x + 12, 47), fill=ink, width=2)
    battery_x = search_x - 65
    draw.rounded_rectangle((battery_x - 18, 28, battery_x + 15, 44),
                           4, outline=ink, width=2)
    draw.rounded_rectangle((battery_x - 14, 32, battery_x + 7, 40), 2, fill=ink)
    draw.line((battery_x + 18, 33, battery_x + 18, 39), fill=ink, width=3)
    wifi_x = battery_x - 66
    for radius in (17, 12, 7):
        draw.arc((wifi_x - radius, 31 - radius,
                  wifi_x + radius, 31 + radius), 220, 320, fill=ink, width=2)
    draw.ellipse((wifi_x - 2, 38, wifi_x + 2, 42), fill=ink)
    assert wifi_x > 1972
    return bar


def text(draw, xy, value, size, color):
    draw.multiline_text(xy, value, font=ImageFont.truetype(FONT, size, index=0),
                        fill=color, spacing=36)


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
    canvas = Image.new('RGBA', (3840, 2160), bg + (255,))
    x, y, w = 1710, 514, 1980
    h = round(w * 1964 / 3024)
    shadow = Image.new('RGBA', canvas.size)
    ImageDraw.Draw(shadow).rounded_rectangle(
        (x - 28, y - 28, x + w + 28, y + h), 84, fill=(0, 0, 0, 60))
    canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(44)))
    draw = ImageDraw.Draw(canvas)
    draw.rounded_rectangle((x - 16, y - 16, x + w + 16, y + h + 16), 48,
                           fill=(91, 97, 95), outline=(166, 171, 168), width=4)
    draw.rounded_rectangle((x - 8, y - 8, x + w + 8, y + h + 8), 42,
                           fill=(11, 15, 15))
    base = 'states-base-v1.png' if dark else 'focus-base-v1.png'
    with Image.open(MEDIA / 'alpha-covers-20261007-v1' / base) as source:
        # Wallpaper only; all product UI comes from the original captures.
        wallpaper = ImageOps.fit(source.convert('RGBA').crop((290, 650, 1080, 1080)),
                                 (w, h), method=Image.Resampling.LANCZOS)
    bar = menu_bar(dark).resize((w, round(74 * w / 3024)), Image.Resampling.LANCZOS)
    wallpaper.alpha_composite(bar, (0, 0))
    add_dock(wallpaper, dark)
    mask = Image.new('L', (w, h))
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, w, h), 36, fill=255)
    wallpaper.putalpha(mask)
    canvas.alpha_composite(wallpaper, (x, y))
    scale = w / 3024  # One physical display scale for all three 2x captures.
    shot = shot.resize((round(shot.width * scale), round(shot.height * scale)),
                       Image.Resampling.LANCZOS)
    canvas.alpha_composite(shot, (x + (w - shot.width) // 2, y))
    draw = ImageDraw.Draw(canvas)
    base_y = y + h + 24
    draw.polygon([(x - 56, base_y), (x + w + 56, base_y),
                  (x + w + 30, base_y + 40), (x - 30, base_y + 40)],
                 fill=(112, 118, 116))
    draw.line((x - 52, base_y, x + w + 52, base_y), fill=(196, 200, 198), width=4)
    draw.rounded_rectangle((x + w // 2 - 140, base_y,
                            x + w // 2 + 140, base_y + 14), 8, fill=(65, 70, 68))
    text(draw, (168, 172), 'Agent 灵动岛', 58, fg)
    text(draw, (168, 266), 'MULTI-AGENT · macOS', 32, muted)
    text(draw, (176, 440), label, 44, muted)
    text(draw, (168, 600), heading, 152, fg)
    text(draw, (176, 1200), body, 58, muted)
    text(draw, (176, 1614), note, 44, muted)
    text(draw, (168, 2000), SIGNATURE, 46, muted)
    text(draw, (2960, 2010), '真实产品界面合成 · 非整屏实拍', 36, muted)
    result = canvas.convert('RGB')
    result.save(OUT / f'{name}-4k.png')
    result.save(OUT / f'{name}-4k.jpg', quality=98, subsampling=0)
    return result


if __name__ == '__main__':
    prepare_icons()
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
