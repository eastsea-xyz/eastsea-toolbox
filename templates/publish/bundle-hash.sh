#!/usr/bin/env bash
# Canonical bundle hash for the EastSea app registry.
#
# manifest.bundle.sha256 = sha256 of the canonical bundle index, where the
# index is the sorted list of "<file-sha256>  <relative-path>" lines for every
# file in the bundle directory. Deterministic across machines: no timestamps,
# no modes, path-sorted.
#
# Usage:
#   templates/publish/bundle-hash.sh <bundle-dir>          # print index sha256
#   templates/publish/bundle-hash.sh <bundle-dir> --index  # also print the index itself
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <bundle-dir> [--index]" >&2
  exit 2
fi

dir=$1
show_index=0
[[ "${2:-}" == "--index" ]] && show_index=1

if [[ ! -d "$dir" ]]; then
  echo "error: not a directory: $dir" >&2
  exit 2
fi

# find | sort: canonical path order; sha -r on BSD vs sha256sum on GNU
index=$(
  cd "$dir"
  find . -type f ! -name '.DS_Store' | sed 's|^\./||' | LC_ALL=C sort | while IFS= read -r f; do
    if command -v sha256sum >/dev/null 2>&1; then
      printf '%s  %s\n' "$(sha256sum "$f" | cut -d' ' -f1)" "$f"
    else
      printf '%s  %s\n' "$(shasum -a 256 "$f" | cut -d' ' -f1)" "$f"
    fi
  done
)

if [[ $show_index -eq 1 ]]; then
  printf '%s\n' "$index"
  echo "---"
fi

printf '0x%s\n' "$(printf '%s\n' "$index" | shasum -a 256 2>/dev/null | cut -d' ' -f1 || printf '%s\n' "$index" | sha256sum | cut -d' ' -f1)"
