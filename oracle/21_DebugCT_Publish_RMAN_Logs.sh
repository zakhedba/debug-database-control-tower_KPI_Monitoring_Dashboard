#!/usr/bin/env bash
set -euo pipefail
# Example only. Set source/target explicitly; target should be a mounted share or secure transfer staging area.
SOURCE_DIR="${SOURCE_DIR:-}"
TARGET_DIR="${TARGET_DIR:-}"
DAYS="${DAYS:-7}"
if [[ -z "$SOURCE_DIR" || -z "$TARGET_DIR" ]]; then
  echo "Usage: SOURCE_DIR=/path/to/rman/logs TARGET_DIR=/mounted/controltower/RMAN_Logs $0" >&2
  exit 2
fi
mkdir -p "$TARGET_DIR"
find "$SOURCE_DIR" -type f -name '*.log' -mtime "-$DAYS" -print0 |
  while IFS= read -r -d '' f; do
    cp -p "$f" "$TARGET_DIR/"
  done
find "$TARGET_DIR" -type f -name '*.log' -mtime +30 -delete
printf 'RMAN log publish completed: %s\n' "$(date -Is)"
