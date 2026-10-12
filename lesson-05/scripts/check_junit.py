"""Fail the CI job when the JUnit report shows failures or too few executed tests."""
from __future__ import annotations

import argparse
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


def summarize(path: Path) -> dict[str, int]:
    """Sum tests, failures, errors and skipped across every suite in the report."""
    root = ET.parse(path).getroot()
    suites = [root] if root.tag == "testsuite" else list(root.iter("testsuite"))
    totals = {"tests": 0, "failures": 0, "errors": 0, "skipped": 0}
    for suite in suites:
        for key in totals:
            totals[key] += int(suite.get(key, "0"))
    return totals


def main() -> int:
    """Parse arguments, print a one-line verdict and return the process exit code."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report", type=Path)
    parser.add_argument("--min-tests", type=int, default=1)
    args = parser.parse_args()
    if not args.report.is_file():
        print(f"JUNIT FAIL: {args.report} does not exist")
        return 1
    totals = summarize(args.report)
    executed = totals["tests"] - totals["skipped"]
    problems: list[str] = []
    if totals["failures"] or totals["errors"]:
        problems.append(f"{totals['failures']} failures, {totals['errors']} errors")
    if executed < args.min_tests:
        problems.append(f"only {executed} tests executed, floor is {args.min_tests}")
    if problems:
        print("JUNIT FAIL: " + "; ".join(problems))
        return 1
    print(f"JUNIT OK: {executed} tests executed, 0 failures, 0 errors, {totals['skipped']} skipped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
