#!/usr/bin/env python3
"""Generate the RBF channel app icon by recoloring the Debug icon.

Third entry in an established series. AppIcon-Debug carries an orange DEV
banner; AppIcon-Nightly is that same art with the banner recolored purple and
re-texted NIGHTLY (scripts/generate_nightly_icon.py). This does the same with
green and RBF, so all three channels stay visibly one product family and the
chevron art has exactly one source.

Run once; commit the output. Not part of the install path.

    python3 rbf/scripts/generate_rbf_icon.py

DEPENDENCY, AND WHY THIS SCRIPT NAGS ABOUT IT
    Needs Pillow, which this repo declares nowhere -- there is no
    requirements.txt or pyproject.toml, and no python3 on a stock machine here
    has it. scripts/generate_nightly_icon.py has the same undeclared dependency
    and dies on a bare ModuleNotFoundError. Rather than repeat that, this fails
    with the command that fixes it. Cheapest fix that touches nothing global:

        python3 -m venv /path/to/scratch/venv
        /path/to/scratch/venv/bin/python -m pip install Pillow
        /path/to/scratch/venv/bin/python rbf/scripts/generate_rbf_icon.py

DIFFERENCES FROM THE PRECEDENT, DELIBERATE
    1. Banner text and color come from rbf/scripts/lib/rbf-channel.env, so the
       channel's identity stays in one record.
    2. Contents.json is copied from the source iconset. generate_nightly_icon.py
       writes PNGs and no Contents.json -- AppIcon-Nightly's was evidently
       produced by hand, which is a step nobody would repeat from reading the
       script. An .appiconset without it is not a valid asset catalog entry.
    3. Output is verified before the script claims success.
"""
import os
import shutil
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CHANNEL_RECORD = os.path.join(REPO, "rbf", "scripts", "lib", "rbf-channel.env")
SRC_DIR = os.path.join(REPO, "Assets.xcassets", "AppIcon-Debug.appiconset")

# The Debug banner's fill. Detection below keys off it, so it is named rather
# than buried in the predicate.
DEBUG_BANNER_RGB = (255, 107, 0)

SIZES = [
    ("16.png", 16),
    ("16@2x.png", 32),
    ("32.png", 32),
    ("32@2x.png", 64),
    ("128.png", 128),
    ("128@2x.png", 256),
    ("256.png", 256),
    ("256@2x.png", 512),
    ("512.png", 512),
    ("512@2x.png", 1024),
]


def require_pillow():
    """Fail with the fix, not with a traceback."""
    try:
        from PIL import Image, ImageDraw, ImageFont  # noqa: F401
        return
    except ModuleNotFoundError:
        sys.stderr.write(
            "error: Pillow is not installed for this interpreter.\n"
            f"       interpreter: {sys.executable}\n"
            "       This repo declares no Python dependencies, so nothing\n"
            "       installs it for you. Cheapest fix, touching nothing global:\n\n"
            "         python3 -m venv <scratch>/venv\n"
            "         <scratch>/venv/bin/python -m pip install Pillow\n"
            "         <scratch>/venv/bin/python rbf/scripts/generate_rbf_icon.py\n\n"
            "       Put <scratch> on the external drive, not in the repo.\n"
        )
        raise SystemExit(2)


def read_channel_record(path):
    """Parse flat KEY="value" lines. Deliberately dumb, and it must stay in
    step with the shell side, which just `source`s the same file. The quotes
    are load-bearing: two values contain spaces."""
    if not os.path.isfile(path):
        sys.stderr.write(f"error: channel record not found: {path}\n")
        raise SystemExit(2)

    values = {}
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            key, sep, value = line.partition("=")
            if not sep:
                continue
            value = value.strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
                value = value[1:-1]
            values[key.strip()] = value

    required = ("RBF_ICON_SET", "RBF_ICON_BANNER_TEXT", "RBF_ICON_BANNER_RGB")
    missing = [key for key in required if not values.get(key)]
    if missing:
        sys.stderr.write(
            f"error: channel record is missing {', '.join(missing)}: {path}\n"
        )
        raise SystemExit(2)

    try:
        rgb = tuple(int(part) for part in values["RBF_ICON_BANNER_RGB"].split(","))
    except ValueError:
        sys.stderr.write(
            "error: RBF_ICON_BANNER_RGB must be three comma-separated ints, got "
            f"{values['RBF_ICON_BANNER_RGB']!r}\n"
        )
        raise SystemExit(2)
    if len(rgb) != 3 or not all(0 <= part <= 255 for part in rgb):
        sys.stderr.write(
            f"error: RBF_ICON_BANNER_RGB out of range: {values['RBF_ICON_BANNER_RGB']!r}\n"
        )
        raise SystemExit(2)

    return values["RBF_ICON_SET"], values["RBF_ICON_BANNER_TEXT"], rgb


def recolor_banner(img, banner_rgb, banner_text):
    """Recolor the orange banner and replace its text, preserving the chevron
    art, glow and anti-aliased edges exactly."""
    from PIL import Image, ImageDraw, ImageFont

    img = img.convert("RGBA")
    width, height = img.size
    pixels = img.load()

    # Pass 1 -- remap orange banner pixels, keeping per-pixel intensity and
    # alpha so the anti-aliased edge survives.
    for y in range(height):
        for x in range(width):
            r, g, b, a = pixels[x, y]
            if a == 0:
                continue
            if r > 180 and g < 180 and b < 100 and r > g and r - b > 100:
                strength = min(r / 255.0, 1.0)
                pixels[x, y] = (
                    int(banner_rgb[0] * strength),
                    int(banner_rgb[1] * strength),
                    int(banner_rgb[2] * strength),
                    a,
                )

    # Pass 2 -- find the white DEV text inside the banner band, paint it out
    # with the new banner color, and draw the channel's text in its place.
    banner_y = int(height * 0.82)
    banner_h = height - banner_y

    text_pixels = [
        (x, y)
        for y in range(banner_y, height)
        for x in range(width)
        if (lambda px: px[0] > 220 and px[1] > 220 and px[2] > 220 and px[3] > 200)(
            pixels[x, y]
        )
    ]
    if not text_pixels:
        return img

    min_x = min(p[0] for p in text_pixels)
    max_x = max(p[0] for p in text_pixels)
    min_y = min(p[1] for p in text_pixels)
    max_y = max(p[1] for p in text_pixels)

    pad = max(2, int(height * 0.005))
    min_x = max(0, min_x - pad)
    max_x = min(width - 1, max_x + pad)
    min_y = max(banner_y, min_y - pad)
    max_y = min(height - 1, max_y + pad)

    draw = ImageDraw.Draw(img)
    draw.rectangle([min_x, min_y, max_x, max_y], fill=(*banner_rgb, 255))

    font_size = max(int((max_y - min_y) * 0.85), 6)
    font = None
    for font_path in (
        "/System/Library/Fonts/SFCompact-Bold.otf",
        "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
    ):
        if os.path.exists(font_path):
            try:
                font = ImageFont.truetype(font_path, font_size)
                break
            except Exception:
                continue
    if font is None:
        font = ImageFont.load_default()

    bbox = draw.textbbox((0, 0), banner_text, font=font)
    text_w = bbox[2] - bbox[0]
    text_h = bbox[3] - bbox[1]
    draw.text(
        ((width - text_w) // 2, banner_y + (banner_h - text_h) // 2 - bbox[1]),
        banner_text,
        fill=(255, 255, 255, 255),
        font=font,
    )
    return img


def main():
    require_pillow()
    from PIL import Image

    icon_set, banner_text, banner_rgb = read_channel_record(CHANNEL_RECORD)
    dst_dir = os.path.join(REPO, "Assets.xcassets", f"{icon_set}.appiconset")

    if not os.path.isdir(SRC_DIR):
        sys.stderr.write(f"error: source iconset not found: {SRC_DIR}\n")
        raise SystemExit(2)

    os.makedirs(dst_dir, exist_ok=True)
    print(f"source : {SRC_DIR}")
    print(f"target : {dst_dir}")
    print(f"banner : {banner_text} rgb{banner_rgb}\n")

    written = []
    for filename, pixel_size in SIZES:
        src_path = os.path.join(SRC_DIR, filename)
        if not os.path.exists(src_path):
            sys.stderr.write(f"error: source icon missing: {src_path}\n")
            raise SystemExit(2)

        img = Image.open(src_path)
        if img.size != (pixel_size, pixel_size):
            img = img.resize((pixel_size, pixel_size), Image.LANCZOS)

        dst_path = os.path.join(dst_dir, filename)
        recolor_banner(img, banner_rgb, banner_text).save(dst_path, "PNG")
        written.append(filename)
        print(f"  {filename} ({pixel_size}x{pixel_size})")

    # The precedent omits this and its output was hand-finished as a result.
    src_contents = os.path.join(SRC_DIR, "Contents.json")
    dst_contents = os.path.join(dst_dir, "Contents.json")
    shutil.copyfile(src_contents, dst_contents)
    print("  Contents.json (copied from source iconset)")

    # Verify rather than assume -- a partially written iconset builds into an
    # app with a missing or default icon and no error anywhere.
    missing = [name for name, _ in SIZES if not os.path.exists(os.path.join(dst_dir, name))]
    if missing or not os.path.exists(dst_contents):
        sys.stderr.write(
            "error: output incomplete after write: "
            f"{', '.join(missing + ([] if os.path.exists(dst_contents) else ['Contents.json']))}\n"
        )
        raise SystemExit(1)

    print(f"\nWrote {len(written)} icons + Contents.json to {dst_dir}")


if __name__ == "__main__":
    main()
