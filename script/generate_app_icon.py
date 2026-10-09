"""Rebuild the product mark and macOS icon locally with Pillow."""

from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter


SIGNAL_COLORS = [(121, 242, 181), (247, 247, 244), (132, 219, 243)]


def notch_points(x: float, y: float, width: float, height: float) -> list[tuple[float, float]]:
    shoulder = width * 0.12
    radius = height * 0.35
    left, right = x + shoulder, x + width - shoulder
    points = [(x, y)]

    def curve(start: tuple[float, float], control: tuple[float, float], end: tuple[float, float]) -> None:
        for index in range(1, 41):
            t = index / 40
            points.append(tuple((1 - t) ** 2 * a + 2 * (1 - t) * t * b + t * t * c
                                for a, b, c in zip(start, control, end)))

    curve((x, y), (left, y), (left, y + shoulder))
    points.append((left, y + height - radius))
    curve(points[-1], (left, y + height), (left + radius, y + height))
    points.append((right - radius, y + height))
    curve(points[-1], (right, y + height), (right, y + height - radius))
    points.append((right, y + shoulder))
    curve(points[-1], (right, y), (x + width, y))
    points.append((x, y))
    return points


def mark(size: int) -> Image.Image:
    image = Image.new("RGBA", (size, size))
    points = notch_points(size * 0.04, size * 0.25, size * 0.92, size * 0.5)
    draw = ImageDraw.Draw(image)
    draw.polygon(points, fill=(10, 12, 13, 255))
    outline = Image.new("L", image.size)
    ImageDraw.Draw(outline).line(points, fill=255, width=round(size * 0.06), joint="curve")
    metal = Image.new("RGBA", image.size)
    metal_draw = ImageDraw.Draw(metal)
    for y in range(size):
        ratio = max(0, min(1, (y / size - 0.25) / 0.5))
        value = round(248 - 95 * ratio)
        metal_draw.line((0, y, size, y), fill=(value, value + min(4, 255 - value), value, 255))
    image.alpha_composite(Image.composite(metal, Image.new("RGBA", image.size), outline))
    for index, (color, height) in enumerate(zip(SIGNAL_COLORS, [0.16, 0.25, 0.12])):
        center_x = size * (0.5 + (index - 1) * 0.14)
        center_y = size * 0.528
        half_width, half_height = size * 0.035, size * height / 2
        draw.rounded_rectangle((center_x - half_width, center_y - half_height,
                                center_x + half_width, center_y + half_height),
                               radius=half_width, fill=(*color, 255))
    return image


def app_icon(size: int = 1024) -> Image.Image:
    image = Image.new("RGBA", (size, size))
    mask = Image.new("L", image.size)
    inset = size * 100 / 1024
    ImageDraw.Draw(mask).rounded_rectangle((inset, inset, size - inset, size - inset),
                                          radius=size * 185 / 1024, fill=255)
    surface = Image.new("RGBA", image.size)
    draw = ImageDraw.Draw(surface)
    for y in range(size):
        ratio = y / (size - 1)
        value = round(38 - 25 * ratio)
        draw.line((0, y, size, y), fill=(value, value + 1, value + 2, 255))
    image.alpha_composite(Image.composite(surface, Image.new("RGBA", image.size), mask))
    ImageDraw.Draw(image).rounded_rectangle((inset, inset, size - inset, size - inset),
                                           radius=size * 185 / 1024, outline=(255, 255, 255, 26),
                                           width=max(1, round(size * 2 / 1024)))
    logo_size = round(size * 0.68)
    logo = mark(logo_size)
    origin = (round((size - logo_size) / 2), round((size - logo_size) / 2))
    shadow = Image.new("RGBA", image.size)
    shadow.paste(Image.new("RGBA", logo.size, (0, 0, 0, 140)),
                 (origin[0], origin[1] + round(size * 0.018)), logo.getchannel("A"))
    image.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(size * 0.017)))
    image.alpha_composite(logo, origin)
    return image


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path,
                        default=Path(__file__).resolve().parents[1] / "Resources")
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    logo = mark(1024)
    logo.save(args.output_dir / "BrandMark.png")
    icon = app_icon()
    icon.save(args.output_dir / "AppIcon.png")
    icon.save(args.output_dir / "AppIcon.icns", format="ICNS")

    # Inspect the actual 16-64 pixel outputs, not a scaled screenshot of the master.
    preview = Image.new("RGB", (720, 400), (235, 238, 240))
    large = icon.resize((280, 280), Image.Resampling.LANCZOS)
    preview.paste(large, (24, 36), large)
    draw = ImageDraw.Draw(preview)
    draw.rounded_rectangle((336, 32, 696, 190), radius=8, fill=(12, 13, 14))
    for index, target in enumerate([16, 24, 32, 48, 64]):
        x = 356 + index * 64
        small = logo.resize((target, target), Image.Resampling.LANCZOS)
        preview.paste(small, (x, 86 - target // 2), small)
        draw.text((x, 142), str(target), fill=(185, 192, 196))
        small_icon = icon.resize((target, target), Image.Resampling.LANCZOS)
        preview.paste(small_icon, (x, 266 - target // 2), small_icon)
        draw.text((x, 324), str(target), fill=(55, 62, 66))
    preview.save(args.output_dir / "BrandPreview.png")
    print(f"Generated product mark and app icon in {args.output_dir}")


if __name__ == "__main__":
    main()
