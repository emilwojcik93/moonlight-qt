#!/usr/bin/env bash
# Regression tests for apply-series.sh, rot-matrix.sh and series-sha.sh.
# Self-contained: builds a tiny throw-away repo and series, touches nothing else.
#   tools/tests/test-tools.sh
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
tools=$(cd "$here/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/tools-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

pass=0 failn=0
ok()   { pass=$((pass+1)); echo "ok   - $1"; }
bad()  { failn=$((failn+1)); echo "FAIL - $1"; }
check() { # description, command...
  local d=$1; shift
  if "$@"; then ok "$d"; else bad "$d"; fi
}

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
repo="$tmp/repo"; mkdir "$repo"; cd "$repo"
git init -q -b main .
git config core.autocrlf false
printf 'one\n' > a.txt; git add a.txt; git commit -q -m base
base=$(git rev-parse HEAD)

# two patches: 0001 edits a.txt, 0002 adds b.txt
printf 'one\ntwo\n' > a.txt; git commit -q -am p1
printf 'bee\n' > b.txt; git add b.txt; git commit -q -m p2
good=$(git rev-parse HEAD)
git branch ref-good "$good"
mkdir "$tmp/series"
git format-patch -q --no-signature --zero-commit -o "$tmp/series" "$base..$good"
( cd "$tmp/series" && printf '# group: g1\n%s\n# group: g2\n%s\n' "$(ls 0001*)" "$(ls 0002*)" > series )
git checkout -q -b other "$base"; printf 'other\n' > c.txt; git add c.txt; git commit -q -m other
git branch ref-other
git checkout -q main
# a base where patch 0002 cannot apply (b.txt already exists with other content)
git checkout -q -b conflict "$base"; printf 'zzz\n' > b.txt; git add b.txt; git commit -q -m conflictbase; git checkout -q main
git branch keepme "$base"
keepme_before=$(git rev-parse keepme)
A=("$tools/apply-series.sh" --series "$tmp/series/series")
nwt() { git worktree list | wc -l | tr -d ' '; }

# 1. verify mismatch with --keep-branch leaves nothing behind (exit 2)
"${A[@]}" "$base" --keep-branch out1 --verify ref-other --quiet >/dev/null 2>&1; rc=$?
check "verify mismatch exits 2" test "$rc" = 2
check "verify mismatch creates no branch" bash -c '! git rev-parse --verify -q refs/heads/out1 >/dev/null'
"${A[@]}" "$base" --keep-branch keepme --verify ref-other --quiet >/dev/null 2>&1
check "verify mismatch does not move an existing branch" test "$(git rev-parse keepme)" = "$keepme_before"
check "no leftover worktree after mismatch" test "$(nwt)" = 1

# 2. verify match creates the branch at the verified tree
"${A[@]}" "$base" --keep-branch out2 --verify ref-good --quiet >/dev/null 2>&1; rc=$?
check "verify match exits 0" test "$rc" = 0
check "verify match creates branch with equal tree" test "$(git rev-parse out2^{tree} 2>/dev/null)" = "$(git rev-parse ref-good^{tree})"

# 3. conflict: exit 1, no branch, no worktree, report written
"${A[@]}" conflict --keep-branch out3 --report "$tmp/rep.md" --quiet >/dev/null 2>&1; rc=$?
check "conflict exits 1" test "$rc" = 1
check "conflict creates no branch" bash -c '! git rev-parse --verify -q refs/heads/out3 >/dev/null'
check "conflict writes report naming the patch" grep -q '0002' "$tmp/rep.md"
check "no leftover worktree after conflict" test "$(nwt)" = 1

# 4. --skip-group
"${A[@]}" "$base" --skip-group g2 --verify "$good~1" --quiet >/dev/null 2>&1; rc=$?
check "--skip-group g2 equals first patch only" test "$rc" = 0

# 5. --prefix-check
out=$("${A[@]}" "$base" --prefix-check --keep-branch pc 2>&1); rc=$?
check "prefix-check success exits 0" test "$rc" = 0
check "prefix-check creates one branch per prefix" bash -c 'git rev-parse --verify -q refs/heads/pc-p01 >/dev/null && git rev-parse --verify -q refs/heads/pc-p02 >/dev/null'
check "prefix-check last prefix equals result" test "$(git rev-parse pc-p02^{tree})" = "$(git rev-parse pc^{tree})"
out=$("${A[@]}" conflict --prefix-check --keep-branch pcf 2>&1); rc=$?
check "prefix-check failure exits 1" test "$rc" = 1
check "prefix-check names the failing prefix" bash -c 'echo "$0" | grep -q "prefix 2/2 FAILS"' "$out"
check "prefix-check reports passing prefix 1" bash -c 'echo "$0" | grep -q "prefix 1/2 OK"' "$out"
check "prefix-check failure leaves no branches" bash -c '! git rev-parse --verify -q refs/heads/pcf-p01 >/dev/null'
check "no leftover worktree after prefix-check" test "$(nwt)" = 1

# 6. series-sha: CRLF-insensitive series, sensitive to patch bytes and order
h1=$("$tools/series-sha.sh" "$tmp/series/series")
mkdir "$tmp/series2"; cp "$tmp/series"/* "$tmp/series2/"
sed 's/$/\r/' "$tmp/series/series" > "$tmp/series2/series"
h2=$("$tools/series-sha.sh" "$tmp/series2/series")
check "series-sha ignores CRLF in the series file" test "$h1" = "$h2"
expect=$( { tr -d '\r' < "$tmp/series/series"; cat "$tmp/series"/0001*; cat "$tmp/series"/0002*; } | sha256sum | cut -d' ' -f1)
check "series-sha = sha256(series LF + patches in order)" test "$h1" = "$expect"
echo "x" >> "$tmp/series2/0002"*.patch
check "series-sha changes when a patch changes" test "$h1" != "$("$tools/series-sha.sh" "$tmp/series2/series")"

echo "passed=$pass failed=$failn"
[ "$failn" -eq 0 ]
