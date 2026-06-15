#!/usr/bin/env bash
#
# Regression tests for z.sh.
#
# Focus: the multi-keyword / "common prefix" behavior (see the "Common:"
# section of the man page) must take you to the single best match and keep
# the listing, the -e output and the directory you actually cd into in
# agreement. The historical "jump to the common ancestor" behavior is now
# opt-in via $_Z_KEEP_COMMON. The ranking, recency, case and ordering rules
# must keep working either way.
#
# Run with:  ./test.sh   (or: make test)

here=$(cd "$(dirname "$0")" && pwd)
ZSH="$here/z.sh"

# a clean sandbox, independent of the user's real ~/.z and environment
unset _Z_EXCLUDE_DIRS _Z_OWNER _Z_CMD _Z_MAX_SCORE
export _Z_NO_PROMPT_COMMAND=1
export _Z_KEEP_COMMON=        # off by default; turned on per-call in subshells
root=$(mktemp -d "${TMPDIR:-/tmp}/z-test.XXXXXX") || exit 1
export _Z_DATA="$root/.z"
trap 'rm -rf "$root"' EXIT

# shellcheck source=/dev/null
. "$ZSH"

now=$(date +%s)
old=$((now - 100000))

# build every directory the scenarios need; each scenario then selects a
# subset by writing only the relevant entries into the datafile.
mkdir -p \
    "$root/work/project" "$root/work/project/src" \
    "$root/srv/app" "$root/srv/app-data" \
    "$root/foo/bar" "$root/bar/foo" \
    "$root/r/alpha" "$root/r/beta" \
    "$root/t/recent" "$root/t/freq" \
    "$root/Projects/Code" \
    "$root/a/code" "$root/b/Code"

pass=0 fail=0

ok() { pass=$((pass + 1)); printf 'ok   - %s\n' "$1"; }
bad() {
    fail=$((fail + 1))
    printf 'FAIL - %s\n        got:  [%s]\n        want: [%s]\n' "$1" "$2" "$3"
}
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }
has() { case "$2" in *"$3"*) ok "$1";; *) bad "$1" "$2" "should contain: $3";; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1" "$2" "should NOT contain: $3";; *) ok "$1";; esac; }

# replace the datafile contents from stdin ("path|rank|time" per line)
setdata() { cat > "$_Z_DATA"; }

# drivers. echo -> stdout; list -> stderr; go -> pwd after the cd.
zecho() { _z -e "$@" 2>/dev/null; }
zlist() { _z -l "$@" 2>&1 >/dev/null; }
zgo() { ( cd "$root" || exit; _z "$@" >/dev/null 2>&1; pwd ); }
# same, with the historical common-ancestor behavior enabled (isolated in a
# subshell so the env var never leaks into later cases)
zecho_kc() { ( export _Z_KEEP_COMMON=1; _z -e "$@" 2>/dev/null ); }
zlist_kc() { ( export _Z_KEEP_COMMON=1; _z -l "$@" 2>&1 >/dev/null ); }
zgo_kc() { ( cd "$root" || exit; export _Z_KEEP_COMMON=1; _z "$@" >/dev/null 2>&1; pwd ); }

echo "# Scenario 1: multi-keyword should reach the specific dir, not the parent"
setdata <<EOF
$root/work/project|1|$now
$root/work/project/src|50|$now
EOF
eq  "default: -e returns the specific dir"          "$(zecho work project)"          "$root/work/project/src"
eq  "default: cd lands in the specific dir"         "$(zgo work project)"            "$root/work/project/src"
has "default: list shows the specific dir"          "$(zlist work project)"          "$root/work/project/src"
hasnt "default: list has no 'common:' annotation"   "$(zlist work project)"          "common:"
# the heart of the bug report: the listing's top hit must equal where we cd
eq  "default: list top hit == -e == cd target" \
    "$(zlist work project | tail -n1 | awk '{print $NF}')" "$(zecho work project)"

echo "# Scenario 1b: with _Z_KEEP_COMMON the historical jump is restored, consistently"
eq  "keep_common: -e returns the common parent"     "$(zecho_kc work project)"       "$root/work/project"
eq  "keep_common: cd lands on the common parent"    "$(zgo_kc work project)"         "$root/work/project"
has "keep_common: list annotates 'common:'"         "$(zlist_kc work project)"       "common:"
has "keep_common: 'common:' names the parent"       "$(zlist_kc work project)"       "$root/work/project"

echo "# Scenario 2: a sibling sharing a string prefix is NOT a path ancestor"
setdata <<EOF
$root/srv/app|1|$now
$root/srv/app-data|50|$now
EOF
eq  "default: -e returns app-data"                  "$(zecho srv app)"               "$root/srv/app-data"
eq  "keep_common: /srv/app is not an ancestor of /srv/app-data" \
    "$(zecho_kc srv app)" "$root/srv/app-data"
hasnt "keep_common: no bogus 'common:' for a mere prefix" "$(zlist_kc srv app)"     "common:"

echo "# Scenario 3: multiple regexes must match in order"
setdata <<EOF
$root/foo/bar|10|$now
$root/bar/foo|10|$now
EOF
eq  "order: 'foo bar' matches /foo/bar"             "$(zecho foo bar)"               "$root/foo/bar"
eq  "order: 'bar foo' matches /bar/foo"             "$(zecho bar foo)"               "$root/bar/foo"

echo "# Scenario 4: -r ranks by frequency only (and differs from frecency)"
setdata <<EOF
$root/r/alpha|100|$old
$root/r/beta|40|$now
EOF
eq  "rank: -r picks the highest ranked dir"         "$(_z -r -e r 2>/dev/null)"      "$root/r/alpha"
eq  "default: frecency favors the recent dir"       "$(zecho r)"                     "$root/r/beta"

echo "# Scenario 5: -t ranks by recency only (and differs from frecency)"
# note: keep both timestamps strictly in the past. a dir whose time equals the
# query's wall clock gets a -t score of exactly 0, which z's awk treats as a
# non-match (`matches[$1] && ...`), so sitting on that boundary is flaky.
setdata <<EOF
$root/t/recent|1|$((now - 10))
$root/t/freq|100|$old
EOF
eq  "recent: -t picks the most recent dir"          "$(_z -t -e t 2>/dev/null)"      "$root/t/recent"
eq  "default: frecency favors the frequent dir"     "$(zecho t)"                     "$root/t/freq"

echo "# Scenario 6: case-insensitive fallback still matches"
setdata <<EOF
$root/Projects/Code|10|$now
EOF
eq  "case: lowercase query matches CamelCase dir"   "$(zecho projects code)"         "$root/Projects/Code"

echo "# Scenario 7: a case-sensitive match wins over a higher-ranked insensitive one"
setdata <<EOF
$root/a/code|1|$now
$root/b/Code|100|$now
EOF
eq  "case: exact-case match beats higher-ranked other-case" \
    "$(zecho code)" "$root/a/code"

echo
echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]
