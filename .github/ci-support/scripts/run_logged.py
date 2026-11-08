#!/usr/bin/env python3
"""CI stand-in for the author's private ios-build-support run_logged.py.

Runs a command, streams its output to the console and a log file, and stops it
after --timeout seconds. Usage: run_logged.py --log PATH --label NAME --timeout SECONDS -- CMD...
"""
import argparse
import subprocess
import sys
import threading
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--log", required=True)
    parser.add_argument("--label", default="command")
    parser.add_argument("--timeout", type=float, default=3600)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("a command is required after --")

    log_path = Path(args.log)
    log_path.parent.mkdir(parents=True, exist_ok=True)
    print(f"::group::{args.label}", flush=True)
    with log_path.open("w", encoding="utf-8", errors="replace") as log:
        process = subprocess.Popen(
            command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace"
        )
        timed_out = threading.Event()

        def stop() -> None:
            timed_out.set()
            process.kill()

        timer = threading.Timer(args.timeout, stop)
        timer.start()
        try:
            assert process.stdout is not None
            for line in process.stdout:
                sys.stdout.write(line)
                log.write(line)
            status = process.wait()
        finally:
            timer.cancel()
        if timed_out.is_set():
            print(f"{args.label} timed out after {args.timeout:.0f}s", file=sys.stderr)
            status = 124
    print("::endgroup::", flush=True)
    return status


if __name__ == "__main__":
    sys.exit(main())
