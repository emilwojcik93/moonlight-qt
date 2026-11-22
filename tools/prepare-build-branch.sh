#!/usr/bin/env bash
# Break-glass / first-release path: prepare and push build/<tag>-nN from the operator machine.
# Usage: tools/prepare-build-branch.sh [--dry-run] [--tag v6.2.0-daily.U] [--remote origin]
#        (see ci/prepare_build_branch.py).  Windows: export GIT_SSH_COMMAND=C:/Windows/System32/OpenSSH/ssh.exe
# Picks the first interpreter that really runs Python >= 3.8 (python3, python, py -3); the Microsoft Store
# "python3" alias exists on Windows but fails when executed, so presence alone is not enough.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
probe='import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)'
py=()
for cand in "python3" "python" "py -3"; do
  # shellcheck disable=SC2206
  words=($cand)
  if command -v "${words[0]}" > /dev/null 2>&1 && "${words[@]}" -c "$probe" > /dev/null 2>&1; then
    py=("${words[@]}")
    break
  fi
done
if [ "${#py[@]}" -eq 0 ]; then
  echo "prepare-build-branch: no working Python >= 3.8 found (tried python3, python, py -3)" >&2
  exit 127
fi
exec "${py[@]}" "$here/../ci/prepare_build_branch.py" --root "$here/.." "$@"
