#!/usr/bin/env bash
# CI and local builds target the checksum-verified official stock kernel.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
python3 -B -m unittest discover -s "$root/kernel/tests" -p 'test_*.py'
exec bash "$root/kernel/build-stock-scanout.sh" "$@"
