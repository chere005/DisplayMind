#!/usr/bin/env python3
"""Find or terminate only GUI instances of one installed DisplayMind bundle."""

import argparse
import os
from pathlib import Path
import signal
import subprocess
import sys


HEADLESS_MODES = {"--render-preview", "--watchdog", "--diagnostics"}


def is_installed_gui(command, target):
    executable = str(target).rstrip("/") + "/Contents/MacOS/DisplayMind"
    command = command.strip()
    if not command.startswith(executable):
        return False
    arguments = command[len(executable):]
    if arguments and not arguments[0].isspace():
        return False
    modes = (argument.split("=", 1)[0] for argument in arguments.split())
    return not any(mode in HEADLESS_MODES or mode.startswith("--airplay") for mode in modes)


def parse_pids(output):
    return sorted({int(line) for line in output.splitlines() if line.strip().isdigit() and int(line) > 0})


def candidate_pids():
    result = subprocess.run(["/usr/bin/pgrep", "-x", "DisplayMind"], capture_output=True, text=True)
    if result.returncode == 1:
        return []
    if result.returncode != 0:
        raise RuntimeError("Could not inspect running DisplayMind processes.")
    return parse_pids(result.stdout)


def command_for_pid(pid):
    result = subprocess.run(["/bin/ps", "-ww", "-p", str(pid), "-o", "command="], capture_output=True, text=True)
    return result.stdout.strip() if result.returncode == 0 else ""


def matching_pids(target, candidates, read_command):
    return [pid for pid in candidates if is_installed_gui(read_command(pid), target)]


def terminate_matching(target, candidates, read_command, send_signal):
    # Re-read each PID immediately before signaling; a candidate may have exited or changed mode.
    for pid in matching_pids(target, candidates, read_command):
        if not is_installed_gui(read_command(pid), target):
            continue
        try:
            send_signal(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("target", type=Path)
    parser.add_argument("--terminate", action="store_true")
    args = parser.parse_args()
    target = args.target.absolute()
    try:
        candidates = candidate_pids()
        if args.terminate:
            terminate_matching(target, candidates, command_for_pid, os.kill)
        else:
            for pid in matching_pids(target, candidates, command_for_pid):
                print(pid)
    except (OSError, RuntimeError) as error:
        print(f"DisplayMind process check: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
