#!/bin/bash
# Copyright 2026 MagicWine contributors
# SPDX-License-Identifier: LGPL-2.1-or-later
# Compile both Windows ABIs and compare real synchronization with MSync off/on.
# Requires Python 3, both MinGW GCC cross-compilers, and the patched Wine runtime.
# --benchmark adds finite handoff measurements, not an FPS or speedup assertion.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 - "$ROOT" "$@" <<'PY'
import argparse
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile

root = Path(sys.argv[1])
parser = argparse.ArgumentParser(
    prog="scripts/test-msync.sh",
    description="Test real Windows synchronization in both ABIs with WINEMSYNC=0 and 1. "
                "Every run uses its own disposable prefix and wineserver.",
    epilog="Dependencies: python3, x86_64-w64-mingw32-gcc, i686-w64-mingw32-gcc, "
           "and a patched macOS Wine runtime with adjacent wineserver and WoW64 support. "
           "No installed bottle or existing Wine session is used.")
parser.add_argument("wine", type=Path, help="absolute path to the patched runtime's bin/wine")
parser.add_argument("--benchmark", action="store_true", help="also print bounded signal-and-wait handoff timings")
args = parser.parse_args(sys.argv[2:])
wine = args.wine
server = wine.parent / "wineserver"
if not wine.is_absolute() or not all(path.is_file() and os.access(path, os.X_OK) for path in (wine, server)):
    parser.error("Wine must be an absolute executable path with an adjacent executable wineserver")
compilers = {64: "x86_64-w64-mingw32-gcc", 32: "i686-w64-mingw32-gcc"}
for compiler in compilers.values():
    if shutil.which(compiler) is None:
        parser.error("missing prerequisite: " + compiler)

MARKER = "msync: up and running."
BASE_ENV = os.environ.copy()
for key in ("WINEPREFIX", "WINEARCH", "WINEDLLPATH", "WINEDLLOVERRIDES", "WINELOADER", "WINESERVER",
            "WINEMSYNC", "WINEESYNC", "WINEFSYNC", "WINEDEBUG"):
    BASE_ENV.pop(key, None)
BASE_ENV.update(WINEDEBUG="-all", WINESERVER=str(server), WINEESYNC="0", WINEFSYNC="0")


def interrupt(_signum, _frame):
    raise KeyboardInterrupt


signal.signal(signal.SIGTERM, interrupt)


def terminate_group(process):
    # This group was created by us, never an inherited shell/user Wine group.
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait(timeout=10)


def run(command, env, log, timeout, show=False):
    print("+ " + " ".join(map(str, command)), flush=True)
    with log.open("wb") as output:
        process = subprocess.Popen(list(map(str, command)), env=env, stdout=output,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        try:
            result = process.wait(timeout=timeout)
        except BaseException:
            terminate_group(process)
            raise
    text = log.read_text(errors="replace")
    if show or result:
        print(text[-65536:], end="" if text.endswith("\n") else "\n", flush=True)
    if result:
        raise RuntimeError(f"command exited {result}; log: {log.name}")
    return text


def require_backend(mode, logs):
    activated = any(MARKER in path.read_text(errors="replace") for path in logs if path.exists())
    if mode == 1 and not activated:
        raise RuntimeError(f"WINEMSYNC=1 produced no real backend startup marker: {MARKER!r}; "
                           "the supplied runtime must contain the MSync server and client implementation")
    if mode == 0 and activated:
        raise RuntimeError("WINEMSYNC=0 unexpectedly activated MSync")


def session(work, bits, mode):
    directory = work / f"msync-{mode}-{bits}"
    directory.mkdir()
    prefix = directory / "prefix"
    prefix.mkdir()
    env = dict(BASE_ENV, WINEPREFIX=str(prefix), WINEMSYNC=str(mode))
    server_log = directory / "server.log"
    boot_log = directory / "boot.log"
    test_log = directory / "test.log"
    failed = False
    print(f"\n=== {bits}-bit WINEMSYNC={mode}; private prefix {prefix} ===", flush=True)
    try:
        # Daemon startup returns only after acquiring this prefix's server lock,
        # avoiding a race with wineboot's automatic server startup. Its stderr
        # remains in server.log; initialization/marker emission completes before
        # wineboot's first server request can finish.
        run([server, "-p"], env, server_log, 15)
        run([wine, "wineboot", "-u"], env, boot_log, 180)
        require_backend(mode, (server_log, boot_log))
        command = [wine, work / f"msync{bits}.exe"]
        if args.benchmark:
            command.append("--benchmark")
        output = run(command, env, test_log, 300 if args.benchmark else 180, show=True)
        expected = f"PASS: MagicWine MSync synchronization regression ({bits}-bit)"
        if expected not in output:
            raise RuntimeError("test executable did not report completion for the requested ABI")
        require_backend(mode, (server_log, boot_log, test_log))
        print(f"PASS backend startup evidence: WINEMSYNC={mode}, marker "
              + ("present" if mode else "absent"), flush=True)
    except BaseException:
        failed = True
        raise
    finally:
        # Never run a global killall/pkill or consult the caller's WINEPREFIX.
        # Even a stuck client or child process belongs only to this private server.
        cleanup_error = None
        try:
            run([server, "-k"], env, directory / "stop.log", 15)
            run([server, "-w"], env, directory / "wait.log", 15)
        except Exception as error:
            cleanup_error = error
        if failed or cleanup_error is not None:
            for log in sorted(directory.glob("*.log")):
                print(f"\n--- {directory.name}/{log.name} ---", file=sys.stderr)
                print(log.read_text(errors="replace")[-65536:], file=sys.stderr, flush=True)
        if cleanup_error is not None:
            if failed:
                print(f"Private wineserver cleanup failed: {cleanup_error}", file=sys.stderr, flush=True)
            else:
                raise RuntimeError(f"private wineserver cleanup failed: {cleanup_error}") from cleanup_error


try:
    with tempfile.TemporaryDirectory(prefix="magicwine-msync-") as temporary:
        work = Path(temporary).resolve()
        for bits, compiler in compilers.items():
            run([compiler, "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
                 root / "Tests/WineMSyncTests.c", "-o", work / f"msync{bits}.exe"],
                BASE_ENV, work / f"compile-{bits}.log", 120)
        for mode in (0, 1):
            for bits in (64, 32):
                session(work, bits, mode)
    print("\nPASS: both Windows ABIs, WINEMSYNC disabled and enabled, four isolated server sessions.")
    if args.benchmark:
        print("BENCH values describe this finite synchronization workload only; they do not predict game FPS.")
except KeyboardInterrupt:
    print("Interrupted; only the runner's private Wine sessions were stopped.", file=sys.stderr)
    sys.exit(130)
except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
    print(f"FAIL: {error}", file=sys.stderr)
    sys.exit(1)
PY
