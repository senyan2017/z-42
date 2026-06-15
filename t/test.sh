#!/usr/bin/env bash
#
# Behavioural tests for z.sh's internal helpers.
#
# No framework, no network, no real $HOME/.z: every test drives a single-purpose
# function with a temp datafile or with fixed "dir|rank|time" lines on stdin, so
# the matching / aging / completion rules can be checked without a live shell.
#
# Run with:   bash t/test.sh     (or: make test)

here=$(cd "$(dirname "$0")/.." && pwd)

tests=0
fails=0

# ok ACTUAL EXPECTED LABEL  -- record a string-equality assertion
ok() {
    tests=$((tests + 1))
    if [ "$1" = "$2" ]; then
        printf 'ok   - %s\n' "$3"
    else
        fails=$((fails + 1))
        printf 'FAIL - %s\n      expected: [%s]\n      actual:   [%s]\n' "$3" "$2" "$1"
    fi
}

# contains ACTUAL NEEDLE LABEL -- assert ACTUAL contains substring NEEDLE
contains() {
    tests=$((tests + 1))
    case "$1" in
        *"$2"*) printf 'ok   - %s\n' "$3" ;;
        *)
            fails=$((fails + 1))
            printf 'FAIL - %s\n      expected substring: [%s]\n      actual:             [%s]\n' "$3" "$2" "$1"
            ;;
    esac
}

# source z.sh with no side effects: temp datafile, prompt hook disabled
export _Z_NO_PROMPT_COMMAND=1
tmp=$(mktemp -d)
export _Z_DATA="$tmp/.z"
trap 'rm -rf "$tmp"' EXIT

# shellcheck source=/dev/null
. "$here/z.sh"

# real directories used by the file-backed helpers
mkdir -p "$tmp/uniqalpha" "$tmp/uniqalpha/beta" "$tmp/uniqgamma"

now=1000000000   # fixed "now" so frecency/recency are deterministic
old=$((now - 100000000))

# --- _z_datafile -----------------------------------------------------------

ok "$(_z_datafile)" "$_Z_DATA" "_z_datafile reports the configured datafile"

# --- _z_dirs ---------------------------------------------------------------

printf '%s|1|100\n%s|1|100\n' "$tmp/uniqalpha" "$tmp/does-not-exist" > "$_Z_DATA"
ok "$(_z_dirs "$_Z_DATA")" "$tmp/uniqalpha|1|100" \
    "_z_dirs keeps only entries whose directory still exists"

ok "$(_z_dirs "$tmp/no-such-file")" "" \
    "_z_dirs emits nothing when the datafile is missing"

# --- _z_add ----------------------------------------------------------------

: > "$_Z_DATA"
_z_add "$_Z_DATA" "$tmp/uniqgamma"
case "$(cat "$_Z_DATA")" in
    "$tmp/uniqgamma|1|"*) r=ok ;; *) r=$(cat "$_Z_DATA") ;;
esac
ok "$r" ok "_z_add creates a new entry at rank 1"

printf '%s|3|100\n' "$tmp/uniqgamma" > "$_Z_DATA"
_z_add "$_Z_DATA" "$tmp/uniqgamma"
case "$(cat "$_Z_DATA")" in
    "$tmp/uniqgamma|4|"*) r=ok ;; *) r=$(cat "$_Z_DATA") ;;
esac
ok "$r" ok "_z_add bumps an existing entry's rank by 1"

# summed rank 6+4=10 exceeds score 5 -> every rank is aged by *0.99
printf '%s|6|100\n%s|4|100\n' "$tmp/uniqalpha" "$tmp/uniqgamma" > "$_Z_DATA"
_Z_MAX_SCORE=5 _z_add "$_Z_DATA" "$tmp/uniqalpha/beta"
aged=$(_z_dirs "$_Z_DATA" | \awk -F"|" -v d="$tmp/uniqalpha" '$1==d{print $2}')
ok "$aged" "5.94" "_z_add ages all ranks by 0.99 once the score is exceeded"

: > "$_Z_DATA"
_Z_EXCLUDE_DIRS=("$tmp/uniqgamma")
_z_add "$_Z_DATA" "$tmp/uniqgamma"
_Z_EXCLUDE_DIRS=()
ok "$(cat "$_Z_DATA")" "" "_z_add honours _Z_EXCLUDE_DIRS"

# --- _z_query (hermetic: candidates supplied on stdin) ---------------------

best=$(printf '/a/xx|1|%s\n/a/xy|50|%s\n' "$old" "$now" | _z_query "$now" "" "" "x")
ok "$best" "/a/xy" "_z_query picks the highest frecency among matches"

best=$(printf '/a/p|2|%s\n/a/q|9|%s\n' "$now" "$now" | _z_query "$now" "" "rank" "/a/")
ok "$best" "/a/q" "_z_query -r ranks by raw rank"

best=$(printf '/a/old|9|%s\n/a/new|1|%s\n' "$((now-1000))" "$((now-10))" | _z_query "$now" "" "recent" "/a/")
ok "$best" "/a/new" "_z_query -t ranks by most recent access"

best=$(printf '/a/Foo|5|%s\n' "$now" | _z_query "$now" "" "" "foo")
ok "$best" "/a/Foo" "_z_query falls back to a case-insensitive match"

best=$(printf '/p/a|1|%s\n/p/a/b|50|%s\n' "$now" "$now" | _z_query "$now" "" "" "a")
ok "$best" "/p/a" "_z_query returns the shortest common prefix, ignoring score"

printf '/x/y|1|%s\n' "$now" | _z_query "$now" "" "" "zzz"
ok "$?" "1" "_z_query exits non-zero when nothing matches"

out=$(printf '/x/y|3|%s\n' "$now" | _z_query "$now" 1 "" "y" 2>/dev/null)
rc=$?
ok "$out" "" "_z_query -l prints nothing to stdout"
ok "$rc" "0" "_z_query -l exits zero"
err=$(printf '/x/y|3|%s\n' "$now" | _z_query "$now" 1 "" "y" 2>&1 1>/dev/null)
contains "$err" "/x/y" "_z_query -l lists matches on stderr"

# --- _z_complete -----------------------------------------------------------

printf '%s|5|100\n%s|5|100\n' "$tmp/uniqalpha" "$tmp/uniqgamma" > "$_Z_DATA"
ok "$(_z_complete "$_Z_DATA" "z uniqal")" "$tmp/uniqalpha" \
    "_z_complete returns directories matching the partial line"

# --- _z_remove -------------------------------------------------------------

printf '%s|5|100\n%s|5|100\n' "$tmp/uniqalpha" "$tmp/uniqgamma" > "$_Z_DATA"
_z_remove "$_Z_DATA" "$tmp/uniqalpha"
ok "$(cat "$_Z_DATA")" "$tmp/uniqgamma|5|100" \
    "_z_remove deletes the entry for the given directory"

# --- summary ---------------------------------------------------------------

echo
if [ "$fails" -eq 0 ]; then
    printf 'PASS: %d/%d\n' "$tests" "$tests"
    exit 0
else
    printf 'FAIL: %d/%d failed\n' "$fails" "$tests"
    exit 1
fi
