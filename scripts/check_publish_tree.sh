#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "not a git repository: $root" >&2
  exit 2
fi

fail=0
max_bytes=$((10 * 1024 * 1024))

while IFS= read -r -d '' file; do
  case "$file" in
    build/*|output/*|backups/*|work/*|latest_backup.txt)
      echo "blocked local asset path: $file" >&2
      fail=1
      ;;
    *.win|*.bps|*.xdelta|*.mp4|*.exe|*.dll|*.ttf|*.otf)
      echo "blocked binary asset: $file" >&2
      fail=1
      ;;
    verify/*.gml|verify/**/*.gml)
      echo "blocked decompiled GML dump: $file" >&2
      fail=1
      ;;
  esac

  if [ -f "$file" ]; then
    size="$(wc -c < "$file")"
    if [ "$size" -gt "$max_bytes" ]; then
      echo "large file over 10 MiB: $file ($size bytes)" >&2
      fail=1
    fi
  fi
done < <(git ls-files -z --cached --others --exclude-standard)

if [ "$fail" -ne 0 ]; then
  echo "publish tree check failed" >&2
  exit 1
fi

echo "publish tree check passed"
