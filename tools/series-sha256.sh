#!/usr/bin/env bash
# Print the patch_series_sha256: sha256 over the concatenated contents of every
# patch listed in patches/series, in series order (comments/blank lines ignored).
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/.." && pwd)
series=${1:-$root/patches/series}
dir=$(dirname "$series")
while IFS= read -r line || [ -n "$line" ]; do
  line=${line%$'\r'}
  case "$line" in ''|'#'*) continue;; esac
  cat "$dir/$line"
done < "$series" | sha256sum | cut -d' ' -f1
