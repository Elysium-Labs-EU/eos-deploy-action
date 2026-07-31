#!/usr/bin/env bash
# Fails if the diff against BASE_REF adds/modifies a file larger than
# FILE_SIZE_LIMIT bytes that isn't tracked via Git LFS.
set -euo pipefail

BASE_REF="${1:?usage: check-large-files.sh <base-ref>}"
FILE_SIZE_LIMIT="${FILE_SIZE_LIMIT:-1048576}" # 1 MiB

changed_files=$(git diff --name-only --diff-filter=ACMR "${BASE_REF}...HEAD")

if [ -z "$changed_files" ]; then
  echo "No added/modified files in diff; nothing to check."
  exit 0
fi

failed=0

while IFS= read -r file; do
  [ -f "$file" ] || continue

  if git check-attr filter -- "$file" | grep -q 'filter: lfs$'; then
    continue
  fi

  size=$(wc -c <"$file" | tr -d ' ')

  if [ "$size" -gt "$FILE_SIZE_LIMIT" ]; then
    echo "FAIL: '$file' is $size bytes, exceeding the $FILE_SIZE_LIMIT byte limit and is not tracked via Git LFS."
    failed=1
  fi
done <<<"$changed_files"

if [ "$failed" -ne 0 ]; then
  echo ""
  echo "Large file(s) detected. Track them with Git LFS ('git lfs track <path>') or keep them out of the repo."
  exit 1
fi

echo "No oversized files found."
