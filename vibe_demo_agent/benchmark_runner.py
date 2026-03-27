"""
benchmark_runner.py — Invokes launch_arm_neoverse_demo_deterministic.sh
and parses the resulting fio JSON + bdevperf log files into a structured
scorecard.

Supports two execution modes controlled by DEMO_SSH_HOST env var:
  - Local mode  (DEMO_SSH_HOST unset): runs the launcher via subprocess
  - Remote mode (DEMO_SSH_HOST set):   runs over SSH with real-time stdout
    streaming, fetches result files via ssh cat for local parsing

The heavy lifting (fio, bdevperf, FUSE engine lifecycle, device safety)
is done entirely by the bash script.  This module is a thin orchestrator
that adds hardware metadata detection and scorecard rendering.
"""

import json
import os
import re
import subprocess
from dataclasses import dataclass, field

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_DIR = os.path.dirname(SCRIPT_DIR)
LAUNCHER = os.path.join(REPO_DIR, "launch_arm_neoverse_demo_deterministic.sh")

# Remote repo path (on the Azure Cobalt node)
REMOTE_REPO = "~/dataplane-emu"
REMOTE_LAUNCHER = f"{REMOTE_REPO}/launch_arm_neoverse_demo_deterministic.sh"

# bdevperf log paths — must match the launcher script
BDEV_LAT_LOG = "/tmp/arm_neoverse_bdevperf_lat.log"
BDEV_MID_LOG = "/tmp/arm_neoverse_bdevperf_mid.log"
BDEV_IOPS_LOG = "/tmp/arm_neoverse_bdevperf_iops.log"

# ANSI colours
CYAN = '\033[96m'
GREEN = '\033[92m'
YELLOW = '\033[93m'
RED = '\033[1;91m'
DIM = '\033[2m'
RESET = '\033[0m'


def _ssh_host():
    """Return the SSH target or None for local execution."""
    return os.environ.get("DEMO_SSH_HOST") or None


# ── Data structures ────────────────────────────────────────────────────

@dataclass
class StageResult:
    lat_us: float = 0.0
    iops: int = 0


@dataclass
class BenchmarkResults:
    kernel_qd1: StageResult = field(default_factory=StageResult)
    fuse_qd1: StageResult = field(default_factory=StageResult)
    spdk_qd1: StageResult = field(default_factory=StageResult)
    kernel_qd_mid: StageResult = field(default_factory=StageResult)
    fuse_qd_mid: StageResult = field(default_factory=StageResult)
    spdk_qd_mid: StageResult = field(default_factory=StageResult)
    qd_mid: int = 16
    cpu_desc: str = ""
    instance_type: str = ""
    disk_model: str = ""
    stage3_label: str = ""
    bs: str = "4k"
    runtime: int = 10
    rwmixread: int = 50


# ── Parsers (match the bash script's jq/awk expressions exactly) ──────

def parse_fio_json_str(raw):
    """Parse fio JSON string → StageResult."""
    try:
        data = json.loads(raw)
        job = data["jobs"][0]
        read_lat = job.get("read", {}).get("clat_ns", {}).get("mean", 0) or 0
        write_lat = job.get("write", {}).get("clat_ns", {}).get("mean", 0) or 0
        lat_us = (read_lat + write_lat) / 2000.0
        read_iops = job.get("read", {}).get("iops", 0) or 0
        write_iops = job.get("write", {}).get("iops", 0) or 0
        iops = int(read_iops + write_iops)
        return StageResult(lat_us=round(lat_us, 2), iops=iops)
    except Exception:
        return StageResult()


def parse_fio_json(path):
    """Parse fio JSON file → StageResult."""
    try:
        with open(path) as f:
            return parse_fio_json_str(f.read())
    except Exception:
        return StageResult()


def parse_bdevperf_log_str(content):
    """Parse bdevperf Total line from string → StageResult."""
    try:
        match = re.search(r'^\s*Total\s*:\s*(.+)$', content, re.MULTILINE)
        if not match:
            return StageResult()
        fields = match.group(1).split()
        iops = int(float(fields[0]))
        lat_us = float(fields[4])
        return StageResult(lat_us=round(lat_us, 2), iops=iops)
    except Exception:
        return StageResult()


def parse_bdevperf_log(path):
    """Parse bdevperf log file → StageResult."""
    try:
        with open(path) as f:
            return parse_bdevperf_log_str(f.read())
    except Exception:
        return StageResult()


# ── SSH helpers ───────────────────────────────────────────────────────

def _ssh_cmd_base(host):
    """Base SSH command with options to suppress host key prompts."""
    return [
        "ssh", "-o", "StrictHostKeyChecking=accept-new",
        "-o", "BatchMode=yes", host,
    ]


def ssh_read_file(host, remote_path):
    """Read a file from the remote host, returns content string or ''."""
    try:
        r = subprocess.run(
            _ssh_cmd_base(host) + [f"cat {remote_path}"],
            capture_output=True, text=True, timeout=15,
        )
        return r.stdout if r.returncode == 0 else ""
    except Exception:
        return ""


def ssh_run_line(host, cmd):
    """Run a single command on the remote host, return stdout."""
    try:
        r = subprocess.run(
            _ssh_cmd_base(host) + [cmd],
            capture_output=True, text=True, timeout=15,
        )
        return r.stdout.strip() if r.returncode == 0 else ""
    except Exception:
        return ""


def _remote_missing_commands(host, commands):
    """Return a list of commands missing on the remote host."""
    missing = []
    for command in commands:
        check = ssh_run_line(host, f"command -v {command} >/dev/null 2>&1 && echo OK")
        if check != "OK":
            missing.append(command)
    return missing


def _validate_remote_benchmark_host(host):
    """Fail early with a targeted message if the remote benchmark host is missing prerequisites."""
    required = ["bash", "fio", "jq", "awk", "bc", "findmnt", "lsblk", "readlink", "grep", "timeout", "modprobe", "cmake", "make", "sudo"]
    missing = _remote_missing_commands(host, required)
    if missing:
        missing_list = ", ".join(missing)
        raise RuntimeError(
            f"Remote benchmark host {host} is missing required commands: {missing_list}. "
            "Install them on the Azure host before starting the scorecard demo."
        )


# ── Hardware metadata detection ───────────────────────────────────────

def _detect_cpu_desc_local():
    try:
        with open("/proc/cpuinfo") as f:
            for line in f:
                if "CPU part" in line:
                    part = line.split(":")[-1].strip().lower()
                    return {
                        "0xd49": "Neoverse-N2",
                        "0xd40": "Neoverse-V1",
                        "0xd4f": "Neoverse-V2",
                    }.get(part, f"ARM64 (part={part})")
    except Exception:
        pass
    return "ARM64"


def _detect_cpu_desc_remote(host):
    raw = ssh_run_line(host, "grep 'CPU part' /proc/cpuinfo | head -1")
    if ":" in raw:
        part = raw.split(":")[-1].strip().lower()
        return {
            "0xd49": "Neoverse-N2",
            "0xd40": "Neoverse-V1",
            "0xd4f": "Neoverse-V2",
        }.get(part, f"ARM64 (part={part})")
    return "ARM64"


def detect_cloud_and_instance(host=None):
    """Returns (cloud_provider, instance_type, cloud_label)."""
    if host:
        vendor = ssh_run_line(host, "cat /sys/devices/virtual/dmi/id/sys_vendor 2>/dev/null")
        product = ssh_run_line(host, "cat /sys/devices/virtual/dmi/id/product_name 2>/dev/null")
        cpu = _detect_cpu_desc_remote(host)
    else:
        try:
            vendor = open("/sys/devices/virtual/dmi/id/sys_vendor").read().strip()
            product = open("/sys/devices/virtual/dmi/id/product_name").read().strip()
        except Exception:
            vendor = product = ""
        cpu = _detect_cpu_desc_local()

    cloud = "unknown"
    combined = f"{vendor} {product}".lower()
    if "microsoft" in combined or "azure" in combined:
        cloud = "azure"
    elif "amazon" in combined or "ec2" in combined:
        cloud = "aws"

    instance = ""
    imds_curl = (
        'curl -s -H "Metadata:true" --connect-timeout 2 '
        '"http://169.254.169.254/metadata/instance/compute/vmSize'
        '?api-version=2021-02-01&format=text"'
    )
    aws_curl = (
        "curl -s --connect-timeout 2 "
        "http://169.254.169.254/latest/meta-data/instance-type"
    )

    if cloud == "azure":
        if host:
            instance = ssh_run_line(host, imds_curl)
        else:
            try:
                r = subprocess.run(
                    ["curl", "-s", "-H", "Metadata:true", "--connect-timeout", "2",
                     "http://169.254.169.254/metadata/instance/compute/vmSize"
                     "?api-version=2021-02-01&format=text"],
                    capture_output=True, text=True, timeout=5,
                )
                instance = r.stdout.strip() if r.returncode == 0 else ""
            except Exception:
                pass
    elif cloud == "aws":
        if host:
            instance = ssh_run_line(host, aws_curl)
        else:
            try:
                r = subprocess.run(
                    ["curl", "-s", "--connect-timeout", "2",
                     "http://169.254.169.254/latest/meta-data/instance-type"],
                    capture_output=True, text=True, timeout=5,
                )
                instance = r.stdout.strip() if r.returncode == 0 else ""
            except Exception:
                pass

    if cloud == "azure":
        cloud_label = f"Azure Cobalt 100 ({cpu})"
    elif cloud == "aws":
        if "V2" in cpu:
            cloud_label = f"AWS Graviton4 ({cpu})"
        elif "V1" in cpu:
            cloud_label = f"AWS Graviton3 ({cpu})"
        else:
            cloud_label = f"AWS Graviton ({cpu})"
    else:
        cloud_label = cpu

    return cloud, instance, cloud_label


def detect_disk_model(device="/dev/nvme0n1", host=None):
    if host:
        return ssh_run_line(host, f"lsblk -d -no MODEL {device}") or "NVMe"
    try:
        r = subprocess.run(
            ["lsblk", "-d", "-no", "MODEL", device],
            capture_output=True, text=True, timeout=5,
        )
        return r.stdout.strip() if r.returncode == 0 else "NVMe"
    except Exception:
        return "NVMe"


# ── Benchmark orchestration ──────────────────────────────────────────

def run_benchmark(
    executive_demo=True,
    runtime=10,
    qd_mid=16,
    skip_build=True,
    stage_cb=None,
):
    """Run the deterministic launcher and parse all results.

    If DEMO_SSH_HOST is set, executes over SSH with real-time stdout streaming.
    Otherwise runs locally via subprocess.

    stage_cb: optional callback(str) invoked with lines matching '[Stage N]'.
    Returns BenchmarkResults with all parsed data + hardware metadata.
    """
    host = _ssh_host()

    if host:
        return _run_benchmark_remote(
            host, executive_demo, runtime, qd_mid, skip_build, stage_cb)
    else:
        return _run_benchmark_local(
            executive_demo, runtime, qd_mid, skip_build, stage_cb)


def _run_benchmark_local(executive_demo, runtime, qd_mid, skip_build, stage_cb):
    """Run on the local machine."""
    env = os.environ.copy()
    env["ARM_NEOVERSE_DEMO_CONFIRM"] = "YES"
    env["DEMO_RUNTIME_SEC"] = str(runtime)
    env["DEMO_SKIP_BUILD"] = "1" if skip_build else "0"

    cmd = ["bash", LAUNCHER]
    if executive_demo:
        cmd.append("--executive-demo")

    proc = subprocess.Popen(
        cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, env=env, cwd=REPO_DIR,
    )

    for line in proc.stdout:
        line = line.rstrip('\n')
        if stage_cb and re.match(r'\[Stage \d', line):
            stage_cb(line)
        print(line, flush=True)

    proc.wait()
    if proc.returncode != 0:
        raise RuntimeError(
            f"Benchmark launcher exited with code {proc.returncode}")

    cloud, instance, cloud_label = detect_cloud_and_instance()
    disk_model = detect_disk_model()

    return _build_results(
        cloud, cloud_label, instance, disk_model,
        qd_mid, runtime, local=True,
    )


def _run_benchmark_remote(host, executive_demo, runtime, qd_mid, skip_build, stage_cb):
    """Run on a remote host via SSH with real-time stdout streaming."""
    _validate_remote_benchmark_host(host)

    flag = " --executive-demo" if executive_demo else ""
    skip = "1" if skip_build else "0"
    remote_cmd = (
        f"cd {REMOTE_REPO} && "
        f"ARM_NEOVERSE_DEMO_CONFIRM=YES "
        f"DEMO_RUNTIME_SEC={runtime} "
        f"DEMO_SKIP_BUILD={skip} "
        f"bash {REMOTE_LAUNCHER}{flag}"
    )

    ssh = _ssh_cmd_base(host) + [remote_cmd]

    proc = subprocess.Popen(
        ssh, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, bufsize=1,  # line-buffered for real-time streaming
    )

    for line in proc.stdout:
        line = line.rstrip('\n')
        if stage_cb and re.match(r'\[Stage \d', line):
            stage_cb(line)
        print(line, flush=True)

    proc.wait()
    if proc.returncode != 0:
        raise RuntimeError(
            f"Remote benchmark launcher exited with code {proc.returncode}")

    # Detect HW metadata from the remote host
    cloud, instance, cloud_label = detect_cloud_and_instance(host=host)
    disk_model = detect_disk_model(host=host)

    return _build_results(
        cloud, cloud_label, instance, disk_model,
        qd_mid, runtime, local=False, host=host,
    )


def _build_results(cloud, cloud_label, instance, disk_model,
                   qd_mid, runtime, local=True, host=None):
    """Parse result files and build BenchmarkResults."""
    if cloud == "azure":
        s3label = "bdev_uring (io_uring \u2192 Azure Boost mediated passthrough)"
    elif cloud == "aws":
        s3label = "bdev_nvme (vfio-pci \u2192 PCIe bypass, no-IOMMU / Nitro DMA isolation)"
    else:
        s3label = "SPDK bdevperf"

    results = BenchmarkResults(
        qd_mid=qd_mid, runtime=runtime,
        cpu_desc=cloud_label, instance_type=instance,
        disk_model=disk_model, stage3_label=s3label,
    )

    if local:
        results.kernel_qd1 = parse_fio_json(
            os.path.join(REPO_DIR, "x_qd1.json"))
        results.kernel_qd_mid = parse_fio_json(
            os.path.join(REPO_DIR, f"x_qd{qd_mid}.json"))
        results.fuse_qd1 = parse_fio_json(
            os.path.join(REPO_DIR, "fuse_qd1.json"))
        results.fuse_qd_mid = parse_fio_json(
            os.path.join(REPO_DIR, f"fuse_qd{qd_mid}.json"))
        results.spdk_qd1 = parse_bdevperf_log(BDEV_LAT_LOG)
        results.spdk_qd_mid = parse_bdevperf_log(BDEV_MID_LOG)
    else:
        # Fetch result files from remote via SSH cat
        results.kernel_qd1 = parse_fio_json_str(
            ssh_read_file(host, f"{REMOTE_REPO}/x_qd1.json"))
        results.kernel_qd_mid = parse_fio_json_str(
            ssh_read_file(host, f"{REMOTE_REPO}/x_qd{qd_mid}.json"))
        results.fuse_qd1 = parse_fio_json_str(
            ssh_read_file(host, f"{REMOTE_REPO}/fuse_qd1.json"))
        results.fuse_qd_mid = parse_fio_json_str(
            ssh_read_file(host, f"{REMOTE_REPO}/fuse_qd{qd_mid}.json"))
        results.spdk_qd1 = parse_bdevperf_log_str(
            ssh_read_file(host, BDEV_LAT_LOG))
        results.spdk_qd_mid = parse_bdevperf_log_str(
            ssh_read_file(host, BDEV_MID_LOG))

    return results


# ── Scorecard renderer ───────────────────────────────────────────────

def render_deterministic_scorecard(results):
    """Render the enriched 2-box scorecard with hardware metadata header."""
    W = 76  # inner width between │ delimiters (increased for better spacing)
    border = '═' * (W + 4)
    r = results

    def _box_top(title):
        fill = W - len(title) - 4
        return f"  ┌─ {CYAN}{title}{RESET} {'─' * fill}┐"

    def _box_bot():
        return f"  └{'─' * W}┘"

    def _row(col1, col2, col3, highlight=False):
        # Format each column separately without ANSI in width calculations
        col1_clean = f"{col1:<34s}"
        col2_clean = f"{col2:>14s}"  
        col3_clean = f"{col3:>14s}"
        
        # Apply highlighting after width formatting
        col1_formatted = f"{GREEN}{col1_clean}{RESET}" if highlight else col1_clean
        
        # Build the row content 
        content = f" {col1_formatted}  {col2_clean}  {col3_clean} "
        
        # Calculate padding based on visible content only (68 chars)
        visible_content_length = 1 + 34 + 2 + 14 + 2 + 14 + 1  # 68
        padding = W - visible_content_length
        
        return f"  │{content}{' ' * padding}│"

    def _header_row():
        content = f" {'Architecture':<34s}  {'Avg (μs)':>14s}  {'IOPS':>14s} "
        padding = W - len(content)
        return f"  │{content}{' ' * padding}│"

    def _sep():
        content = f" {'─' * 34}  {'─' * 14}  {'─' * 14} "
        padding = W - len(content)
        return f"  │{content}{' ' * padding}│"

    def _data(n, label, sr, is_best_lat=False, is_best_iops=False):
        # Format latency with proper precision (no ANSI in data values) 
        if sr.lat_us > 0:
            lat = f"{sr.lat_us:.2f}" if sr.lat_us < 1000 else f"{sr.lat_us:.1f}"
        else:
            lat = "N/A"
        
        # Format IOPS with thousands separator (no ANSI in data values)
        if sr.iops > 0:
            iops = f"{sr.iops:,}"
        else:
            iops = "N/A"
        
        # Highlight best performance
        highlight = is_best_lat or is_best_iops
        label_text = f"{n}. {label}"
        
        return _row(label_text, lat, iops, highlight)

    def _qd_box(title, kernel, fuse, spdk):
        # Determine best performers (excluding N/A values)
        valid_results = [(kernel, "kernel"), (fuse, "fuse"), (spdk, "spdk")]
        valid_lat = [(r.lat_us, name) for r, name in valid_results if r.lat_us > 0]
        valid_iops = [(r.iops, name) for r, name in valid_results if r.iops > 0]
        
        best_lat = min(valid_lat)[1] if valid_lat else None
        best_iops = max(valid_iops)[1] if valid_iops else None
        
        return [
            _box_top(title),
            _header_row(),
            _sep(),
            _data(1, "Kernel (XFS + fio)", kernel, 
                 is_best_lat=(best_lat == "kernel"), 
                 is_best_iops=(best_iops == "kernel")),
            _data(2, "User-Space Bridge (FUSE)", fuse,
                 is_best_lat=(best_lat == "fuse"), 
                 is_best_iops=(best_iops == "fuse")),
            _data(3, "SPDK Zero-Copy (bdevperf)", spdk,
                 is_best_lat=(best_lat == "spdk"), 
                 is_best_iops=(best_iops == "spdk")),
            _box_bot(),
        ]

    lines = ["", f"{CYAN}{border}{RESET}"]
    lines.append(
        f"  {YELLOW}{r.cpu_desc}{RESET} | {YELLOW}{r.instance_type}{RESET} | {CYAN}SILICON DATA PLANE SCORECARD{RESET}")
    lines.append(f"  {DIM}Target Drive:{RESET} {r.disk_model}")
    lines.append(
        f"  {DIM}Config:{RESET} bs={r.bs}  runtime={r.runtime}s"
        f"  rwmix={r.rwmixread}/{100 - r.rwmixread}")
    lines.append(f"  {DIM}Stage 3:{RESET} {r.stage3_label}")
    lines.append(f"{CYAN}{border}{RESET}")
    lines.append("")
    lines.extend(_qd_box(
        "Latency (QD=1)", r.kernel_qd1, r.fuse_qd1, r.spdk_qd1))
    lines.append("")
    lines.extend(_qd_box(
        f"Knee-of-Curve (QD={r.qd_mid})",
        r.kernel_qd_mid, r.fuse_qd_mid, r.spdk_qd_mid))
    lines.append(f"{CYAN}{border}{RESET}")
    lines.append("")

    return "\n".join(lines)
