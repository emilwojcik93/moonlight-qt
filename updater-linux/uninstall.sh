#!/bin/sh
# Remove the updater program and units. Leaves the installed Moonlight client, its state and policy in place unless
# --purge is given. Never touches DIR/.config/"Moonlight Game Streaming Project".
#   ./uninstall.sh [--prefix DIR] [--purge]
set -eu
prefix=${HOME:-}
purge=0
while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) prefix=$2; shift 2 ;;
    --purge) purge=1; shift ;;
    *) echo "uninstall.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$prefix" in /*) ;; *) echo "uninstall.sh: prefix must be absolute" >&2; exit 2 ;; esac
real_home=$(cd "${HOME:-/nonexistent}" 2>/dev/null && pwd -P || echo "")
prefix=$(cd "$prefix" && pwd -P)
if [ "$prefix" = "$real_home" ] && command -v systemctl >/dev/null 2>&1; then
  systemctl --user disable --now moonlight-posture-update.timer 2>/dev/null || true
fi
rm -f "$prefix/.config/systemd/user/moonlight-posture-update.service" "$prefix/.config/systemd/user/moonlight-posture-update.timer"
rm -rf "$prefix/.local/lib/moonlight-posture-updater" "$prefix/.local/share/doc/moonlight-posture-updater"
rm -f "$prefix/.local/bin/moonlight-posture-update"
if [ "$purge" = 1 ]; then
  rm -rf "$prefix/.local/opt/moonlight-posture" "$prefix/.local/state/moonlight-posture-updater" \
    "$prefix/.config/moonlight-posture-updater" "$prefix/.local/bin/moonlight-posture" \
    "$prefix/.local/share/applications/moonlight-posture.desktop"
fi
echo "removed updater from $prefix$([ "$purge" = 1 ] && echo ' (purged client, state and policy)')"
