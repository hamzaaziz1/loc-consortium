#!/usr/bin/env bash
# Fails if any tracked file contains a CRLF line ending.
# WSL + Windows editors reintroduce these constantly and Besu config parsing,
# PEM files and shell shebangs all break in ways that look like other bugs.
set -euo pipefail

bad=0
while IFS= read -r f; do
  [[ -f "$f" ]] || continue
  if file "$f" | grep -q "CRLF"; then
    echo "CRLF line endings: $f"
    bad=1
  fi
done < <(git ls-files)

if [[ "$bad" -ne 0 ]]; then
  echo
  echo "fix with: git add --renormalize . && git commit"
  exit 1
fi

echo "no CRLF found in tracked files"
