#!/usr/bin/env python3
"""CI stand-in for the author's private check_xcode_toolchain.py.

Fails with a clear message when the selected Xcode or iOS SDK is older than required.
"""
import argparse
import re
import subprocess
import sys


def version(text: str) -> tuple[int, ...]:
    match = re.search(r"(\d+(?:\.\d+)*)", text)
    if not match:
        raise ValueError(f"no version in {text!r}")
    return tuple(int(part) for part in match.group(1).split("."))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--minimum-xcode", required=True)
    parser.add_argument("--minimum-ios-sdk", required=True)
    args = parser.parse_args()

    xcode_line = subprocess.check_output(["xcodebuild", "-version"], text=True).splitlines()[0]
    sdk = subprocess.check_output(["xcrun", "--sdk", "iphoneos", "--show-sdk-version"], text=True).strip()
    print(f"Selected {xcode_line}, iOS SDK {sdk}")

    problems = []
    if version(xcode_line) < version(args.minimum_xcode):
        problems.append(f"Xcode {args.minimum_xcode} or later is required")
    if version(sdk) < version(args.minimum_ios_sdk):
        problems.append(f"iOS SDK {args.minimum_ios_sdk} or later is required")
    for problem in problems:
        print(f"error: {problem}", file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
