#!/usr/bin/env bash
# apply-series.sh <ref> [options]
#
# Apply patches/series onto <ref> (tag, branch or commit) in a throw-away git
# worktree with `git am --3way`, optionally compare the result to a reference.
# Nothing is left behind (temp worktree only) unless --keep-branch is given.
#
# Options:
#   --verify <reference>    after applying, require the resulting tree hash to equal
#                           <reference>^{tree}; exit 2 on mismatch
#   --skip-group <name>     do not apply the patches of group <name> (repeatable,
#                           e.g. --skip-group touch-menu)
#   --keep-branch <name>    create/overwrite local branch <name> at the result
#                           (used by the pipeline to build upstream + patches)
#   --report <file>         on failure write a markdown report (patch, files, hunks)
#   --series <file>         series file (default: <script dir>/../patches/series)
#   --quiet                 only print the final result line
#   -h, --help
#
# Exit codes: 0 ok, 1 a patch failed to apply (conflict), 2 --verify mismatch,
#             3 usage or environment error.
#
# Run from inside a git repository that contains <ref> (the fork clone with the
# upstream remote fetched). The series itself is read from the script location,
# so it works from a checkout of the automation branch or any git worktree.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
series="$here/../patches/series"
ref="" verify="" report="" keep_branch="" quiet=0
skip_groups=()

usage() { sed -n '2,/^set -uo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }
die() { echo "apply-series: $*" >&2; exit 3; }
say() { [ "$quiet" = 1 ] || echo "$@"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --verify) [ $# -ge 2 ] || die "--verify needs a value"; verify=$2; shift 2;;
    --skip-group) [ $# -ge 2 ] || die "--skip-group needs a value"; skip_groups+=("$2"); shift 2;;
    --keep-branch) [ $# -ge 2 ] || die "--keep-branch needs a value"; keep_branch=$2; shift 2;;
    --report) [ $# -ge 2 ] || die "--report needs a value"; report=$2; shift 2;;
    --series) [ $# -ge 2 ] || die "--series needs a value"; series=$2; shift 2;;
    --quiet) quiet=1; shift;;
    -h|--help) usage; exit 0;;
    -*) die "unknown option: $1";;
    *) [ -z "$ref" ] || die "unexpected argument: $1"; ref=$1; shift;;
  esac
done
[ -n "$ref" ] || { usage >&2; exit 3; }
[ -f "$series" ] || die "series file not found: $series"
series_dir=$(cd "$(dirname "$series")" && pwd)
git rev-parse --git-dir >/dev/null 2>&1 || die "not inside a git repository"

# Deterministic, platform independent behaviour: no CRLF conversion, no signing,
# no hooks, fixed identity when none is configured.
G=(git -c core.autocrlf=false -c core.safecrlf=false -c core.hooksPath=/dev/null -c commit.gpgsign=false)
: "${GIT_COMMITTER_NAME:=$(git config user.name 2>/dev/null || true)}"
: "${GIT_COMMITTER_EMAIL:=$(git config user.email 2>/dev/null || true)}"
[ -n "$GIT_COMMITTER_NAME" ] || GIT_COMMITTER_NAME="patch-pipeline"
[ -n "$GIT_COMMITTER_EMAIL" ] || GIT_COMMITTER_EMAIL="patch-pipeline@localhost"
export GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL

base=$("${G[@]}" rev-parse --verify --quiet "$ref^{commit}") || die "cannot resolve ref: $ref"
ref_tree=""
if [ -n "$verify" ]; then
  ref_tree=$("${G[@]}" rev-parse --verify --quiet "$verify^{tree}") || die "cannot resolve --verify reference: $verify"
fi

# --- parse series into (group|patch) entries ---------------------------------
patches=()
group="default"
while IFS= read -r line || [ -n "$line" ]; do
  line=${line%$'\r'}
  case "$line" in
    '') continue;;
    '# group:'*) group=$(echo "${line#\# group:}" | tr -d '[:space:]'); continue;;
    '#'*) continue;;
  esac
  skip=0
  for g in ${skip_groups[@]+"${skip_groups[@]}"}; do
    [ "$g" = "$group" ] && skip=1
  done
  if [ "$skip" = 1 ]; then say "skip   [$group] $line"; continue; fi
  [ -f "$series_dir/$line" ] || die "patch listed in series is missing: $line"
  patches+=("$group|$line")
done < "$series"

# --- temp worktree, always cleaned up ----------------------------------------
tmp=$(mktemp -d "${TMPDIR:-/tmp}/apply-series.XXXXXX") || die "mktemp failed"
wt="$tmp/wt"
cleanup() {
  if [ -d "$wt" ]; then
    "${G[@]}" -C "$wt" am --abort >/dev/null 2>&1 || true
    "${G[@]}" worktree remove --force "$wt" >/dev/null 2>&1 || true
  fi
  rm -rf "$tmp" 2>/dev/null || true
  "${G[@]}" worktree prune >/dev/null 2>&1 || true
}
trap cleanup EXIT
trap 'exit 130' INT TERM

"${G[@]}" worktree add --quiet --detach "$wt" "$base" >/dev/null 2>&1 || die "git worktree add failed for $ref"
say "base   $ref -> $base"

for entry in ${patches[@]+"${patches[@]}"}; do
  g=${entry%%|*}; p=${entry#*|}
  if out=$("${G[@]}" -C "$wt" am --3way --quiet "$series_dir/$p" 2>&1); then
    say "ok     [$g] $p"
    continue
  fi
  echo "FAIL   [$g] $p" >&2
  conflicts=$("${G[@]}" -C "$wt" diff --name-only --diff-filter=U 2>/dev/null)
  echo "git am output:" >&2
  echo "$out" | sed 's/^/    /' >&2
  if [ -n "$conflicts" ]; then
    echo "conflicting files:" >&2
    echo "$conflicts" | sed 's/^/    /' >&2
  else
    echo "no unmerged paths (patch rejected before the 3-way merge; context missing)" >&2
  fi
  if [ -n "$report" ]; then
    fence='```'
    {
      echo "# apply-series failure"
      echo
      echo "- ref: \`$ref\` ($base)"
      echo "- group: \`$g\`"
      echo "- patch: \`$p\`"
      echo
      echo "## git am output"; echo "$fence"; echo "$out"; echo "$fence"
      echo
      echo "## conflicting files"; echo "$fence"; echo "${conflicts:-none unmerged}"; echo "$fence"
      echo
      echo "## conflict hunks (truncated to 400 lines)"; echo "${fence}diff"
      "${G[@]}" -C "$wt" diff 2>/dev/null | head -n 400
      echo "$fence"
    } > "$report"
    echo "report written: $report" >&2
  fi
  echo "RESULT FAIL ref=$ref base=$base patch=$p group=$g" >&2
  exit 1
done

result=$("${G[@]}" -C "$wt" rev-parse HEAD)
result_tree=$("${G[@]}" -C "$wt" rev-parse 'HEAD^{tree}')

if [ -n "$keep_branch" ]; then
  "${G[@]}" branch -f "$keep_branch" "$result" >/dev/null 2>&1 || die "cannot create branch $keep_branch"
  say "branch $keep_branch -> $result"
fi

if [ -n "$verify" ]; then
  if [ "$result_tree" = "$ref_tree" ]; then
    echo "RESULT OK ref=$ref base=$base tree=$result_tree verified-equal-to=$verify"
    exit 0
  fi
  echo "tree mismatch: result $result_tree != $verify $ref_tree" >&2
  echo "differing paths (result vs $verify):" >&2
  "${G[@]}" diff --name-status "$result_tree" "$ref_tree" 2>&1 | sed 's/^/    /' >&2
  echo "RESULT MISMATCH ref=$ref base=$base tree=$result_tree expected=$ref_tree" >&2
  exit 2
fi
echo "RESULT OK ref=$ref base=$base tree=$result_tree commit=$result"
exit 0
