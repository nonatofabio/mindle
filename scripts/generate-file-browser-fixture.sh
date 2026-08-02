#!/usr/bin/env bash
set -euo pipefail

COUNT="${1:-1000}"
ROOT="${2:-$(mktemp -d "${TMPDIR:-/tmp}/mindle-file-browser.XXXXXX")}"

if ! [[ "$COUNT" =~ ^[1-9][0-9]*$ ]]; then
  echo "count must be a positive integer" >&2
  exit 2
fi

if [ -e "$ROOT" ] && [ -n "$(find "$ROOT" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
  echo "target directory must be empty: $ROOT" >&2
  exit 2
fi

mkdir -p "$ROOT"

for ((i = 0; i < COUNT; i++)); do
  section=$((i % 20))
  chapter=$(((i / 20) % 10))
  dir="$ROOT/section-$(printf '%02d' "$section")/chapter-$(printf '%02d' "$chapter")"
  mkdir -p "$dir"
  printf '# Document %04d\n\nFixture content for Mindle file-browser profiling.\n' "$i" \
    > "$dir/document-$(printf '%04d' "$i").md"
done

mkdir -p "$ROOT/.hidden" "$ROOT/unsupported-only"
printf '# Hidden\n' > "$ROOT/.hidden/hidden.md"
printf 'unsupported\n' > "$ROOT/unsupported-only/ignored.json"
printf 'plain text fixture\n' > "$ROOT/readme.txt"
printf '%s\n' "$ROOT"
