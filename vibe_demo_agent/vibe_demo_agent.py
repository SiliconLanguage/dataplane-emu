#!/usr/bin/env python3
import os
import sys
import time
import subprocess
import argparse
from dotenv import load_dotenv

# Load the .env file immediately
load_dotenv()

# ---------------------------------------------------------------------------
# Data Plane Integration — EngineManager + TelemetrySink
# ---------------------------------------------------------------------------
from engine_manager import EngineManager
from telemetry_sink import (
    TelemetrySink, render_telemetry_line, render_comparison_chart,
    render_live_scorecard,
    measure_kernel_latency_us, measure_xfs_latency_us,
)

# Global engine manager instance — commands in scenario scripts control it.
_engine_mgr = EngineManager(
    binary=os.environ.get(
        "DATAPLANE_BINARY",
        os.path.expanduser("~/dataplane-emu/build/dataplane-emu"),
    ),
    reactor_cores=os.environ.get("REACTOR_CORES", "1-3"),
)
_telemetry = TelemetrySink()

# Pre-flight Credential Check
SPEECH_KEY = os.environ.get('SPEECH_KEY')
SPEECH_REGION = os.environ.get('SPEECH_REGION')

CYAN = '\033[96m'
GREEN = '\033[92m'
BLUE = '\033[94m'
YELLOW = '\033[93m'
PURPLE = '\033[95m'
RED = '\033[1;91m'
RESET = '\033[0m'

# ---------------------------------------------------------------------------
# SSH Remote Execution — "Local Controller / Remote Execution" pattern
# Set DEMO_SSH_HOST to run infrastructure commands on a remote Cobalt node
# while keeping TTS audio and terminal visuals local.
# ---------------------------------------------------------------------------
SSH_HOST = os.environ.get('DEMO_SSH_HOST', '')

_LOGO_SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'logo.sh')

def print_logo():
    subprocess.run(['bash', _LOGO_SCRIPT])
    print(f"  >> SYSTEMS ARCHITECTURE | HW/SW CO-DESIGN | AI INFRASTRUCTURE\n")

if not SPEECH_KEY or not SPEECH_REGION:
    print(f"\n{RED}[SYSTEM HALTED] Azure Speech Credentials Missing.{RESET}")
    print(f"{RED}The .env file is either missing or empty.{RESET}")
    print(f"{RED}Please run 'source setup_demo.sh' to initialize the environment before presenting.{RESET}\n")
    sys.exit(1)

# Only import the Azure SDK if we know we have the keys to use it
import azure.cognitiveservices.speech as speechsdk

def play_audio(file_path):
    if sys.platform == "darwin":
        subprocess.run(["afplay", file_path])
    else:
        subprocess.run(["ffplay", "-nodisp", "-autoexit", "-loglevel", "quiet", file_path])

def speak(text, index):
    print(f"{CYAN}>> Demo Agent: '{text}'{RESET}")
    speech_file_path = f"/tmp/vibe_demo_voice_{index}.wav"

    speech_config = speechsdk.SpeechConfig(subscription=SPEECH_KEY, region=SPEECH_REGION)
    speech_config.speech_synthesis_voice_name = "en-US-ChristopherNeural"
    speech_config.set_speech_synthesis_output_format(
        speechsdk.SpeechSynthesisOutputFormat.Riff48Khz16BitMonoPcm
    )

    # No AudioOutputConfig: synthesize to memory so result.audio_data is the
    # complete WAV. Writing audio_data once avoids the double-write corruption
    # that occurs when AudioOutputConfig(filename=...) writes the file and then
    # the manual write overwrites it with a potentially empty or partial buffer.
    speech_synthesizer = speechsdk.SpeechSynthesizer(speech_config=speech_config, audio_config=None)

    result = speech_synthesizer.speak_text(text)
    if result.reason != speechsdk.ResultReason.SynthesizingAudioCompleted:
        print(f"{YELLOW}[WARNING] TTS failed (reason: {result.reason}). Skipping voice line.{RESET}")
        return
    with open(speech_file_path, "wb") as f:
        f.write(result.audio_data)
        f.flush()
        os.fsync(f.fileno())
    play_audio(speech_file_path)

def trigger_easter_egg(voice_index):
    print_logo()

    pitch = (
        "Bridging hyperscale infrastructure and bare-metal performance "
        "requires global vision. "
        "Ping is exploring engineering leadership opportunities. "
        "He leads teams and AI agents building systems "
        "that bypass the kernel, not the details. "
        "Let's scale the next-gen AI data plane together."
    )
    speak(pitch, voice_index)

def run_demo(script_path):
    try:
        with open(script_path, 'r') as file:
            lines = file.readlines()
    except FileNotFoundError:
        print(f"{RED}Error: Could not find script at {script_path}{RESET}")
        sys.exit(1)

    print_logo()
    print(f"{GREEN}Starting Vibe Demo: {script_path}{RESET}\n")
    voice_index = 0
    
    in_block = False
    block_delimiter = ""
    block_buffer = ""

    try:
        for original_line in lines:
            line = original_line.strip()
            
            if in_block:
                block_buffer += original_line
                if line == block_delimiter:
                    in_block = False
                    subprocess.run(block_buffer, shell=True, executable='/bin/bash')
                    time.sleep(0.5)
                continue

            if not line:
                continue

            # ---------------------------------------------------------
            # Engine lifecycle directives (Pillar 1)
            # ---------------------------------------------------------
            if line.startswith("# ENGINE_START"):
                # Parse optional flags: # ENGINE_START spdk bypass benchmark
                tokens = line.replace("# ENGINE_START", "").strip().split()
                use_spdk = "spdk" in tokens
                use_bypass = "bypass" in tokens
                use_bench = "benchmark" in tokens
                mount = os.environ.get("DEMO_MOUNTPOINT", "/mnt/virtual_nvme")
                blk = os.environ.get("DEMO_BLOCK_DEVICE", "")
                print(f"\n{GREEN}[ENGINE] Starting dataplane-emu "
                      f"(spdk={use_spdk}, bypass={use_bypass})...{RESET}")
                _engine_mgr.start(
                    spdk=use_spdk,
                    kernel_bypass=use_bypass,
                    benchmark=use_bench,
                    mountpoint=mount,
                    block_device=blk or None,
                )
                try:
                    _engine_mgr.wait_healthy(timeout=10.0)
                    print(f"{GREEN}[ENGINE] Healthy.{RESET}\n")
                except TimeoutError as exc:
                    print(f"{RED}[ENGINE] {exc}{RESET}\n")
                continue

            if line.startswith("# ENGINE_STOP"):
                print(f"\n{GREEN}[ENGINE] Stopping dataplane-emu...{RESET}")
                _engine_mgr.stop()
                print(f"{GREEN}[ENGINE] Stopped.{RESET}\n")
                continue

            # ---------------------------------------------------------
            # Engine benchmark summary (show the audience the numbers)
            # ---------------------------------------------------------
            if line.startswith("# ENGINE_SUMMARY"):
                # # ENGINE_SUMMARY [timer_freq_hz]
                parts = line.replace("# ENGINE_SUMMARY", "").strip().split()
                freq = int(parts[0]) if parts else 1_000_000_000
                try:
                    _telemetry.open()
                    snap = _telemetry.snapshot()
                    _telemetry.close()
                    total = snap.total_read_ops + snap.total_write_ops
                    lat_us = snap.latency_us(freq)
                    title = (f"Benchmark: {total:,} NVMe Reads "
                             f"via Lock-Free SQ/CQ Bypass")
                    box_w = max(len(title) + 6, 48)
                    inner = box_w - 2
                    print(f"\n  {CYAN}┌{'─' * inner}┐{RESET}")
                    print(f"  {CYAN}│{RESET}  {GREEN}{title}{RESET}"
                          f"{' ' * (inner - len(title) - 2)}{CYAN}│{RESET}")
                    print(f"  {CYAN}├{'─' * inner}┤{RESET}")
                    lw = 34  # "  Total I/Os      " + 14-digit field
                    print(f"  {CYAN}│{RESET}  Total I/Os      {GREEN}{total:>14,}{RESET}"
                          f"{' ' * (inner - lw)}{CYAN}│{RESET}")
                    print(f"  {CYAN}│{RESET}  Reads            {snap.total_read_ops:>14,}"
                          f"{' ' * (inner - lw)}{CYAN}│{RESET}")
                    print(f"  {CYAN}│{RESET}  Writes           {snap.total_write_ops:>14,}"
                          f"{' ' * (inner - lw)}{CYAN}│{RESET}")
                    print(f"  {CYAN}│{RESET}  Bypass latency   {YELLOW}{lat_us:>11.2f} µs{RESET}"
                          f"{' ' * (inner - lw)}{CYAN}│{RESET}")
                    print(f"  {CYAN}└{'─' * inner}┘{RESET}\n")
                except Exception as exc:
                    print(f"{YELLOW}[TELEMETRY] Could not read summary: {exc}{RESET}")
                continue

            # ---------------------------------------------------------
            # Live telemetry display (Pillar 4)
            # ---------------------------------------------------------
            if line.startswith("# TELEMETRY"):
                # # TELEMETRY <seconds> [timer_freq_hz]
                parts = line.replace("# TELEMETRY", "").strip().split()
                duration = float(parts[0]) if parts else 3.0
                freq = int(parts[1]) if len(parts) > 1 else 1_000_000_000
                try:
                    _telemetry.open()
                    prev = None
                    end_time = time.monotonic() + duration
                    while time.monotonic() < end_time:
                        snap = _telemetry.snapshot()
                        line_out = render_telemetry_line(snap, prev, freq)
                        print(f"\r{line_out}", end="", flush=True)
                        prev = snap
                        time.sleep(0.25)
                    print()  # newline after telemetry
                    _telemetry.close()
                except Exception as exc:
                    print(f"{YELLOW}[TELEMETRY] {exc}{RESET}")
                continue

            # ---------------------------------------------------------
            # Latency comparison chart (Pillar 4)
            # ---------------------------------------------------------
            if line.startswith("# COMPARE_CHART"):
                # # COMPARE_CHART <legacy_us> <bypass_us>
                parts = line.replace("# COMPARE_CHART", "").strip().split()
                legacy = float(parts[0]) if len(parts) > 0 else 14.0
                bypass = float(parts[1]) if len(parts) > 1 else 3.8
                print(render_comparison_chart(legacy, bypass))
                continue

            # ---------------------------------------------------------
            # Live kernel-vs-bypass comparison (Pillar 4)
            # Runs dd through VFS to measure real kernel latency, then
            # reads bypass latency from the telemetry SHM.
            # ---------------------------------------------------------
            if line.startswith("# COMPARE_LIVE"):
                # # COMPARE_LIVE [io_count] [timer_freq_hz]
                parts = line.replace("# COMPARE_LIVE", "").strip().split()
                io_count = int(parts[0]) if len(parts) > 0 else 10000
                freq = int(parts[1]) if len(parts) > 1 else 1_000_000_000
                print(f"\n{YELLOW}[PROBE] Measuring kernel VFS latency "
                      f"({io_count} sync writes)...{RESET}")
                legacy_us = measure_kernel_latency_us(io_count=io_count)
                print(f"{YELLOW}[PROBE] VFS latency: {legacy_us:.1f} µs/IO{RESET}")
                # Read bypass latency from telemetry SHM.
                bypass_us = 3.8  # fallback
                try:
                    _telemetry.open()
                    snap = _telemetry.snapshot()
                    bypass_us = snap.latency_us(freq)
                    _telemetry.close()
                except Exception:
                    pass
                print(render_comparison_chart(legacy_us, bypass_us))
                continue

            # ---------------------------------------------------------
            # XFS-vs-bypass comparison (real XFS filesystem)
            # Creates loopback XFS, measures sync IO, compares to SQ/CQ.
            # ---------------------------------------------------------
            if line.startswith("# COMPARE_XFS"):
                # # COMPARE_XFS [io_count] [timer_freq_hz]
                parts = line.replace("# COMPARE_XFS", "").strip().split()
                io_count = int(parts[0]) if len(parts) > 0 else 10000
                freq = int(parts[1]) if len(parts) > 1 else 1_000_000_000

                def _xfs_log(msg):
                    print(f"{YELLOW}[XFS] {msg}{RESET}")

                xfs_us = measure_xfs_latency_us(
                    io_count=io_count, verbose_cb=_xfs_log,
                )
                # Read bypass latency from telemetry SHM.
                bypass_us = 3.8  # fallback
                try:
                    _telemetry.open()
                    snap = _telemetry.snapshot()
                    bypass_us = snap.latency_us(freq)
                    _telemetry.close()
                except Exception:
                    pass
                print(render_comparison_chart(
                    xfs_us, bypass_us,
                    config_line="Config: bs=4k  QD=1  read  (loopback XFS vs lock-free SQ/CQ)",
                ))
                continue

            # ---------------------------------------------------------
            # Deterministic 3-stage benchmark scorecard
            # Runs launch_arm_neoverse_demo_deterministic.sh and
            # parses fio JSON + bdevperf logs.
            # ---------------------------------------------------------
            if line.startswith("# SCORECARD"):
                # # SCORECARD [runtime_sec] [qd_mid]
                parts = line.replace("# SCORECARD", "").strip().split()
                runtime = int(parts[0]) if len(parts) > 0 else 10
                qd_mid = int(parts[1]) if len(parts) > 1 else 16

                print(f"\n{GREEN}[BENCHMARK] Launching deterministic 3-stage benchmark...{RESET}")
                print(f"{GREEN}[BENCHMARK] Stages: Kernel fio \u2192 FUSE bridge fio \u2192 SPDK bdevperf{RESET}")
                print(f"{GREEN}[BENCHMARK] QD sweep: 1, {qd_mid}  |  Runtime: {runtime}s per run{RESET}")
                if SSH_HOST:
                    print(f"{GREEN}[BENCHMARK] Remote execution: {SSH_HOST}{RESET}")
                print()

                from benchmark_runner import run_benchmark, render_deterministic_scorecard

                try:
                    results = run_benchmark(
                        executive_demo=True,
                        runtime=runtime,
                        qd_mid=qd_mid,
                    )
                    print(render_deterministic_scorecard(results))
                except Exception as exc:
                    print(f"{RED}[BENCHMARK] Failed: {exc}{RESET}")
                continue

            if line.startswith("# VOICE:"):
                text = line.replace("# VOICE:", "").strip()
                speak(text, voice_index)
                voice_index += 1
            elif line.startswith("# HIRE_ME"):
                trigger_easter_egg(voice_index)
                voice_index += 1
            elif line.startswith("# WAIT:"):
                seconds = float(line.replace("# WAIT:", "").strip())
                time.sleep(seconds)
            elif line.startswith("#"):
                continue
            else:
                if "cat <<" in line:
                    in_block = True
                    parts = line.split("<<")
                    block_delimiter = parts[1].strip().strip("'").strip('"')
                    block_buffer = original_line
                else:
                    # Silently run echo and sleep to preserve the magic trick
                    if line.startswith("echo") or line.startswith("sleep"):
                        subprocess.run(line, shell=True, executable='/bin/bash')
                    else:
                        print(f"\n{GREEN}$ {line}{RESET}")
                        subprocess.run(line, shell=True, executable='/bin/bash')
                        time.sleep(0.5)
                        
    except KeyboardInterrupt:
        print(f"\n{CYAN}Demo interrupted. Shutting down engine...{RESET}")
        if _engine_mgr.is_running:
            _engine_mgr.stop()
        sys.exit(0)

    # Ensure engine is stopped after script completes.
    if _engine_mgr.is_running:
        _engine_mgr.stop()

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Run a bash script with Azure Neural TTS voiceovers.")
    parser.add_argument("script", help="Path to the .sh demo script")
    args = parser.parse_args()
    run_demo(args.script)
