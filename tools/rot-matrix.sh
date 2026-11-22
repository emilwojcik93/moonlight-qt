#!/usr/bin/env bash
# rot-matrix.sh [N] [options]
#
# Dry-run the patch series against the last N upstream v6.2.0-daily.* tags
# (default 5) plus upstream master, and print a pass/fail table. Uses
# apply-series.sh (temp worktrees only); no real branch is touched, nothing is
# pushed. Each target is tried twice: the full series and posture-core only
# (--skip-group touch-menu), because the two groups rot independently.
#
# Options:
#   --remote <name>      upstream remote (default: $UPSTREAM_REMOTE or "upstream")
#   --tag-glob <glob>    tag pattern (default: 'v6.2.0-daily.*')
#   --master <ref>       master ref (default: <remote>/master)
#   --floor <tag>        oldest tag the series is expected to apply to; failures on older
#                        tags are shown as "FAIL*" and do not affect the exit code
#   --fetch              git fetch <remote> master + tags first (network)
#   --out <file>         also write the table as markdown to <file>
#   -h, --help
#
# Exit code: 0 if every target applies the full series, 1 if any target fails.
# Run from inside the fork clone (needs the upstream remote's tags locally).
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
apply="$here/apply-series.sh"
remote=${UPSTREAM_REMOTE:-upstream}
glob='v6.2.0-daily.*'
n=5 master="" out="" do_fetch=0 floor=""

die() { echo "rot-matrix: $*" >&2; exit 3; }

while [ $# -gt 0 ]; do
  case "$1" in
    --remote) [ $# -ge 2 ] || die "--remote needs a value"; remote=$2; shift 2;;
    --tag-glob) [ $# -ge 2 ] || die "--tag-glob needs a value"; glob=$2; shift 2;;
    --master) [ $# -ge 2 ] || die "--master needs a value"; master=$2; shift 2;;
    --floor) [ $# -ge 2 ] || die "--floor needs a value"; floor=$2; shift 2;;
    --out) [ $# -ge 2 ] || die "--out needs a value"; out=$2; shift 2;;
    --fetch) do_fetch=1; shift;;
    -h|--help) sed -n '2,/^set -uo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0;;
    -*) die "unknown option: $1";;
    *) case "$1" in ''|*[!0-9]*) die "N must be a positive integer";; esac; n=$1; shift;;
  esac
done
[ -n "$master" ] || master="$remote/master"
git rev-parse --git-dir >/dev/null 2>&1 || die "not inside a git repository"

if [ "$do_fetch" = 1 ]; then
  git fetch --quiet "$remote" master --tags || die "fetch failed"
fi

tags=$(git tag -l "$glob" | sort -V | tail -n "$n" | sort -Vr)
[ -n "$tags" ] || die "no tags match $glob (run with --fetch?)"
git rev-parse --verify --quiet "$master^{commit}" >/dev/null || die "cannot resolve $master"

run_one() { # ref skipflag -> sets status, detail
  local ref=$1; shift
  local log; log=$(mktemp "${TMPDIR:-/tmp}/rot.XXXXXX")
  if bash "$apply" "$ref" --quiet "$@" >"$log" 2>&1; then
    status=PASS; detail=""
  else
    status=FAIL
    detail=$(awk '/^FAIL /{p=$3} /conflicting files:/{c=1;next} c&&/^    /{f=f" "$1} /^RESULT/{c=0} END{printf "%s%s", p, (f!=""?" ["substr(f,2)"]":"")}' "$log")
    [ -n "$detail" ] || detail=$(tail -n 1 "$log")
  fi
  rm -f "$log"
}

# true when <tag> sorts (version order) strictly before --floor; master never is
below_floor() {
  [ -n "$floor" ] || return 1
  [ "$1" != "$master" ] || return 1
  [ "$1" != "$floor" ] || return 1
  [ "$(printf '%s\n%s\n' "$1" "$floor" | sort -V | head -n 1)" = "$1" ]
}

rows=""
fails=0
printf '%-22s %-9s %-6s %-12s %s\n' target commit full posture-only detail
for ref in $tags "$master"; do
  sha=$(git rev-parse --short=9 "$ref^{commit}")
  label=$ref; [ "$ref" = "$master" ] && label="$master"
  run_one "$ref"; full=$status; fdetail=$detail
  run_one "$ref" --skip-group touch-menu; core=$status; cdetail=$detail
  if [ "$full" != PASS ]; then
    if below_floor "$ref"; then
      full="FAIL*"; [ "$core" = FAIL ] && core="FAIL*"
    else
      fails=$((fails+1))
    fi
  fi
  d=""
  [ -n "$fdetail" ] && d="full: $fdetail"
  [ -n "$cdetail" ] && d="$d${d:+; }core: $cdetail"
  printf '%-22s %-9s %-6s %-12s %s\n' "$label" "$sha" "$full" "$core" "$d"
  rows="$rows| \`$label\` | \`$sha\` | $full | $core | ${d:-}|
"
done

if [ -n "$out" ]; then
  {
    echo "| target | commit | full series | posture-core only | detail |"
    echo "|---|---|---|---|---|"
    printf '%s' "$rows"
  } > "$out"
  echo "table written: $out" >&2
fi
[ "$fails" -eq 0 ]
