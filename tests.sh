#!/usr/bin/env bash
# tests.sh - Test suite for z.sh
#
# Runs automated tests for core behaviors:
#   - data file maintenance (add, remove, aging)
#   - matching and scoring (frecency, rank, recent)
#   - case-sensitive/case-insensitive fallback
#   - common prefix logic
#   - argument parsing
#   - tab completion
#
# Usage:
#   bash tests.sh
#
# Exit code: 0 if all tests pass, 1 if any fail.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
Z_SH="$SCRIPT_DIR/z.sh"

# --- test infrastructure ---------------------------------------------------

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
CURRENT_TEST=""
TEST_TMP=""

pass() {
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf "  \033[32m✓\033[0m %s\n" "$CURRENT_TEST"
}

fail() {
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf "  \033[31m✗\033[0m %s\n" "$CURRENT_TEST"
    printf "    %s\n" "$1"
}

run_test() {
    TESTS_RUN=$((TESTS_RUN + 1))
    CURRENT_TEST="$1"
}

assert_eq() {
    local expected="$1" actual="$2" msg="${3:-}"
    if [ "$expected" = "$actual" ]; then
        pass
    else
        fail "expected: '$expected', got: '$actual' ${msg:+($msg)}"
    fi
}

assert_contains() {
    local haystack="$1" needle="$2"
    if printf '%s\n' "$haystack" | grep -qF "$needle"; then
        pass
    else
        fail "output does not contain: '$needle'"
    fi
}

assert_not_contains() {
    local haystack="$1" needle="$2"
    if printf '%s\n' "$haystack" | grep -qF "$needle"; then
        fail "output unexpectedly contains: '$needle'"
    else
        pass
    fi
}

assert_exit() {
    local expected="$1" actual="$2"
    if [ "$expected" = "$actual" ]; then
        pass
    else
        fail "expected exit code $expected, got $actual"
    fi
}

setup() {
    TEST_TMP="$(mktemp -d)"
    export _Z_DATA="$TEST_TMP/.z"
    export _Z_CMD=z
    export _Z_NO_PROMPT_COMMAND=1
    unset _Z_OWNER 2>/dev/null
    unset _Z_MAX_SCORE 2>/dev/null
    unset _Z_EXCLUDE_DIRS 2>/dev/null
}

teardown() {
    [ -n "$TEST_TMP" ] && rm -rf "$TEST_TMP"
    TEST_TMP=""
}

# Create directories inside TEST_TMP, print the path.
make_dir() {
    local d="$TEST_TMP/$1"
    mkdir -p "$d"
    printf '%s' "$d"
}

# Create datafile with entries. Each arg: "path|rank|timestamp"
make_datafile() {
    : > "$_Z_DATA"
    for entry in "$@"; do
        printf '%s\n' "$entry" >> "$_Z_DATA"
    done
}

# Run a snippet in a fresh bash process with z.sh sourced.
# Usage: z_eval 'code'
# Captures stdout.
z_eval() {
    bash -c '
        export _Z_DATA="'"$_Z_DATA"'"
        export _Z_CMD="'"$_Z_CMD"'"
        export _Z_NO_PROMPT_COMMAND=1
        source "'"$Z_SH"'" 2>/dev/null
        '"$1"'
    '
}

# Run a snippet, capture stdout and exit code separately.
# Sets Z_OUT and Z_RC.
z_eval_rc() {
    local tmpfile="$TEST_TMP/_z_out"
    bash -c '
        export _Z_DATA="'"$_Z_DATA"'"
        export _Z_CMD="'"$_Z_CMD"'"
        export _Z_NO_PROMPT_COMMAND=1
        source "'"$Z_SH"'" 2>/dev/null
        '"$1"'
    ' > "$tmpfile" 2>&1
    Z_RC=$?
    Z_OUT="$(cat "$tmpfile")"
}

# Run a snippet, capture only stderr.
z_eval_stderr() {
    bash -c '
        export _Z_DATA="'"$_Z_DATA"'"
        export _Z_CMD="'"$_Z_CMD"'"
        export _Z_NO_PROMPT_COMMAND=1
        source "'"$Z_SH"'" 2>/dev/null
        '"$1"'
    ' 2>&1 >/dev/null
}

# ============================================================================
# Test groups
# ============================================================================

echo ""
echo "=== z.sh test suite ==="
echo ""

# --- Data file utilities --------------------------------------------------

echo "-- Data file utilities --"

run_test "_z_datafile returns custom path from _Z_DATA"
setup
result="$(z_eval '_z_datafile')"
assert_eq "$_Z_DATA" "$result"
teardown

run_test "_z_datafile returns default \$HOME/.z when _Z_DATA unset"
setup
result="$(bash -c 'unset _Z_DATA; source "'"$Z_SH"'" 2>/dev/null; _z_datafile')"
assert_eq "$HOME/.z" "$result"
teardown

run_test "_z_datafile follows symlinks"
setup
mkdir -p "$TEST_TMP/real"
touch "$TEST_TMP/real/.z"
ln -s "$TEST_TMP/real/.z" "$_Z_DATA"
result="$(z_eval '_z_datafile')"
assert_eq "$TEST_TMP/real/.z" "$result"
teardown

# --- Data file: reading ---------------------------------------------------

echo ""
echo "-- Data file reading --"

run_test "_z_dirs filters out non-existent directories"
setup
d1="$(make_dir existing)"
make_datafile "$d1|5|1000" "/nonexistent/path|3|1000"
result="$(z_eval '_z_dirs')"
assert_contains "$result" "$d1|5|1000"
run_test "_z_dirs excludes nonexistent path"
assert_not_contains "$result" "/nonexistent/path"
teardown

run_test "_z_dirs returns nothing when datafile is missing"
setup
# Don't create datafile
result="$(z_eval '_z_dirs')"
assert_eq "" "$result"
teardown

# --- Data file: adding entries --------------------------------------------

echo ""
echo "-- Adding entries --"

run_test "_z_add creates datafile entry for new directory"
setup
d1="$(make_dir testdir)"
z_eval "_z_add '$d1'"
content="$(cat "$_Z_DATA")"
assert_contains "$content" "$d1|1|"
teardown

run_test "_z_add increments rank for existing directory"
setup
d1="$(make_dir testdir)"
now="$(\date +%s)"
make_datafile "$d1|5|$now"
z_eval "_z_add '$d1'"
content="$(cat "$_Z_DATA")"
assert_contains "$content" "$d1|6|"
teardown

run_test "_z_add skips \$HOME"
setup
z_eval "_z_add '$HOME'"
if [ ! -f "$_Z_DATA" ] || [ ! -s "$_Z_DATA" ]; then
    pass
else
    fail "datafile should be empty or nonexistent"
fi
teardown

run_test "_z_add skips /"
setup
z_eval "_z_add '/'"
if [ ! -f "$_Z_DATA" ] || [ ! -s "$_Z_DATA" ]; then
    pass
else
    fail "datafile should be empty or nonexistent"
fi
teardown

run_test "_z_add respects _Z_EXCLUDE_DIRS"
setup
d1="$(make_dir excluded/sub)"
bash -c '
    export _Z_DATA="'"$_Z_DATA"'"
    export _Z_CMD=z
    export _Z_NO_PROMPT_COMMAND=1
    _Z_EXCLUDE_DIRS=("'"$TEST_TMP"'/excluded")
    source "'"$Z_SH"'" 2>/dev/null
    _z_add "'"$d1"'"
'
if [ ! -f "$_Z_DATA" ] || [ ! -s "$_Z_DATA" ]; then
    pass
else
    fail "excluded dir should not appear in datafile"
fi
teardown

# --- Data file: aging -----------------------------------------------------

echo ""
echo "-- Aging --"

run_test "aging triggers when total rank exceeds _Z_MAX_SCORE"
setup
d1="$(make_dir dir1)"
d2="$(make_dir dir2)"
now="$(\date +%s)"
export _Z_MAX_SCORE=10
make_datafile "$d1|8|$now" "$d2|8|$now"
z_eval "_z_add '$d1'"
content="$(cat "$_Z_DATA")"
# d1 was 8, add makes it 9, total=17 > 10, so aging: 0.99*9=8.91
assert_contains "$content" "8.91"
run_test "aging also scales other entries"
assert_contains "$content" "7.92"
unset _Z_MAX_SCORE
teardown

run_test "no aging when total rank is below _Z_MAX_SCORE"
setup
d1="$(make_dir dir1)"
now="$(\date +%s)"
make_datafile "$d1|3|$now"
z_eval "_z_add '$d1'"
content="$(cat "$_Z_DATA")"
assert_contains "$content" "$d1|4|"
teardown

# --- Data file: removal ---------------------------------------------------

echo ""
echo "-- Removal --"

run_test "_z_remove deletes current directory from datafile"
setup
d1="$(make_dir testdir)"
d2="$(make_dir other)"
now="$(\date +%s)"
make_datafile "$d1|5|$now" "$d2|3|$now"
# _z_remove uses PWD, so cd into d1 first
bash -c '
    export _Z_DATA="'"$_Z_DATA"'"
    export _Z_CMD=z
    export _Z_NO_PROMPT_COMMAND=1
    cd "'"$d1"'"
    source "'"$Z_SH"'" 2>/dev/null
    _z_remove
'
content="$(cat "$_Z_DATA")"
assert_not_contains "$content" "$d1|"
run_test "_z_remove preserves other entries"
assert_contains "$content" "$d2|3|$now"
teardown

# --- Matching: basic ------------------------------------------------------

echo ""
echo "-- Matching --"

run_test "_z_match returns best frecent match"
setup
d1="$(make_dir foo/bar)"
d2="$(make_dir foo/baz)"
now="$(\date +%s)"
old="$((now - 86400))"
make_datafile "$d1|10|$now" "$d2|5|$old"
result="$(z_eval "_z_match '' '' 'foo'")"
assert_eq "$d1" "$result"
teardown

run_test "_z_match requires all query terms in order"
setup
d1="$(make_dir foo/bar)"
d2="$(make_dir bar/foo)"
now="$(\date +%s)"
make_datafile "$d1|10|$now" "$d2|10|$now"
result="$(z_eval "_z_match '' '' 'foo bar'")"
assert_eq "$d1" "$result"
teardown

run_test "_z_match: 'bar foo' matches /bar/foo not /foo/bar"
setup
d1="$(make_dir foo/bar)"
d2="$(make_dir bar/foo)"
now="$(\date +%s)"
make_datafile "$d1|10|$now" "$d2|10|$now"
result="$(z_eval "_z_match '' '' 'bar foo'")"
assert_eq "$d2" "$result"
teardown

# --- Matching: case sensitivity -------------------------------------------

echo ""
echo "-- Case sensitivity --"

run_test "case-sensitive match preferred over case-insensitive"
setup
d1="$(make_dir Foo/Bar)"
d2="$(make_dir foo/bar)"
now="$(\date +%s)"
make_datafile "$d1|5|$now" "$d2|5|$now"
result="$(z_eval "_z_match '' '' 'foo'")"
assert_eq "$d2" "$result"
teardown

run_test "falls back to case-insensitive when no case-sensitive match"
setup
d1="$(make_dir Foo/Bar)"
now="$(\date +%s)"
make_datafile "$d1|5|$now"
result="$(z_eval "_z_match '' '' 'foo'")"
assert_eq "$d1" "$result"
teardown

# --- Matching: sort types -------------------------------------------------

echo ""
echo "-- Sort types --"

run_test "rank sort (-r) picks highest rank regardless of time"
setup
d1="$(make_dir dir1)"
d2="$(make_dir dir2)"
now="$(\date +%s)"
old="$((now - 86400))"
make_datafile "$d1|100|$old" "$d2|5|$now"
result="$(z_eval "_z_match '' 'rank' 'dir'")"
assert_eq "$d1" "$result"
teardown

run_test "recent sort (-t) picks most recently accessed"
setup
d1="$(make_dir dir1)"
d2="$(make_dir dir2)"
now="$(\date +%s)"
old="$((now - 86400))"
make_datafile "$d1|100|$old" "$d2|5|$now"
result="$(z_eval "_z_match '' 'recent' 'dir'")"
assert_eq "$d2" "$result"
teardown

# --- Common prefix --------------------------------------------------------

echo ""
echo "-- Common prefix --"

run_test "common prefix: chooses shortest when all share a prefix"
setup
d1="$(make_dir projects/foo)"
d2="$(make_dir projects/foo/bar)"
d3="$(make_dir projects/foo/baz)"
now="$(\date +%s)"
make_datafile "$d1|5|$now" "$d2|10|$now" "$d3|10|$now"
result="$(z_eval "_z_match '' '' 'projects'")"
assert_eq "$d1" "$result"
teardown

run_test "common prefix: ignored when explicit sort type is given"
setup
d1="$(make_dir projects/foo)"
d2="$(make_dir projects/foo/bar)"
now="$(\date +%s)"
make_datafile "$d1|5|$now" "$d2|100|$now"
result="$(z_eval "_z_match '' 'rank' 'projects'")"
assert_eq "$d2" "$result"
teardown

# --- Matching: no results -------------------------------------------------

echo ""
echo "-- No results --"

run_test "_z_match returns exit code 1 when no match"
setup
d1="$(make_dir foo)"
now="$(\date +%s)"
make_datafile "$d1|5|$now"
z_eval_rc "_z_match '' '' 'zzzzz'"
assert_exit 1 "$Z_RC"
teardown

run_test "_z_match returns 1 when datafile does not exist"
setup
# Don't create datafile
z_eval_rc "_z_match '' '' 'foo'"
assert_exit 1 "$Z_RC"
teardown

# --- List mode ------------------------------------------------------------

echo ""
echo "-- List mode --"

run_test "list mode prints matching directories to stderr"
setup
d1="$(make_dir foo/bar)"
d2="$(make_dir foo/baz)"
now="$(\date +%s)"
make_datafile "$d1|5|$now" "$d2|10|$now"
stderr_output="$(z_eval_stderr "_z_match '1' '' 'foo'")"
assert_contains "$stderr_output" "foo/bar"
run_test "list mode includes second match"
assert_contains "$stderr_output" "foo/baz"
teardown

# --- Tab completion -------------------------------------------------------

echo ""
echo "-- Tab completion --"

run_test "_z_complete returns matching paths"
setup
d1="$(make_dir projects/foo)"
d2="$(make_dir projects/bar)"
now="$(\date +%s)"
make_datafile "$d1|5|$now" "$d2|10|$now"
result="$(z_eval "_z_complete 'z pr'")"
assert_contains "$result" "$d1"
run_test "_z_complete returns second match too"
assert_contains "$result" "$d2"
teardown

run_test "_z_complete case-insensitive for lowercase query"
setup
d1="$(make_dir Projects/Foo)"
now="$(\date +%s)"
make_datafile "$d1|5|$now"
result="$(z_eval "_z_complete 'z projects'")"
assert_contains "$result" "$d1"
teardown

run_test "_z_complete case-sensitive for mixed-case query"
setup
d1="$(make_dir Projects/Foo)"
d2="$(make_dir projects/foo)"
now="$(\date +%s)"
make_datafile "$d1|5|$now" "$d2|5|$now"
result="$(z_eval "_z_complete 'z Projects'")"
assert_contains "$result" "$d1"
run_test "_z_complete excludes case-mismatched entry"
assert_not_contains "$result" "$d2"
teardown

run_test "_z_complete returns nothing for missing datafile"
setup
# No datafile
result="$(z_eval "_z_complete 'z foo'")"
assert_eq "" "$result"
teardown

# --- Argument parsing -----------------------------------------------------

echo ""
echo "-- Argument parsing --"

run_test "parse_args: basic query"
setup
result="$(z_eval 'eval "_z_parse_args foo bar"; echo "$_Z_PARSE_QUERY"')"
assert_eq "foo bar" "$result"
teardown

run_test "parse_args: -r sets type to rank"
setup
result="$(z_eval 'eval "_z_parse_args -r foo"; echo "$_Z_PARSE_TYPE"')"
assert_eq "rank" "$result"
teardown

run_test "parse_args: -t sets type to recent"
setup
result="$(z_eval 'eval "_z_parse_args -t foo"; echo "$_Z_PARSE_TYPE"')"
assert_eq "recent" "$result"
teardown

run_test "parse_args: -l enables list mode"
setup
result="$(z_eval 'eval "_z_parse_args -l foo"; echo "$_Z_PARSE_LIST"')"
assert_eq "1" "$result"
teardown

run_test "parse_args: -e enables echo mode"
setup
result="$(z_eval 'eval "_z_parse_args -e foo"; echo "$_Z_PARSE_ECHO"')"
assert_eq "1" "$result"
teardown

run_test "parse_args: no query defaults to list mode"
setup
result="$(z_eval '_z_parse_args; echo "$_Z_PARSE_LIST"')"
assert_eq "1" "$result"
teardown

run_test "parse_args: -h returns exit code 1"
setup
z_eval_rc '_z_parse_args -h'
assert_exit 1 "$Z_RC"
teardown

run_test "parse_args: combined flags -lr"
setup
result="$(z_eval 'eval "_z_parse_args -lr foo"; echo "$_Z_PARSE_LIST:$_Z_PARSE_TYPE"')"
assert_eq "1:rank" "$result"
teardown

run_test "parse_args: -- separator passes remaining args as query"
setup
result="$(z_eval 'eval "_z_parse_args -- -foo bar"; echo "$_Z_PARSE_QUERY"')"
assert_eq "-foo bar" "$result"
teardown

# --- Integration ----------------------------------------------------------

echo ""
echo "-- Integration --"

run_test "_z -e echoes best match instead of cd"
setup
d1="$(make_dir myproject)"
now="$(\date +%s)"
make_datafile "$d1|10|$now"
result="$(z_eval "_z -e myproject")"
assert_eq "$d1" "$result"
teardown

run_test "_z with no args enters list mode"
setup
d1="$(make_dir foo)"
now="$(\date +%s)"
make_datafile "$d1|5|$now"
stderr_output="$(z_eval_stderr '_z')"
assert_contains "$stderr_output" "foo"
teardown

run_test "_z --add then _z -e finds the added directory"
setup
d1="$(make_dir integration_test)"
z_eval "_z --add '$d1'"
result="$(z_eval "_z -e integration")"
assert_eq "$d1" "$result"
teardown

# --- Frecency formula sanity ----------------------------------------------

echo ""
echo "-- Frecency formula --"

run_test "recently accessed low-rank dir beats old high-rank dir"
setup
d1="$(make_dir oldpopular)"
d2="$(make_dir newkid)"
now="$(\date +%s)"
old="$((now - 86400 * 30))"
make_datafile "$d1|50|$old" "$d2|3|$now"
result="$(z_eval "_z_match '' '' '.*'")"
assert_eq "$d2" "$result"
teardown

# ============================================================================
# Summary
# ============================================================================

echo ""
echo "========================================="
printf "  Total: %d  " "$TESTS_RUN"
printf "\033[32mPassed: %d\033[0m  " "$TESTS_PASSED"
printf "\033[31mFailed: %d\033[0m\n" "$TESTS_FAILED"
echo "========================================="
echo ""

if [ "$TESTS_FAILED" -gt 0 ]; then
    exit 1
fi
exit 0
