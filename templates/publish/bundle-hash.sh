#!/usr/bin/env bash
# Hash the canonical compact JSON eastsea-bundle/1 index (design 31 section 4.2).
set -euo pipefail
if [[ $# -lt 1 || $# -gt 2 || ( $# -eq 2 && "$2" != "--index" ) ]]; then
  echo "usage: $0 <bundle-dir> [--index]" >&2
  exit 2
fi
root=$(cd "$(dirname "$0")/../.." && pwd -P)
if [[ "${2:-}" == "--index" ]]; then
  python3 "$root/scripts/publish.py" --hash-bundle "$1" --index
fi
python3 "$root/scripts/publish.py" --hash-bundle "$1"
