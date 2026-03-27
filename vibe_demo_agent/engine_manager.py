"""
engine_manager.py — Control-to-Data Plane Bridge

Manages the lifecycle of the C++ dataplane-emu process:
  - Launches with taskset core pinning (cores 1-3 for SPDK reactors)
  - Monitors stderr for SPDK health probes
  - Provides graceful SIGINT teardown matching the C++ signal_handler chain

Usage:
    mgr = EngineManager(binary="./dataplane-emu")
    mgr.start(spdk=True, kernel_bypass=True, mountpoint="/mnt/virtual_nvme")
    mgr.wait_healthy(timeout=10.0)
    # ... run demo ...
    mgr.stop()
"""

import os
import signal
import subprocess
import threading
import time

# Default reactor core mask: cores 1-3, leaving core 0 for OS + Python.
DEFAULT_REACTOR_CORES = "1-3"

# Health-check markers emitted by main.cpp stderr.
_HEALTH_MARKERS = [
    "SPDK environment initialised",
    "Mounting FUSE bridge",
    "Starting kernel-bypass backend",
    "Kernel-bypass bridge not enabled",
    "Execution complete",
]


class EngineManager:
    """Manages a single dataplane-emu child process."""

    def __init__(self, binary="./dataplane-emu", reactor_cores=DEFAULT_REACTOR_CORES):
        self.binary = binary
        self.reactor_cores = reactor_cores
        self._proc = None          # subprocess.Popen handle
        self._stderr_lines = []    # captured stderr lines
        self._stdout_lines = []    # captured stdout lines
        self._stderr_thread = None
        self._stdout_thread = None
        self._healthy = threading.Event()
        self._stop_flag = threading.Event()

    # -----------------------------------------------------------------
    # Public API
    # -----------------------------------------------------------------

    def start(self, spdk=False, kernel_bypass=False,
              mountpoint="/mnt/virtual_nvme", block_device=None,
              benchmark=False, extra_env=None):
        """Fork/exec the C++ engine with taskset core pinning."""
        if self._proc is not None:
            raise RuntimeError("Engine already running")

        cmd = ["taskset", "-c", self.reactor_cores, self.binary]
        if spdk:
            cmd.append("-s")
        if kernel_bypass:
            cmd.append("-k")
        if benchmark:
            cmd.append("-b")
        if mountpoint:
            cmd.extend(["-m", mountpoint])
        if block_device:
            cmd.extend(["-d", block_device])

        env = os.environ.copy()
        if extra_env:
            env.update(extra_env)

        self._proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
            # Start in its own process group so we can signal it cleanly.
            preexec_fn=os.setsid,
        )

        # Background threads to drain stdout+stderr and detect health markers.
        self._stop_flag.clear()
        self._healthy.clear()
        self._stderr_thread = threading.Thread(
            target=self._drain_pipe,
            args=(self._proc.stderr, self._stderr_lines),
            daemon=True,
        )
        self._stdout_thread = threading.Thread(
            target=self._drain_pipe,
            args=(self._proc.stdout, self._stdout_lines),
            daemon=True,
        )
        self._stderr_thread.start()
        self._stdout_thread.start()

    def wait_healthy(self, timeout=10.0):
        """Block until the engine emits a health marker on stdout or stderr."""
        if not self._healthy.wait(timeout=timeout):
            # Dump what we captured so far for diagnosis.
            captured = "\n".join(
                (self._stderr_lines + self._stdout_lines)[-20:]
            )
            raise TimeoutError(
                f"Engine did not become healthy within {timeout}s.\n"
                f"Last output:\n{captured}"
            )

    def stop(self, timeout=5.0):
        """Send SIGINT (triggers the C++ fork/exec fusermount3 -u chain) and wait."""
        if self._proc is None:
            return

        try:
            # Signal the entire process group.
            os.killpg(os.getpgid(self._proc.pid), signal.SIGINT)
        except ProcessLookupError:
            pass

        try:
            self._proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            # Hard kill as last resort.
            os.killpg(os.getpgid(self._proc.pid), signal.SIGKILL)
            self._proc.wait(timeout=2)

        self._stop_flag.set()
        for t in (self._stderr_thread, self._stdout_thread):
            if t and t.is_alive():
                t.join(timeout=2)

        self._proc = None

    @property
    def is_running(self):
        return self._proc is not None and self._proc.poll() is None

    @property
    def returncode(self):
        if self._proc is None:
            return None
        return self._proc.poll()

    @property
    def stderr_lines(self):
        """Snapshot of captured stderr lines (thread-safe read)."""
        return list(self._stderr_lines)

    @property
    def stdout_lines(self):
        """Snapshot of captured stdout lines (thread-safe read)."""
        return list(self._stdout_lines)

    # -----------------------------------------------------------------
    # Internal
    # -----------------------------------------------------------------

    def _drain_pipe(self, pipe, line_store):
        """Background thread: read a pipe line-by-line, detect health markers."""
        while not self._stop_flag.is_set():
            if self._proc is None or pipe is None:
                break
            line = pipe.readline()
            if not line:
                break
            decoded = line.decode("utf-8", errors="replace").rstrip("\n")
            line_store.append(decoded)

            # Check for any health marker.
            for marker in _HEALTH_MARKERS:
                if marker in decoded:
                    self._healthy.set()
                    break
