#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
COUNT="${1:-1000}"
ROOT="${2:-$ROOT_DIR/.build/file-browser-fixture-$COUNT}"

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
  printf '# Document %04d\n\nDeterministic Mindle file-browser benchmark fixture.\n' "$i" \
    > "$dir/document-$(printf '%04d' "$i").md"
done

mkdir -p "$ROOT/.hidden" "$ROOT/unsupported-only"
printf '# Hidden\n' > "$ROOT/.hidden/hidden.md"
printf 'unsupported\n' > "$ROOT/unsupported-only/ignored.json"
printf 'plain text fixture\n' > "$ROOT/readme.txt"

git -C "$ROOT" init -q
git -C "$ROOT" config user.name "Mindle Benchmark"
git -C "$ROOT" config user.email "benchmark@mindle.local"
git -C "$ROOT" add .
GIT_AUTHOR_DATE="2024-01-02T03:04:05Z" \
GIT_COMMITTER_DATE="2024-01-02T03:04:05Z" \
  git -C "$ROOT" commit -qm "fixture"

for ((i = 0; i < 10 && i < COUNT; i++)); do
  section=$((i % 20))
  chapter=$(((i / 20) % 10))
  file="$ROOT/section-$(printf '%02d' "$section")/chapter-$(printf '%02d' "$chapter")/document-$(printf '%04d' "$i").md"
  printf '\nWorking tree change %04d.\n' "$i" >> "$file"
done
for ((i = 0; i < 10; i++)); do
  printf '# Untracked %02d\n' "$i" > "$ROOT/untracked-$(printf '%02d' "$i").md"
done

printf '%s\n' "$ROOT"
