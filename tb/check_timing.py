#!/usr/bin/env python3
"""Reject failed or incomplete Quartus timing reports, even after exit status 0."""

import re
import sys
from decimal import Decimal
from pathlib import Path

METRICS = {"setup", "hold", "recovery", "removal", "minimum pulse width"}
SLACK = re.compile(
    r"^Info \(332146\): Worst-case ([a-z ]+) slack is (-?\d+(?:\.\d+)?)\s*$",
    re.MULTILINE,
)


def check_timing(report: str) -> None:
    if "Timing requirements not met" in report:
        raise ValueError("Quartus reports unmet timing requirements")
    seen = set()
    for metric, value in SLACK.findall(report):
        if metric not in METRICS:
            continue
        seen.add(metric)
        if Decimal(value) < 0:
            raise ValueError(f"negative {metric} slack: {value} ns")
    if seen != METRICS:
        raise ValueError(f"missing timing results: {', '.join(sorted(METRICS - seen))}")


if __name__ == "__main__":
    try:
        check_timing(Path(sys.argv[1]).read_text())
    except (IndexError, OSError, ValueError) as error:
        sys.exit(f"Timing check failed: {error}")
    print("PASS: setup, hold, recovery, removal and pulse-width timing")
