#!/usr/bin/env python3
"""
Export monadic_data_plane.excalidraw to a high-resolution PNG.

Renders the dark-mode diagram with Pillow, matching the neon-glow aesthetic:
  green → GPUDirect Storage paths
  cyan  → RDMA / network paths
  orange → control signals
  purple → NVLink P2P

Usage:
  python3 docs/arch/export_monadic_data_plane_png.py
"""

import json
import math
import os
import sys

from PIL import Image, ImageDraw, ImageFont

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, "..", ".."))
EXCALIDRAW_PATH = os.path.join(SCRIPT_DIR, "monadic_data_plane.excalidraw")
PNG_PATH = os.path.join(SCRIPT_DIR, "monadic_data_plane.png")

SCALE = 2  # 2× for high-resolution output
PADDING = 60  # px padding around content (before scaling)

# Fonts (fallback chain)
FONT_PATHS = [
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
]
FONT_BOLD_PATHS = [
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf",
]


def _find_font(paths):
    for p in paths:
        if os.path.exists(p):
            return p
    return None


FONT_REGULAR = _find_font(FONT_PATHS)
FONT_BOLD = _find_font(FONT_BOLD_PATHS) or FONT_REGULAR


def get_font(size, bold=False):
    path = FONT_BOLD if bold else FONT_REGULAR
    try:
        if path:
            return ImageFont.truetype(path, int(size * SCALE))
    except (OSError, IOError):
        pass
    return ImageFont.load_default()


def hex_to_rgba(hex_color, alpha=255):
    h = hex_color.lstrip("#")
    if len(h) == 6:
        return (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16), alpha)
    return (0, 0, 0, alpha)


def hex_to_rgb(hex_color):
    h = hex_color.lstrip("#")
    return (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16))


def s(v):
    return int(v * SCALE)


def sp(x, y):
    return (s(x + PADDING), s(y + PADDING))


# ─── Drawing primitives ──────────────────────────────────────────────


def draw_rect(draw, el):
    x, y, w, h = el["x"], el["y"], el["width"], el["height"]
    bg = el.get("backgroundColor", "transparent")
    stroke = el.get("strokeColor", "#e0e0e0")
    sw = el.get("strokeWidth", 2)
    style = el.get("strokeStyle", "solid")
    opacity = el.get("opacity", 100)
    radius = 0
    rn = el.get("roundness")
    if rn and isinstance(rn, dict):
        radius = min(12, w * 0.04, h * 0.08)

    x0, y0 = sp(x, y)
    x1, y1 = sp(x + w, y + h)
    r = s(radius)

    if bg and bg != "transparent":
        fill_rgb = hex_to_rgb(bg)
        alpha = int(255 * opacity / 100)
        fill_rgba = fill_rgb + (alpha,)
        if r > 0:
            draw.rounded_rectangle([x0, y0, x1, y1], radius=r, fill=fill_rgba)
        else:
            draw.rectangle([x0, y0, x1, y1], fill=fill_rgba)

    if stroke and stroke != "transparent" and sw > 0:
        stroke_rgb = hex_to_rgb(stroke)
        alpha = int(255 * min(opacity, 100) / 100)
        stroke_rgba = stroke_rgb + (alpha,)
        line_w = max(1, s(sw))

        if style == "dashed":
            _draw_dashed_rect(draw, x0, y0, x1, y1, stroke_rgba, line_w, r)
        else:
            if r > 0:
                draw.rounded_rectangle([x0, y0, x1, y1], radius=r,
                                       outline=stroke_rgba, width=line_w)
            else:
                draw.rectangle([x0, y0, x1, y1], outline=stroke_rgba, width=line_w)


def _draw_dashed_rect(draw, x0, y0, x1, y1, color, width, radius):
    dash_len = max(8, width * 4)
    gap_len = max(6, width * 3)
    edges = [
        [(x0, y0), (x1, y0)],
        [(x1, y0), (x1, y1)],
        [(x1, y1), (x0, y1)],
        [(x0, y1), (x0, y0)],
    ]
    for (sx, sy), (ex, ey) in edges:
        _draw_dashed_line(draw, sx, sy, ex, ey, color, width, dash_len, gap_len)


def _draw_dashed_line(draw, x0, y0, x1, y1, color, width, dash=12, gap=8):
    dx, dy = x1 - x0, y1 - y0
    length = math.hypot(dx, dy)
    if length < 1:
        return
    ux, uy = dx / length, dy / length
    pos = 0
    while pos < length:
        end = min(pos + dash, length)
        draw.line(
            [(x0 + ux * pos, y0 + uy * pos), (x0 + ux * end, y0 + uy * end)],
            fill=color, width=width,
        )
        pos = end + gap


def draw_line(draw, el):
    ox, oy = el["x"], el["y"]
    points = el.get("points", [])
    if len(points) < 2:
        return
    stroke = hex_to_rgb(el.get("strokeColor", "#e0e0e0"))
    sw = max(1, s(el.get("strokeWidth", 2)))
    style = el.get("strokeStyle", "solid")

    for i in range(len(points) - 1):
        px0, py0 = sp(ox + points[i][0], oy + points[i][1])
        px1, py1 = sp(ox + points[i + 1][0], oy + points[i + 1][1])
        if style == "dashed":
            _draw_dashed_line(draw, px0, py0, px1, py1, stroke, sw)
        else:
            draw.line([(px0, py0), (px1, py1)], fill=stroke, width=sw)


def draw_arrow(draw, el):
    ox, oy = el["x"], el["y"]
    points = el.get("points", [])
    if len(points) < 2:
        return

    stroke = hex_to_rgb(el.get("strokeColor", "#e0e0e0"))
    sw = max(1, s(el.get("strokeWidth", 2)))
    style = el.get("strokeStyle", "solid")

    scaled_pts = [sp(ox + p[0], oy + p[1]) for p in points]
    for i in range(len(scaled_pts) - 1):
        if style == "dashed":
            _draw_dashed_line(draw, scaled_pts[i][0], scaled_pts[i][1],
                              scaled_pts[i + 1][0], scaled_pts[i + 1][1],
                              stroke, sw, dash=s(10), gap=s(6))
        else:
            draw.line([scaled_pts[i], scaled_pts[i + 1]], fill=stroke, width=sw)

    end_head = el.get("endArrowhead", "arrow")
    if end_head == "arrow" and len(scaled_pts) >= 2:
        _draw_arrowhead(draw, scaled_pts[-2], scaled_pts[-1], stroke, sw)


def _draw_arrowhead(draw, from_pt, to_pt, color, line_width):
    dx = to_pt[0] - from_pt[0]
    dy = to_pt[1] - from_pt[1]
    length = math.hypot(dx, dy)
    if length < 1:
        return
    ux, uy = dx / length, dy / length

    head_len = max(s(12), line_width * 5)
    head_wid = max(s(8), line_width * 3)

    bx = to_pt[0] - ux * head_len
    by = to_pt[1] - uy * head_len

    px, py = -uy, ux

    p1 = (bx + px * head_wid, by + py * head_wid)
    p2 = (bx - px * head_wid, by - py * head_wid)

    draw.polygon([to_pt, p1, p2], fill=color)


def draw_text(draw, el, all_els):
    content = el.get("text", "")
    if not content:
        return

    font_size = el.get("fontSize", 20)
    color = hex_to_rgb(el.get("strokeColor", "#e0e0e0"))
    align = el.get("textAlign", "center")
    v_align = el.get("verticalAlign", "middle")
    container_id = el.get("containerId")

    bold = font_size >= 22
    font = get_font(font_size, bold=bold)

    lines = content.split("\n")

    line_heights = []
    line_widths = []
    for ln in lines:
        bbox = font.getbbox(ln)
        lw = bbox[2] - bbox[0]
        lh = bbox[3] - bbox[1]
        line_widths.append(lw)
        line_heights.append(lh)

    line_spacing = int(font_size * 0.35 * SCALE)
    total_text_h = sum(line_heights) + line_spacing * (len(lines) - 1)

    if container_id:
        container = None
        for e in all_els:
            if e.get("id") == container_id:
                container = e
                break
        if container:
            cx, cy = sp(container["x"], container["y"])
            cw, ch = s(container["width"]), s(container["height"])
        else:
            cx, cy = sp(el["x"], el["y"])
            cw, ch = s(el.get("width", 200)), s(el.get("height", 50))
    else:
        cx, cy = sp(el["x"], el["y"])
        cw = s(el.get("width", 200))
        ch = s(el.get("height", 50))

    if v_align == "top":
        text_y = cy + s(8)
    elif v_align == "middle":
        text_y = cy + (ch - total_text_h) // 2
    else:
        text_y = cy + ch - total_text_h - s(4)

    for i, ln in enumerate(lines):
        lw = line_widths[i]
        if align == "center":
            text_x = cx + (cw - lw) // 2
        elif align == "right":
            text_x = cx + cw - lw - s(4)
        else:
            text_x = cx + s(4)

        draw.text((text_x, text_y), ln, fill=color, font=font)
        text_y += line_heights[i] + line_spacing


# ─── Main ────────────────────────────────────────────────────────────


def main():
    with open(EXCALIDRAW_PATH, "r") as f:
        doc = json.load(f)

    elements = [e for e in doc["elements"] if not e.get("isDeleted", False)]

    # Get the background colour from appState
    bg_hex = doc.get("appState", {}).get("viewBackgroundColor", "#1a1a2e")
    bg_rgb = hex_to_rgb(bg_hex)

    # Compute bounding box
    positioned = [e for e in elements if e["type"] in ("rectangle", "text", "arrow", "line")]
    min_x = min(e["x"] for e in positioned)
    min_y = min(e["y"] for e in positioned)
    max_x = max(e["x"] + e.get("width", 0) for e in elements)
    max_y = max(e["y"] + e.get("height", 0) for e in elements)

    canvas_w = s(max_x - min_x + PADDING * 2 + 60)
    canvas_h = s(max_y - min_y + PADDING * 2 + 60)

    print(f"  Canvas: {canvas_w}×{canvas_h} px (scale={SCALE}×)")

    # Dark background
    img = Image.new("RGBA", (canvas_w, canvas_h), bg_rgb + (255,))
    draw = ImageDraw.Draw(img, "RGBA")

    # Render in Z-order: backgrounds → lines → rects → arrows → text
    rects = [e for e in elements if e["type"] == "rectangle"]
    lines = [e for e in elements if e["type"] == "line"]
    arrows = [e for e in elements if e["type"] == "arrow"]
    texts = [e for e in elements if e["type"] == "text"]

    rects.sort(key=lambda e: -e["width"] * e["height"])

    for el in rects:
        draw_rect(draw, el)
    for el in lines:
        draw_line(draw, el)
    for el in arrows:
        draw_arrow(draw, el)
    for el in texts:
        draw_text(draw, el, elements)

    img_rgb = img.convert("RGB")
    img_rgb.save(PNG_PATH, "PNG", dpi=(144, 144))
    file_size = os.path.getsize(PNG_PATH)
    print(f"✓ PNG exported → {os.path.relpath(PNG_PATH, REPO_ROOT)}  ({file_size:,} bytes)")
    return True


if __name__ == "__main__":
    if not os.path.exists(EXCALIDRAW_PATH):
        print(f"✗ {EXCALIDRAW_PATH} not found. Run generate_monadic_data_plane.py first.")
        sys.exit(1)
    success = main()
    sys.exit(0 if success else 1)
