#!/usr/bin/env python3
"""
Generate the 'Monadic Data Plane: Zero-Host-CPU Orchestration' Excalidraw diagram.

Illustrates complete elimination of the Host CPU from the active data path,
showing GPUDirect Storage, DPDK gpudev, BlueField SNAP, and RDMA fabric paths.

Outputs:
  docs/arch/monadic_data_plane.excalidraw   – raw Excalidraw JSON
  docs/arch/monadic_data_plane.png          – high-resolution PNG (Pillow renderer)

Usage:
  python3 docs/arch/generate_monadic_data_plane.py
"""

import json
import os
import random
import time

# ---------------------------------------------------------------------------
# Output paths
# ---------------------------------------------------------------------------
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, "..", ".."))
EXCALIDRAW_PATH = os.path.join(SCRIPT_DIR, "monadic_data_plane.excalidraw")
PNG_PATH = os.path.join(SCRIPT_DIR, "monadic_data_plane.png")

# ---------------------------------------------------------------------------
# Excalidraw constants
# ---------------------------------------------------------------------------
FONT_VIRGIL = 1
FONT_HELVETICA = 2
FONT_CASCADIA = 3
ROUGHNESS_CLEAN = 0

# Dark-mode colour palette
COL_BG = "#1a1a2e"  # dark navy background
COL_BG_ZONE_HOST = "#2a2a3e"  # slightly lighter for host zone
COL_BG_ZONE_ACCEL = "#1e2a3a"  # dark teal for accelerator zone
COL_BG_ZONE_STORAGE = "#1e1e30"  # deep purple-navy for storage zone

COL_GREEN_GLOW = "#39ff14"  # neon green (storage paths)
COL_GREEN_DIM = "#1b5e20"
COL_GREEN_FILL = "#0a2e0a"
COL_CYAN_GLOW = "#00e5ff"  # cyan (network paths)
COL_CYAN_DIM = "#006064"
COL_CYAN_FILL = "#0a1e2e"
COL_ORANGE_GLOW = "#ff9100"  # orange (control signals)
COL_ORANGE_DIM = "#bf6900"
COL_ORANGE_FILL = "#2e1a00"
COL_WHITE = "#e0e0e0"
COL_WHITE_DIM = "#9e9e9e"
COL_FADED = "#555570"  # faded/bypassed elements
COL_FADED_FILL = "#22223a"
COL_RED_DIM = "#ff1744"
COL_YELLOW = "#ffd600"
COL_ZONE_STROKE = "#444466"
COL_TITLE = "#b0b0d0"
COL_NVLINK = "#c158dc"  # purple for NVLink

# ---------------------------------------------------------------------------
# Element helpers (same pattern as generate_diagram.py)
# ---------------------------------------------------------------------------
_rng = random.Random(77)  # deterministic


def _uid() -> str:
    chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
    return "".join(_rng.choice(chars) for _ in range(12))


def _seed() -> int:
    return _rng.randint(100_000, 999_999_999)


_NOW = int(time.time() * 1000)


def _base(**kw):
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
        "strokeColor": COL_WHITE,
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


def make_rect(x, y, w, h, *, fill="transparent", stroke=COL_WHITE,
              stroke_width=2, stroke_style="solid", roundness=3, opacity=100):
    return _base(
        type="rectangle", x=x, y=y, width=w, height=h,
        backgroundColor=fill, strokeColor=stroke,
        strokeWidth=stroke_width, strokeStyle=stroke_style,
        opacity=opacity,
        roundness={"type": roundness} if roundness else None,
    )


def make_text(x, y, content, *, font_size=20, font_family=FONT_HELVETICA,
              color=COL_WHITE, align="center", v_align="middle",
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


def make_arrow(x, y, points, *, color=COL_WHITE, stroke_width=2,
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


def make_line(x, y, points, *, color=COL_WHITE, stroke_width=2,
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
    text_el["containerId"] = rect_el["id"]
    rect_el["boundElements"] = [{"id": text_el["id"], "type": "text"}]


# ---------------------------------------------------------------------------
# Build the diagram
# ---------------------------------------------------------------------------
elements: list[dict] = []

# Canvas dimensions – three horizontal zones stacked vertically
# Zone 1: Host / Control Plane    y: 0 .. 280
# Zone 2: Peripheral Domain       y: 310 .. 780
# Zone 3: Storage & Fabric        y: 810 .. 1050
CANVAS_W = 1700
ZONE_PAD = 30

# ───────────────────────────────────────────────────────────────────────────
# TITLE
# ───────────────────────────────────────────────────────────────────────────
elements.append(make_text(
    250, 20, "Monadic Data Plane: Zero-Host-CPU Orchestration",
    font_size=34, color=COL_TITLE, width=1200, height=46,
))

# ───────────────────────────────────────────────────────────────────────────
# ZONE 1: HOST / CONTROL PLANE   (y: 80 .. 290)
# ───────────────────────────────────────────────────────────────────────────
z1_y = 80
z1_h = 210

z1_bg = make_rect(ZONE_PAD, z1_y, CANVAS_W - 2 * ZONE_PAD, z1_h,
                  fill=COL_BG_ZONE_HOST, stroke=COL_ZONE_STROKE,
                  stroke_width=1, opacity=80)
elements.append(z1_bg)

# Zone label
elements.append(make_text(
    50, z1_y + 5, "CONTROL PLANE  (Host)",
    font_size=14, color=COL_ORANGE_DIM, align="left", width=220, height=20,
))

# Host CPU box
host_x, host_y = 100, z1_y + 45
host_w, host_h = 380, 140
host_r = make_rect(host_x, host_y, host_w, host_h,
                   fill=COL_ORANGE_FILL, stroke=COL_ORANGE_GLOW,
                   stroke_width=2, opacity=90)
host_t = make_text(0, 0, "Host CPU\nConfiguration Agent Only",
                   font_size=18, color=COL_ORANGE_GLOW)
bind_text_to_rect(host_r, host_t)
elements += [host_r, host_t]

# C++23 Monadic Control Plane sub-box inside Host CPU
mono_x, mono_y = host_x + 60, host_y + 85
mono_w, mono_h = 260, 42
mono_r = make_rect(mono_x, mono_y, mono_w, mono_h,
                   fill="#2e1a00", stroke=COL_ORANGE_DIM,
                   stroke_width=1, opacity=85)
mono_t = make_text(0, 0, "C++23 Monadic Control Plane",
                   font_size=13, color=COL_ORANGE_GLOW)
bind_text_to_rect(mono_r, mono_t)
elements += [mono_r, mono_t]

# System RAM – faded/bypassed box
ram_x, ram_y = 580, z1_y + 60
ram_w, ram_h = 280, 100
ram_r = make_rect(ram_x, ram_y, ram_w, ram_h,
                  fill=COL_FADED_FILL, stroke=COL_FADED,
                  stroke_width=2, stroke_style="dashed", opacity=50)
ram_t = make_text(0, 0, "System RAM\nBypassed (Zero-CPU Tax)",
                  font_size=16, color=COL_FADED)
bind_text_to_rect(ram_r, ram_t)
elements += [ram_r, ram_t]

# Big red X over System RAM
elements.append(make_line(ram_x + 20, ram_y + 15,
                          [[0, 0], [ram_w - 40, ram_h - 30]],
                          color=COL_RED_DIM, stroke_width=3))
elements.append(make_line(ram_x + 20, ram_y + ram_h - 15,
                          [[0, 0], [ram_w - 40, -(ram_h - 30)]],
                          color=COL_RED_DIM, stroke_width=3))

# "NO DATA PATH" annotation near RAM
elements.append(make_text(
    ram_x + ram_w + 20, ram_y + 30,
    "✗ No data arrows\n   pass through here",
    font_size=13, color=COL_RED_DIM, align="left", width=200, height=36,
))

# ───────────────────────────────────────────────────────────────────────────
# ZONE 2: PERIPHERAL DOMAIN  (DPU / GPU)   (y: 320 .. 780)
# ───────────────────────────────────────────────────────────────────────────
z2_y = 320
z2_h = 460

z2_bg = make_rect(ZONE_PAD, z2_y, CANVAS_W - 2 * ZONE_PAD, z2_h,
                  fill=COL_BG_ZONE_ACCEL, stroke=COL_ZONE_STROKE,
                  stroke_width=1, opacity=80)
elements.append(z2_bg)

elements.append(make_text(
    50, z2_y + 5, "PERIPHERAL DOMAIN  (Accelerator Cluster)",
    font_size=14, color=COL_CYAN_DIM, align="left", width=380, height=20,
))

# ── NVIDIA GPU box ──
gpu_x, gpu_y = 100, z2_y + 50
gpu_w, gpu_h = 550, 380
gpu_r = make_rect(gpu_x, gpu_y, gpu_w, gpu_h,
                  fill="#0a2020", stroke=COL_GREEN_GLOW,
                  stroke_width=3, opacity=90)
gpu_t = make_text(0, 0, "NVIDIA GPU",
                  font_size=24, color=COL_GREEN_GLOW, v_align="top")
bind_text_to_rect(gpu_r, gpu_t)
elements += [gpu_r, gpu_t]

# VRAM sub-box
vram_x, vram_y = gpu_x + 40, gpu_y + 70
vram_w, vram_h = 460, 130
vram_r = make_rect(vram_x, vram_y, vram_w, vram_h,
                   fill=COL_GREEN_FILL, stroke=COL_GREEN_GLOW,
                   stroke_width=2, opacity=80)
vram_t = make_text(0, 0, "VRAM  (HBM3e)\nGPUDirect Target Buffer",
                   font_size=17, color=COL_GREEN_GLOW)
bind_text_to_rect(vram_r, vram_t)
elements += [vram_r, vram_t]

# BAR1 Aperture sub-box
bar1_x, bar1_y = gpu_x + 40, gpu_y + 220
bar1_w, bar1_h = 460, 60
bar1_r = make_rect(bar1_x, bar1_y, bar1_w, bar1_h,
                   fill="#0e1e0e", stroke="#2e7d32",
                   stroke_width=1, opacity=75)
bar1_t = make_text(0, 0, "BAR1 Aperture  (PCIe MMIO)",
                   font_size=14, color="#66bb6a")
bind_text_to_rect(bar1_r, bar1_t)
elements += [bar1_r, bar1_t]

# GPU Compute Engines sub-box
compute_x, compute_y = gpu_x + 40, gpu_y + 300
compute_w, compute_h = 460, 55
compute_r = make_rect(compute_x, compute_y, compute_w, compute_h,
                      fill="#0e1e0e", stroke="#2e7d32",
                      stroke_width=1, opacity=75)
compute_t = make_text(0, 0, "SM Clusters  (Tensor Cores / CUDA Cores)",
                      font_size=13, color="#66bb6a")
bind_text_to_rect(compute_r, compute_t)
elements += [compute_r, compute_t]

# ── NVIDIA BlueField-3 DPU box ──
dpu_x, dpu_y = 750, z2_y + 50
dpu_w, dpu_h = 580, 380
dpu_r = make_rect(dpu_x, dpu_y, dpu_w, dpu_h,
                  fill="#0a1a2e", stroke=COL_CYAN_GLOW,
                  stroke_width=3, opacity=90)
dpu_t = make_text(0, 0, "NVIDIA BlueField-3 DPU",
                  font_size=22, color=COL_CYAN_GLOW, v_align="top")
bind_text_to_rect(dpu_r, dpu_t)
elements += [dpu_r, dpu_t]

# SNAP sub-box
snap_x, snap_y = dpu_x + 30, dpu_y + 65
snap_w, snap_h = 240, 90
snap_r = make_rect(snap_x, snap_y, snap_w, snap_h,
                   fill=COL_GREEN_FILL, stroke=COL_GREEN_GLOW,
                   stroke_width=2, opacity=80)
snap_t = make_text(0, 0, "SNAP\n(NVMe Emulation)",
                   font_size=16, color=COL_GREEN_GLOW)
bind_text_to_rect(snap_r, snap_t)
elements += [snap_r, snap_t]

# DPDK gpudev sub-box
dpdk_x, dpdk_y = dpu_x + 300, dpu_y + 65
dpdk_w, dpdk_h = 250, 90
dpdk_r = make_rect(dpdk_x, dpdk_y, dpdk_w, dpdk_h,
                   fill=COL_CYAN_FILL, stroke=COL_CYAN_GLOW,
                   stroke_width=2, opacity=80)
dpdk_t = make_text(0, 0, "DPDK gpudev\n(Packet → GPU DMA)",
                   font_size=15, color=COL_CYAN_GLOW)
bind_text_to_rect(dpdk_r, dpdk_t)
elements += [dpdk_r, dpdk_t]

# Libfabric (OFI) sub-box
fab_x, fab_y = dpu_x + 30, dpu_y + 180
fab_w, fab_h = 520, 80
fab_r = make_rect(fab_x, fab_y, fab_w, fab_h,
                  fill=COL_CYAN_FILL, stroke=COL_CYAN_GLOW,
                  stroke_width=2, opacity=80)
fab_t = make_text(0, 0, "Libfabric (OFI)\nRDMA/RoCEv2 Verbs  ·  One-Sided WRITE/READ",
                  font_size=14, color=COL_CYAN_GLOW)
bind_text_to_rect(fab_r, fab_t)
elements += [fab_r, fab_t]

# DPU ARM Cores sub-box
arm_x, arm_y = dpu_x + 30, dpu_y + 285
arm_w, arm_h = 520, 65
arm_r = make_rect(arm_x, arm_y, arm_w, arm_h,
                  fill="#0a1520", stroke="#0097a7",
                  stroke_width=1, opacity=70)
arm_t = make_text(0, 0, "16× Arm A78 Cores  (ConnectX-7 Steering Engine)",
                  font_size=13, color="#4dd0e1")
bind_text_to_rect(arm_r, arm_t)
elements += [arm_r, arm_t]

# ───────────────────────────────────────────────────────────────────────────
# ZONE 3: STORAGE & FABRIC   (y: 810 .. 1060)
# ───────────────────────────────────────────────────────────────────────────
z3_y = 810
z3_h = 250

z3_bg = make_rect(ZONE_PAD, z3_y, CANVAS_W - 2 * ZONE_PAD, z3_h,
                  fill=COL_BG_ZONE_STORAGE, stroke=COL_ZONE_STROKE,
                  stroke_width=1, opacity=80)
elements.append(z3_bg)

elements.append(make_text(
    50, z3_y + 5, "STORAGE & FABRIC",
    font_size=14, color=COL_FADED, align="left", width=200, height=20,
))

# Local NVMe SSDs
nvme_x, nvme_y = 120, z3_y + 60
nvme_w, nvme_h = 480, 140
nvme_r = make_rect(nvme_x, nvme_y, nvme_w, nvme_h,
                   fill=COL_GREEN_FILL, stroke=COL_GREEN_GLOW,
                   stroke_width=2, opacity=85)
nvme_t = make_text(0, 0, "Local NVMe SSDs\nPCIe Gen5 × 4  ·  SPDK User-Space Driver",
                   font_size=17, color=COL_GREEN_GLOW)
bind_text_to_rect(nvme_r, nvme_t)
elements += [nvme_r, nvme_t]

# Scale-out Network Fabric
net_x, net_y = 750, z3_y + 60
net_w, net_h = 580, 140
net_r = make_rect(net_x, net_y, net_w, net_h,
                  fill=COL_CYAN_FILL, stroke=COL_CYAN_GLOW,
                  stroke_width=2, opacity=85)
net_t = make_text(0, 0, "Scale-Out Network Fabric\n400 GbE InfiniBand / RoCEv2",
                  font_size=17, color=COL_CYAN_GLOW)
bind_text_to_rect(net_r, net_t)
elements += [net_r, net_t]


# ═══════════════════════════════════════════════════════════════════════════
# DATA FLOW ARROWS
# ═══════════════════════════════════════════════════════════════════════════

# ── 1) GPUDirect Storage (Zero-Copy): NVMe → SNAP → GPU VRAM ──
#    Thick green arrow:  NVMe SSD top → SNAP bottom → VRAM bottom

# Segment A:  NVMe top-center → SNAP bottom-center (going up)
nvme_tcx = nvme_x + nvme_w // 2  # 360
nvme_top = nvme_y                 # 870
snap_bcx = snap_x + snap_w // 2  # 870 + 120 = 900
snap_bot = snap_y + snap_h       # 435 + 90 = 525

elements.append(make_arrow(
    nvme_tcx, nvme_top,
    [[0, 0], [snap_bcx - nvme_tcx, snap_bot - nvme_top]],
    color=COL_GREEN_GLOW, stroke_width=5,
))

# Segment B:  SNAP left-center → VRAM right-center (going left into GPU)
snap_lcx = snap_x                # 780
snap_mcy = snap_y + snap_h // 2  # 435 + 45 = 480
vram_rcx = vram_x + vram_w      # 140 + 460 = 600
vram_mcy = vram_y + vram_h // 2  # 440 + 65 = 505

elements.append(make_arrow(
    snap_lcx, snap_mcy,
    [[0, 0], [vram_rcx - snap_lcx, vram_mcy - snap_mcy]],
    color=COL_GREEN_GLOW, stroke_width=5,
))

# Label for GPUDirect Storage path
elements.append(make_text(
    170, z3_y - 30,
    "GPUDirect Storage (Zero-Copy)",
    font_size=16, color=COL_GREEN_GLOW, align="left",
    width=340, height=22,
))

# Small annotation arrow pointing to the green path
elements.append(make_text(
    nvme_tcx - 40, nvme_top - 28,
    "▲ GDS Fast Path",
    font_size=12, color=COL_GREEN_GLOW, align="left",
    width=140, height=17,
))


# ── 2) GPUDirect RDMA: Network Fabric → Libfabric/DPU → GPU VRAM ──
#    Thick cyan arrow

# Segment A: Network top → Libfabric bottom
net_tcx = net_x + net_w // 2   # 1040
net_top = net_y                 # 870
fab_bcx = fab_x + fab_w // 2   # 810 + 260 = 1070 (approx center)
fab_bot = fab_y + fab_h        # 500 + 80 = 580

elements.append(make_arrow(
    net_tcx, net_top,
    [[0, 0], [fab_bcx - net_tcx, fab_bot - net_top]],
    color=COL_CYAN_GLOW, stroke_width=5,
))

# Segment B: Libfabric left → VRAM right (into GPU)
fab_lcx = fab_x               # 780
fab_mcy = fab_y + fab_h // 2  # 540

elements.append(make_arrow(
    fab_lcx, fab_mcy,
    [[0, 0], [vram_rcx - fab_lcx, vram_mcy - fab_mcy]],
    color=COL_CYAN_GLOW, stroke_width=5,
))

# Label for RDMA path
elements.append(make_text(
    net_x + 10, net_top - 28,
    "GPUDirect RDMA",
    font_size=16, color=COL_CYAN_GLOW, align="left",
    width=200, height=22,
))


# ── 3) Inter-Node Path: NVLink P2P between GPUs ──
# Arrow across the top of the GPU box to indicate GPU-to-GPU link
nvlink_y = gpu_y + 15
elements.append(make_arrow(
    gpu_x + gpu_w - 30, nvlink_y,
    [[0, 0], [100, 0]],
    color=COL_NVLINK, stroke_width=4,
))
# Bidirectional – add reverse arrow
elements.append(make_arrow(
    gpu_x + gpu_w + 70, nvlink_y + 18,
    [[0, 0], [-100, 0]],
    color=COL_NVLINK, stroke_width=4,
))

elements.append(make_text(
    gpu_x + gpu_w - 40, nvlink_y + 28,
    "NVLink / Sub-µs P2P",
    font_size=13, color=COL_NVLINK, align="center",
    width=180, height=18,
))


# ── 4) Control Logic: Host CPU → DPU/GPU (dashed orange) ──
# Host CPU right edge → DPU top-left area
host_rcx = host_x + host_w      # 480
host_mcy = host_y + host_h // 2  # 195

# Arrow to DPU
dpu_top_lcx = dpu_x + 100       # 850
dpu_top_y = dpu_y               # 370

elements.append(make_arrow(
    host_rcx + 5, host_mcy,
    [[0, 0], [dpu_top_lcx - host_rcx - 5, dpu_top_y - host_mcy]],
    color=COL_ORANGE_GLOW, stroke_width=3, stroke_style="dashed",
))

# Arrow to GPU
gpu_top_rcx = gpu_x + gpu_w - 100  # 550
gpu_top_y = gpu_y                    # 370

elements.append(make_arrow(
    host_rcx + 5, host_mcy + 20,
    [[0, 0], [gpu_top_rcx - host_rcx - 5, gpu_top_y - host_mcy - 20]],
    color=COL_ORANGE_GLOW, stroke_width=3, stroke_style="dashed",
))

# Label for control path
elements.append(make_text(
    host_rcx + 20, host_mcy - 35,
    "Monadic Command\nSubmission (C++23)",
    font_size=13, color=COL_ORANGE_GLOW, align="left",
    width=190, height=36,
))


# ── 5) DPDK gpudev internal path: DPDK → VRAM  ──
dpdk_lcx = dpdk_x               # 1050
dpdk_mcy = dpdk_y + dpdk_h // 2  # 480

elements.append(make_arrow(
    dpdk_lcx, dpdk_mcy,
    [[0, 0], [vram_rcx - dpdk_lcx + 10, vram_mcy - dpdk_mcy - 20]],
    color=COL_CYAN_GLOW, stroke_width=3, stroke_style="dashed",
))

elements.append(make_text(
    dpdk_lcx - 130, dpdk_mcy - 30,
    "gpudev\nDMA",
    font_size=11, color=COL_CYAN_DIM, align="center",
    width=60, height=30,
))


# ═══════════════════════════════════════════════════════════════════════════
# ZONE SEPARATOR LINES
# ═══════════════════════════════════════════════════════════════════════════

# Between Zone 1 and Zone 2
elements.append(make_line(
    ZONE_PAD, z2_y - 15,
    [[0, 0], [CANVAS_W - 2 * ZONE_PAD, 0]],
    color=COL_ZONE_STROKE, stroke_width=1, stroke_style="dashed",
))

# Between Zone 2 and Zone 3
elements.append(make_line(
    ZONE_PAD, z3_y - 15,
    [[0, 0], [CANVAS_W - 2 * ZONE_PAD, 0]],
    color=COL_ZONE_STROKE, stroke_width=1, stroke_style="dashed",
))


# ═══════════════════════════════════════════════════════════════════════════
# LEGEND
# ═══════════════════════════════════════════════════════════════════════════
legend_x, legend_y = 1100, z1_y + 20
elements.append(make_rect(legend_x, legend_y, 520, 170,
                          fill="#151528", stroke=COL_ZONE_STROKE,
                          stroke_width=1, opacity=90))
elements.append(make_text(legend_x + 10, legend_y + 8, "Legend",
                          font_size=16, color=COL_TITLE, align="left",
                          width=100, height=22))

# Green line
elements.append(make_line(legend_x + 20, legend_y + 45,
                          [[0, 0], [50, 0]],
                          color=COL_GREEN_GLOW, stroke_width=4))
elements.append(make_text(legend_x + 80, legend_y + 36,
                          "GPUDirect Storage (Zero-Copy)",
                          font_size=13, color=COL_GREEN_GLOW, align="left",
                          width=300, height=18))

# Cyan line
elements.append(make_line(legend_x + 20, legend_y + 75,
                          [[0, 0], [50, 0]],
                          color=COL_CYAN_GLOW, stroke_width=4))
elements.append(make_text(legend_x + 80, legend_y + 66,
                          "GPUDirect RDMA / Network Path",
                          font_size=13, color=COL_CYAN_GLOW, align="left",
                          width=300, height=18))

# Orange dashed line
elements.append(make_line(legend_x + 20, legend_y + 105,
                          [[0, 0], [50, 0]],
                          color=COL_ORANGE_GLOW, stroke_width=3,
                          stroke_style="dashed"))
elements.append(make_text(legend_x + 80, legend_y + 96,
                          "Monadic Control Signal (Config Only)",
                          font_size=13, color=COL_ORANGE_GLOW, align="left",
                          width=320, height=18))

# Purple line
elements.append(make_line(legend_x + 20, legend_y + 135,
                          [[0, 0], [50, 0]],
                          color=COL_NVLINK, stroke_width=4))
elements.append(make_text(legend_x + 80, legend_y + 126,
                          "NVLink Inter-GPU P2P",
                          font_size=13, color=COL_NVLINK, align="left",
                          width=250, height=18))

# ═══════════════════════════════════════════════════════════════════════════
# Assemble Excalidraw document
# ═══════════════════════════════════════════════════════════════════════════
document = {
    "type": "excalidraw",
    "version": 2,
    "source": "dataplane-emu-generator",
    "elements": elements,
    "appState": {
        "gridSize": None,
        "viewBackgroundColor": COL_BG,
    },
    "files": {},
}

os.makedirs(os.path.dirname(EXCALIDRAW_PATH), exist_ok=True)
with open(EXCALIDRAW_PATH, "w") as f:
    json.dump(document, f, indent=2)

print(f"✓ Excalidraw saved → {os.path.relpath(EXCALIDRAW_PATH, REPO_ROOT)}")
print(f"  {len(elements)} elements generated")
print(f"  Background: dark mode ({COL_BG})")
