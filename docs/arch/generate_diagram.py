#!/usr/bin/env python3
"""
Generate Excalidraw diagram for the Double Trampoline I/O Interception System.

Outputs:
  docs/arch/double_trampoline.excalidraw   – raw Excalidraw JSON
  docs/arch/double_trampoline.png          – high-resolution PNG (if export tool available)

Usage:
  python3 docs/arch/generate_diagram.py
"""

import json
import os
import random
import subprocess
import sys
import time

# ---------------------------------------------------------------------------
# Output paths (relative to repo root)
# ---------------------------------------------------------------------------
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, "..", ".."))
EXCALIDRAW_PATH = os.path.join(SCRIPT_DIR, "double_trampoline.excalidraw")
PNG_PATH = os.path.join(SCRIPT_DIR, "double_trampoline.png")

# ---------------------------------------------------------------------------
# Excalidraw constants
# ---------------------------------------------------------------------------
FONT_VIRGIL = 1
FONT_HELVETICA = 2
FONT_CASCADIA = 3
ROUGHNESS_CLEAN = 0  # architect-style clean lines

# Colour palette
COL_GREEN = "#16a34a"
COL_GREEN_LIGHT = "#bbf7d0"
COL_GREEN_BG = "#f0fdf4"
COL_BLUE = "#2563eb"
COL_BLUE_LIGHT = "#bfdbfe"
COL_BLUE_BG = "#dbeafe"
COL_ORANGE = "#d97706"
COL_ORANGE_LIGHT = "#fed7aa"
COL_ORANGE_BG = "#fef3c7"
COL_GREY = "#4b5563"
COL_GREY_LIGHT = "#e5e7eb"
COL_GREY_MED = "#9ca3af"
COL_GREY_BLUE = "#6b7280"
COL_RED = "#dc2626"
COL_PINK_BG = "#fce7f3"
COL_PINK = "#be185d"
COL_DARK = "#1e1e1e"
COL_DARK_BLUE = "#1e3a5f"
COL_DARK_GREEN = "#14532d"
COL_DARK_BROWN = "#78350f"
COL_DARK_GREY = "#1f2937"
COL_MED_GREY = "#374151"
COL_DARK_PINK = "#831843"

# ---------------------------------------------------------------------------
# Element helpers
# ---------------------------------------------------------------------------
_rng = random.Random(42)  # deterministic for reproducible output


def _uid() -> str:
    chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
    return "".join(_rng.choice(chars) for _ in range(12))


def _seed() -> int:
    return _rng.randint(100_000, 999_999_999)


_NOW = int(time.time() * 1000)


def _base(**kw):
    """Return a base Excalidraw element dict with sane defaults."""
    d = {
        "id": _uid(),
        "type": "rectangle",
        "fillStyle": "solid",
        "strokeWidth": 2,
        "strokeStyle": "solid",
        "roughness": ROUGHNESS_CLEAN,
        "opacity": 100,
        "angle": 0,
        "x": 0,
        "y": 0,
        "width": 100,
        "height": 50,
        "strokeColor": COL_DARK,
        "backgroundColor": "transparent",
        "seed": _seed(),
        "groupIds": [],
        "frameId": None,
        "roundness": None,
        "boundElements": [],
        "updated": _NOW,
        "link": None,
        "locked": False,
        "version": 1,
        "versionNonce": _seed(),
        "isDeleted": False,
    }
    d.update(kw)
    return d


def make_rect(x, y, w, h, *, fill="transparent", stroke=COL_DARK,
              stroke_width=2, stroke_style="solid", roundness=3, opacity=100):
    return _base(
        type="rectangle", x=x, y=y, width=w, height=h,
        backgroundColor=fill, strokeColor=stroke,
        strokeWidth=stroke_width, strokeStyle=stroke_style,
        opacity=opacity,
        roundness={"type": roundness} if roundness else None,
    )


def make_text(x, y, content, *, font_size=20, font_family=FONT_HELVETICA,
              color=COL_DARK, align="center", v_align="middle",
              container_id=None, width=None, height=None):
    if width is None:
        longest_line = max(content.split("\n"), key=len)
        width = len(longest_line) * font_size * 0.58
    n_lines = content.count("\n") + 1
    if height is None:
        height = font_size * 1.25 * n_lines
    return _base(
        type="text", x=x, y=y, width=width, height=height,
        text=content, fontSize=font_size, fontFamily=font_family,
        textAlign=align, verticalAlign=v_align,
        strokeColor=color, backgroundColor="transparent",
        containerId=container_id,
        originalText=content,
        autoResize=True,
        lineHeight=1.25,
        roundness=None,
    )


def make_arrow(x, y, points, *, color=COL_DARK, stroke_width=2,
               stroke_style="solid", end_arrowhead="arrow"):
    dx = max(abs(p[0]) for p in points) if points else 0
    dy = max(abs(p[1]) for p in points) if points else 0
    return _base(
        type="arrow", x=x, y=y, width=dx, height=dy,
        points=points, strokeColor=color,
        strokeWidth=stroke_width, strokeStyle=stroke_style,
        startArrowhead=None, endArrowhead=end_arrowhead,
        startBinding=None, endBinding=None,
        lastCommittedPoint=None,
        roundness={"type": 2},
    )


def make_line(x, y, points, *, color=COL_DARK, stroke_width=2,
              stroke_style="solid"):
    return _base(
        type="line", x=x, y=y,
        width=abs(points[-1][0] - points[0][0]),
        height=abs(points[-1][1] - points[0][1]),
        points=points, strokeColor=color,
        strokeWidth=stroke_width, strokeStyle=stroke_style,
        startBinding=None, endBinding=None,
        lastCommittedPoint=None,
    )


def bind_text_to_rect(rect_el, text_el):
    """Set up the bidirectional binding between a rect and its label."""
    text_el["containerId"] = rect_el["id"]
    rect_el["boundElements"] = [{"id": text_el["id"], "type": "text"}]


# ---------------------------------------------------------------------------
# Build the diagram
# ---------------------------------------------------------------------------
elements: list[dict] = []

# ===== Background regions =====

# User-Space background (light blue wash)
elements.append(make_rect(40, 210, 1620, 430,
                          fill=COL_BLUE_BG, stroke="#93c5fd",
                          stroke_width=1, opacity=40))

# Kernel-Space background (light grey wash)
elements.append(make_rect(40, 670, 1620, 260,
                          fill=COL_GREY_LIGHT, stroke=COL_GREY_MED,
                          stroke_width=1, opacity=40))

# ===== Layer titles =====

elements.append(make_text(640, 8, "Application Layer",
                          font_size=28, color=COL_MED_GREY, width=320, height=38))
elements.append(make_text(55, 218, "USER SPACE",
                          font_size=14, color=COL_BLUE, align="left",
                          width=120, height=20))
elements.append(make_text(55, 678, "KERNEL SPACE",
                          font_size=14, color=COL_GREY_BLUE, align="left",
                          width=140, height=20))
elements.append(make_text(700, 942, "Hardware Layer",
                          font_size=24, color=COL_MED_GREY, width=240, height=32))

# ===== Dashed separator (User ↔ Kernel boundary) =====
elements.append(make_line(40, 660, [[0, 0], [1620, 0]],
                          color=COL_GREY_BLUE, stroke_width=2,
                          stroke_style="dashed"))

# ===== Application Layer boxes =====

# Box A: PostgreSQL (High Performance Path)
pg_r = make_rect(150, 55, 450, 100,
                 fill=COL_GREEN_BG, stroke=COL_GREEN)
pg_t = make_text(0, 0, "PostgreSQL\n(Dynamic Binary - High Performance Path)",
                 font_size=18, color=COL_DARK_GREEN)
bind_text_to_rect(pg_r, pg_t)
elements += [pg_r, pg_t]

# Box B: Python / Pandas (Legacy Path)
python_r = make_rect(1050, 55, 470, 100,
                     fill=COL_ORANGE_BG, stroke=COL_ORANGE)
python_t = make_text(0, 0, "Python / Pandas\n(Static Runtime / Legacy CLI Tools)",
                     font_size=18, color=COL_DARK_BROWN)
bind_text_to_rect(python_r, python_t)
elements += [python_r, python_t]

# ===== User-Space components =====

# Trampoline 1: LD_PRELOAD Shim
ldp_r = make_rect(185, 270, 310, 78,
                  fill=COL_GREEN_LIGHT, stroke=COL_GREEN)
ldp_t = make_text(0, 0, "Trampoline 1:\nLD_PRELOAD Shim",
                  font_size=16, color=COL_DARK_GREEN)
bind_text_to_rect(ldp_r, ldp_t)
elements += [ldp_r, ldp_t]

# dataplane-emu (Storage Engine) – large central box
engine_r = make_rect(540, 360, 640, 270,
                     fill=COL_GREEN_BG, stroke=COL_GREEN, stroke_width=3)
engine_t = make_text(0, 0, "dataplane-emu  (Storage Engine)",
                     font_size=22, color=COL_DARK_GREEN, v_align="top")
bind_text_to_rect(engine_r, engine_t)
elements += [engine_r, engine_t]

# Lock-Free MPSC Queues (sub-component inside engine)
mpsc_r = make_rect(640, 460, 290, 95,
                   fill=COL_GREEN_LIGHT, stroke="#15803d")
mpsc_t = make_text(0, 0, "Lock-Free\nMPSC Queues",
                   font_size=17, color=COL_DARK_GREEN)
bind_text_to_rect(mpsc_r, mpsc_t)
elements += [mpsc_r, mpsc_t]

# ===== Kernel-Space components =====

# Linux VFS Layer (wide horizontal bar)
vfs_r = make_rect(140, 720, 1420, 55,
                  fill=COL_GREY_LIGHT, stroke=COL_GREY)
vfs_t = make_text(0, 0, "Linux VFS Layer",
                  font_size=18, color=COL_DARK_GREY)
bind_text_to_rect(vfs_r, vfs_t)
elements += [vfs_r, vfs_t]

# Trampoline 2: Custom VFS Module
vfsm_r = make_rect(1120, 810, 360, 78,
                   fill=COL_ORANGE_LIGHT, stroke=COL_ORANGE)
vfsm_t = make_text(0, 0, "Trampoline 2:\nCustom VFS Module",
                   font_size=16, color=COL_DARK_BROWN)
bind_text_to_rect(vfsm_r, vfsm_t)
elements += [vfsm_r, vfsm_t]

# ===== Hardware Layer =====

nvme_r = make_rect(430, 990, 860, 80,
                   fill=COL_PINK_BG, stroke=COL_PINK)
nvme_t = make_text(0, 0, "NVMe Flash Storage",
                   font_size=20, color=COL_DARK_PINK)
bind_text_to_rect(nvme_r, nvme_t)
elements += [nvme_r, nvme_t]

# ===================================================================
# Routing Arrows
# ===================================================================

# Anchor calculations (center-x, bottom-y / top-y of each box)
pg_cx = 150 + 225      # 375 (PostgreSQL now on left)
pg_bot = 155
python_cx = 1050 + 235 # 1285 (Python now on right)
python_bot = 155
ldp_cx = 185 + 155     # 340
ldp_top = 270
ldp_bot = 348
mpsc_cx = 640 + 145    # 785
mpsc_top = 460
mpsc_right_x = 930
mpsc_cy = 507
vfs_top_y = 720
vfsm_cx = 1120 + 180   # 1300
vfsm_top = 810
vfsm_left_x = 1120
vfsm_cy = 849
engine_bot_cx = 540 + 320  # 860
engine_bot_y = 630
nvme_top_cx = 430 + 430    # 860
nvme_top_y = 990

# --- 1) Fast Path: PostgreSQL → LD_PRELOAD (green, bold) ---
elements.append(make_arrow(
    pg_cx, pg_bot + 3,
    [[0, 0], [ldp_cx - pg_cx, ldp_top - pg_bot - 6]],
    color=COL_GREEN, stroke_width=4,
))

# --- 2) Fast Path: LD_PRELOAD → MPSC Queues (green, bold) ---
elements.append(make_arrow(
    ldp_cx, ldp_bot + 3,
    [[0, 0], [mpsc_cx - ldp_cx, mpsc_top - ldp_bot - 6]],
    color=COL_GREEN, stroke_width=4,
))

# Label: "Zero-Syscall Fast Path"
elements.append(make_text(
    410, 373, "Zero-Syscall\nFast Path",
    font_size=15, color=COL_GREEN, align="left",
    width=160, height=38,
))

# --- 3) Universal Path: Python → Linux VFS (orange, bold) ---
elements.append(make_arrow(
    python_cx, python_bot + 3,
    [[0, 0], [0, vfs_top_y - python_bot - 6]],
    color=COL_ORANGE, stroke_width=4,
))

# --- 4) VFS → Custom VFS Module (orange, bold) ---
elements.append(make_arrow(
    vfsm_cx, 778,
    [[0, 0], [0, vfsm_top - 778 - 3]],
    color=COL_ORANGE, stroke_width=3,
))

# --- 5) Bridge: Custom VFS Module → MPSC Queues (dashed orange) ---
elements.append(make_arrow(
    vfsm_left_x - 3, vfsm_cy,
    [[0, 0], [-80, -30], [mpsc_right_x - vfsm_left_x + 6, mpsc_cy - vfsm_cy]],
    color=COL_ORANGE, stroke_width=3, stroke_style="dashed",
))

# Label: "Universal Compatibility Fallback"
elements.append(make_text(
    942, 670, "Universal\nCompatibility\nFallback",
    font_size=15, color=COL_ORANGE, align="left",
    width=130, height=55,
))

# --- 6) Execution Path: Engine → NVMe (black, bold) ---
elements.append(make_arrow(
    engine_bot_cx, engine_bot_y + 5,
    [[0, 0], [nvme_top_cx - engine_bot_cx, nvme_top_y - engine_bot_y - 10]],
    color=COL_DARK, stroke_width=4,
))

# Label: "SPDK / PCIe"
elements.append(make_text(
    875, 840, "SPDK / PCIe",
    font_size=16, color=COL_DARK, align="left",
    width=130, height=22,
))

# ===== Convergence highlight =====
# Dashed red border around MPSC to emphasise that both paths land here
elements.append(make_rect(
    630, 450, 310, 115,
    fill="transparent", stroke=COL_RED,
    stroke_width=2, stroke_style="dashed", opacity=55,
))
elements.append(make_text(
    640, 569, "▲ Both trampolines converge here",
    font_size=12, color=COL_RED, align="left",
    width=260, height=17,
))

# ===================================================================
# Assemble Excalidraw document
# ===================================================================
document = {
    "type": "excalidraw",
    "version": 2,
    "source": "dataplane-emu-generator",
    "elements": elements,
    "appState": {
        "gridSize": None,
        "viewBackgroundColor": "#ffffff",
    },
    "files": {},
}

os.makedirs(os.path.dirname(EXCALIDRAW_PATH), exist_ok=True)
with open(EXCALIDRAW_PATH, "w") as f:
    json.dump(document, f, indent=2)

print(f"✓ Excalidraw diagram saved → {os.path.relpath(EXCALIDRAW_PATH, REPO_ROOT)}")
print(f"  {len(elements)} elements generated")

# ---------------------------------------------------------------------------
# PNG export (best-effort)
# ---------------------------------------------------------------------------


def try_png_export():
    """Attempt PNG export using @excalidraw/cli or kroki.io fallback."""

    # Strategy 1: local npx @excalidraw/cli (if node available)
    try:
        r = subprocess.run(
            ["npx", "--yes", "@excalidraw/cli", "export",
             "--format", "png", "--scale", "2",
             "--output", PNG_PATH, EXCALIDRAW_PATH],
            capture_output=True, text=True, timeout=120,
        )
        if r.returncode == 0 and os.path.exists(PNG_PATH):
            print(f"✓ PNG exported → {os.path.relpath(PNG_PATH, REPO_ROOT)}")
            return True
        print(f"  npx @excalidraw/cli failed (rc={r.returncode}): {r.stderr.strip()}")
    except FileNotFoundError:
        print("  npx not found – skipping @excalidraw/cli")
    except subprocess.TimeoutExpired:
        print("  npx timed out")
    except Exception as e:
        print(f"  npx error: {e}")

    # Strategy 2: try excalidraw_export Python package
    try:
        from excalidraw_export import export_png  # type: ignore
        export_png(EXCALIDRAW_PATH, PNG_PATH, scale=2)
        if os.path.exists(PNG_PATH):
            print(f"✓ PNG exported via excalidraw_export → {os.path.relpath(PNG_PATH, REPO_ROOT)}")
            return True
    except ImportError:
        pass
    except Exception as e:
        print(f"  excalidraw_export error: {e}")

    # Strategy 3: kroki.io HTTP API
    try:
        import urllib.request
        import base64
        import zlib

        with open(EXCALIDRAW_PATH, "rb") as fh:
            raw = fh.read()
        compressed = zlib.compress(raw, 9)
        encoded = base64.urlsafe_b64encode(compressed).decode("ascii")

        url = f"https://kroki.io/excalidraw/png/{encoded}"
        if len(url) < 65_000:
            req = urllib.request.Request(url)
            with urllib.request.urlopen(req, timeout=30) as resp:
                png_data = resp.read()
            with open(PNG_PATH, "wb") as out:
                out.write(png_data)
            print(f"✓ PNG exported via kroki.io → {os.path.relpath(PNG_PATH, REPO_ROOT)}")
            return True
        else:
            # Use POST for large payloads
            post_data = json.dumps({
                "diagram_source": raw.decode("utf-8"),
                "diagram_type": "excalidraw",
                "output_format": "png",
            }).encode("utf-8")
            req = urllib.request.Request(
                "https://kroki.io/",
                data=post_data,
                headers={"Content-Type": "application/json"},
            )
            with urllib.request.urlopen(req, timeout=30) as resp:
                png_data = resp.read()
            with open(PNG_PATH, "wb") as out:
                out.write(png_data)
            print(f"✓ PNG exported via kroki.io POST → {os.path.relpath(PNG_PATH, REPO_ROOT)}")
            return True
    except Exception as e:
        print(f"  kroki.io error: {e}")

    print("⚠ PNG export not available. Open the .excalidraw file in VS Code")
    print("  (with the Excalidraw extension) and export manually, or install Node.js")
    print("  and run:  npx @excalidraw/cli export --format png --scale 2 \\")
    print(f"            --output {os.path.relpath(PNG_PATH, REPO_ROOT)} "
          f"{os.path.relpath(EXCALIDRAW_PATH, REPO_ROOT)}")
    return False


try_png_export()
