#!/bin/sh
# Install the Linux patched-Moonlight updater into a prefix (default: $HOME). No root, no sudo.
#
#   ./install.sh [--prefix DIR] [--enable]
#
# Writes only below DIR/.local/{bin,lib,share,state,opt} and DIR/.config/{systemd/user,moonlight-posture-updater}.
# It NEVER touches DIR/.config/"Moonlight Game Streaming Project" (settings, pairing identity).
# It does not start or enable anything unless --enable is given (only allowed for the real $HOME).
# A fresh install creates policy.json with mode=report-only: the timer only reports "would install <tag>" until you
# have run `moonlight-posture-update verify-only` and then `moonlight-posture-update set-mode install`.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
prefix=${HOME:-}
enable=0
while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) [ $# -ge 2 ] || { echo "install.sh: --prefix needs a value" >&2; exit 2; }; prefix=$2; shift 2 ;;
    --enable) enable=1; shift ;;
    -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "install.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$prefix" ] || { echo "install.sh: no prefix and HOME is unset" >&2; exit 2; }
case "$prefix" in /*) ;; *) echo "install.sh: prefix must be an absolute path" >&2; exit 2 ;; esac
# the prefix ends up in sed expressions and unit files: only plain path characters
if [ "$(printf '%s' "$prefix" | tr -d 'A-Za-z0-9._/-' | wc -c)" -ne 0 ] || [ "$(printf '%s' "$prefix" | wc -l)" -ne 0 ]; then
  echo "install.sh: prefix may only contain [A-Za-z0-9._/-]" >&2; exit 2
fi
mkdir -p "$prefix"
prefix=$(cd "$prefix" && pwd -P)

py=$(command -v python3 || true)
[ -n "$py" ] || { echo "install.sh: python3 not found" >&2; exit 1; }
"$py" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' || { echo "install.sh: python >= 3.9 required" >&2; exit 1; }
for f in bin/moonlight-posture-update systemd/moonlight-posture-update.service systemd/moonlight-posture-update.timer moonlight_posture_update/cli.py; do
  [ -f "$here/$f" ] || { echo "install.sh: missing $here/$f" >&2; exit 1; }
done

lib="$prefix/.local/lib/moonlight-posture-updater"
bindir="$prefix/.local/bin"
unitdir="$prefix/.config/systemd/user"
docdir="$prefix/.local/share/doc/moonlight-posture-updater"

# the units use %h; for a prefix that is not the real home, write absolute paths instead
real_home=$(cd "${HOME:-/nonexistent}" 2>/dev/null && pwd -P || echo "")
subst() { if [ "$prefix" = "$real_home" ]; then cat; else sed "s|%h|$prefix|g"; fi; }

umask 022
mkdir -p "$lib/moonlight_posture_update" "$bindir" "$unitdir" "$docdir" \
  "$prefix/.local/share/applications" "$prefix/.local/opt/moonlight-posture"
mkdir -p -m 700 "$prefix/.local/state/moonlight-posture-updater" "$prefix/.config/moonlight-posture-updater"

# replace the package atomically enough for a oneshot job: copy to a sibling dir, then swap
tmp="$lib/.new.$$"
rm -rf "$tmp"; mkdir -p "$tmp"
for f in "$here"/moonlight_posture_update/*.py; do install -m 644 "$f" "$tmp/$(basename "$f")"; done
rm -rf "$lib/moonlight_posture_update.old"
[ -d "$lib/moonlight_posture_update" ] && mv "$lib/moonlight_posture_update" "$lib/moonlight_posture_update.old"
mv "$tmp" "$lib/moonlight_posture_update"
rm -rf "$lib/moonlight_posture_update.old"

mkdir -p "$lib/bin"
install -m 755 "$here/bin/moonlight-posture-update" "$lib/bin/moonlight-posture-update"
# ~/.local/bin only holds symlinks, so the sandboxed job never needs write access to it
ln -sfn "$lib/bin/moonlight-posture-update" "$bindir/moonlight-posture-update"
ln -sfn "$prefix/.local/opt/moonlight-posture/launcher/moonlight-posture" "$bindir/moonlight-posture"
if [ ! -e "$prefix/.config/moonlight-posture-updater/policy.json" ]; then
  ( umask 077; printf '{\n "schema": 1,\n "mode": "report-only"\n}\n' > "$prefix/.config/moonlight-posture-updater/policy.json" )
fi
for u in moonlight-posture-update.service moonlight-posture-update.timer; do
  subst < "$here/systemd/$u" > "$unitdir/$u.new"
  chmod 644 "$unitdir/$u.new"
  mv "$unitdir/$u.new" "$unitdir/$u"
done
for d in README.md docs/LINUX-UPDATER.md; do
  [ -f "$here/$d" ] && install -m 644 "$here/$d" "$docdir/$(basename "$d")"
done

echo "installed into $prefix"
echo "  program : $lib, $bindir/moonlight-posture-update"
echo "  units   : $unitdir/moonlight-posture-update.{service,timer}"
command -v gh >/dev/null 2>&1 || echo "WARNING: gh (github-cli) not found; the updater needs it for attestation verification" >&2

if [ "$enable" = 1 ]; then
  [ "$prefix" = "$real_home" ] || { echo "install.sh: --enable is only allowed for the real home directory" >&2; exit 2; }
  systemctl --user daemon-reload
  systemctl --user enable --now moonlight-posture-update.timer
  echo "timer enabled; nothing is installed until policy.json says mode=install (currently: $(grep -o '"mode": *"[a-z-]*"' "$prefix/.config/moonlight-posture-updater/policy.json" || echo unknown))"
else
  echo "not enabled. To enable:  systemctl --user daemon-reload && systemctl --user enable --now moonlight-posture-update.timer"
  echo "mode is report-only: rehearse with  $bindir/moonlight-posture-update verify-only  and switch with  $bindir/moonlight-posture-update set-mode install"
fi
