#!/usr/bin/env bash
# series-sha.sh [series-file]
#
# Print patch_series_sha256, the identity of the patch series.
#
# Algorithm (identical to the Vibepollo repo):
#   sha256 over the byte stream
#       [ bytes of patches/series with LF line endings (CR removed) ]
#       [ bytes of each patch file named in the series, in series order,
#         exactly as stored (no newline conversion) ]
# "Named in the series" = every line that is not blank and does not start with '#'.
# Group markers and comments are part of the first segment, so they are hashed
# too: switching a group marker changes the series identity.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
series=${1:-$here/../patches/series}
dir=$(cd "$(dirname "$series")" && pwd)
{
  tr -d '\r' < "$series"
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    case "$line" in ''|'#'*) continue;; esac
    cat "$dir/$line"
  done < <(tr -d '\r' < "$series")
} | sha256sum | cut -d' ' -f1
