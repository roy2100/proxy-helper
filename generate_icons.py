#!/usr/bin/env python3
"""Generate app icon and menu bar icon for ProxyHelper."""
from PIL import Image, ImageDraw
import os, math

ASSETS = "/Users/lielienan/Project/proxy_helper/ProxyHelper/Assets.xcassets"

# ── helpers ──────────────────────────────────────────────────────────────────

def shield_polygon(size, margin_ratio=0.13):
    s = size
    m = s * margin_ratio
    return [
        (s*0.50, m),           # top center
        (s - m,  s*0.26),      # top right
        (s - m,  s*0.56),      # right shoulder
        (s*0.50, s - m),       # bottom tip
        (m,      s*0.56),      # left shoulder
        (m,      s*0.26),      # top left
    ]

def rounded_rect(draw, box, radius, fill):
    draw.rounded_rectangle(box, radius=radius, fill=fill)

# ── App Icon ──────────────────────────────────────────────────────────────────

def create_app_icon(size):
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    # Blue rounded-square background
    r = size * 0.22
    rounded_rect(draw, [0, 0, size - 1, size - 1], r, (37, 99, 235, 255))  # blue-600

    # White shield
    pts = shield_polygon(size, 0.12)
    draw.polygon(pts, fill=(255, 255, 255, 245))

    # Blue routing arrow (→) centered inside the shield
    cx, cy = size * 0.50, size * 0.48
    aw = size * 0.17   # half arrow body length
    lw = max(2, size // 32)
    blue = (37, 99, 235, 255)

    # Horizontal body
    draw.line([(cx - aw, cy), (cx + aw * 0.6, cy)], fill=blue, width=lw)

    # Arrow head (triangle pointing right)
    tip   = (cx + aw, cy)
    head1 = (cx + aw * 0.5, cy - aw * 0.45)
    head2 = (cx + aw * 0.5, cy + aw * 0.45)
    draw.polygon([tip, head1, head2], fill=blue)

    # Small dot on the left of the arrow (source endpoint)
    dot_r = max(1, size // 24)
    draw.ellipse(
        [(cx - aw - dot_r, cy - dot_r), (cx - aw + dot_r, cy + dot_r)],
        fill=blue,
    )

    return img

# ── Menu Bar Template Icon ────────────────────────────────────────────────────

def create_menubar_icon(size):
    """Black-on-transparent template image; system handles color/inversion."""
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    pts = shield_polygon(size, 0.08)
    draw.polygon(pts, fill=(0, 0, 0, 255))

    # Cut out a right-arrow inside the shield
    cx, cy = size * 0.50, size * 0.48
    aw = size * 0.18
    lw = max(1, size // 10)
    white = (0, 0, 0, 0)   # cut-out (transparent)

    draw.line([(cx - aw, cy), (cx + aw * 0.55, cy)], fill=white, width=lw)
    tip   = (cx + aw, cy)
    head1 = (cx + aw * 0.45, cy - aw * 0.48)
    head2 = (cx + aw * 0.45, cy + aw * 0.48)
    draw.polygon([tip, head1, head2], fill=white)

    dot_r = max(1, size // 10)
    draw.ellipse(
        [(cx - aw - dot_r, cy - dot_r), (cx - aw + dot_r, cy + dot_r)],
        fill=white,
    )

    return img

# ── Menu Bar Running Icon (pre-colored green, original rendering) ─────────────

def create_menubar_icon_running(size):
    """Green-on-transparent image for the 'running' state."""
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    pts = shield_polygon(size, 0.08)
    draw.polygon(pts, fill=(34, 197, 94, 255))   # green-500

    cx, cy = size * 0.50, size * 0.48
    aw = size * 0.18
    lw = max(1, size // 10)
    cut = (0, 0, 0, 0)

    draw.line([(cx - aw, cy), (cx + aw * 0.55, cy)], fill=cut, width=lw)
    tip   = (cx + aw, cy)
    head1 = (cx + aw * 0.45, cy - aw * 0.48)
    head2 = (cx + aw * 0.45, cy + aw * 0.48)
    draw.polygon([tip, head1, head2], fill=cut)

    dot_r = max(1, size // 10)
    draw.ellipse(
        [(cx - aw - dot_r, cy - dot_r), (cx - aw + dot_r, cy + dot_r)],
        fill=cut,
    )

    return img

# ── Write files ───────────────────────────────────────────────────────────────

def main():
    # App icon – all required macOS sizes
    appiconset = os.path.join(ASSETS, "AppIcon.appiconset")
    os.makedirs(appiconset, exist_ok=True)

    sizes = [16, 32, 64, 128, 256, 512, 1024]
    for sz in sizes:
        create_app_icon(sz).save(os.path.join(appiconset, f"icon_{sz}.png"))
        print(f"  app icon {sz}×{sz}")

    # Menu bar template icon (stopped state)
    menubar_dir = os.path.join(ASSETS, "MenuBarIcon.imageset")
    os.makedirs(menubar_dir, exist_ok=True)
    create_menubar_icon(18).save(os.path.join(menubar_dir, "menubar.png"))
    create_menubar_icon(36).save(os.path.join(menubar_dir, "menubar@2x.png"))
    print("  menu bar icon (stopped) 18×18 + 36×36")

    # Menu bar running icon (pre-colored green, original rendering)
    running_dir = os.path.join(ASSETS, "MenuBarIconRunning.imageset")
    os.makedirs(running_dir, exist_ok=True)
    create_menubar_icon_running(18).save(os.path.join(running_dir, "menubar_running.png"))
    create_menubar_icon_running(36).save(os.path.join(running_dir, "menubar_running@2x.png"))
    print("  menu bar icon (running/green) 18×18 + 36×36")

if __name__ == "__main__":
    main()
