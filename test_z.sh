#!/usr/bin/env bash
#
# Regression test suite for z.sh
#
# Tests the core matching logic including:
# - Common prefix no longer overrides best match (the core bug fix)
# - Multi-keyword matching (ordered regex)
# - Case-sensitive priority over case-insensitive
# - Rank mode (-r), recent mode (-t)
# - List mode (-l) and echo mode (-e) consistency
# - Single keyword, no match, and edge cases
#
# Usage: bash test_z.sh [path-to-z.sh]

set -o pipefail

ZSH_PATH="${1:-$(dirname "$0")/z.sh}"

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------
TESTDIR="$(mktemp -d)"
trap 'rm -rf "$TESTDIR"' EXIT

export _Z_DATA="$TESTDIR/.z"
export _Z_NO_PROMPT_COMMAND=1
export _Z_NO_RESOLVE_SYMLINKS=1
export _Z_OWNER=""

PASS=0
FAIL=0
FAILURES=""

pass() {
    PASS=$((PASS + 1))
    echo "  PASS: $1"
}

fail() {
    FAIL=$((FAIL + 1))
    FAILURES="${FAILURES}\n  FAIL: $1\n    expected: $2\n    actual:   $3"
    echo "  FAIL: $1"
    echo "    expected: $2"
    echo "    actual:   $3"
}

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        pass "$desc"
    else
        fail "$desc" "$expected" "$actual"
    fi
}

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if echo "$haystack" | grep -qF "$needle"; then
        pass "$desc"
    else
        fail "$desc" "output to contain: $needle" "$haystack"
    fi
}

assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if echo "$haystack" | grep -qF "$needle"; then
        fail "$desc" "output NOT to contain: $needle" "$haystack"
    else
        pass "$desc"
    fi
}

# ---------------------------------------------------------------------------
# Helper: create a .z datafile from lines of "path|rank|timestamp"
# Directories must actually exist on disk for _z_dirs to include them.
# ---------------------------------------------------------------------------
NOW="$(date +%s)"

setup_db() {
    : > "$_Z_DATA"
    while IFS= read -r line; do
        local dir="${line%%|*}"
        mkdir -p "$dir"
        echo "$line" >> "$_Z_DATA"
    done
}

# Source z.sh fresh for each test group (avoid stale state)
source_z() {
    # Unset any previous function definition
    unset -f _z 2>/dev/null || true
    unset _Z_RESOLVE_SYMLINKS 2>/dev/null || true
    source "$ZSH_PATH"
}

# Run z in echo mode and capture output
z_echo() {
    _z -e "$@" 2>/dev/null
}

# Run z in list mode and capture output (stderr has the list)
z_list() {
    _z -l "$@" 2>&1 1>/dev/null
}

# ===========================================================================
# Test Group 1: Common prefix should NOT override best match
# ===========================================================================
echo ""
echo "=== Test Group 1: Common prefix no longer overrides best match ==="
source_z

# Scenario: /foo has low frecency, /foo/bar has high frecency, /foo/baz has medium
# Query "foo" matches all three. Old behavior: jump to /foo (common prefix).
# New behavior: jump to /foo/bar (highest frecency).
setup_db <<EOF
$TESTDIR/foo|5|$((NOW - 10000))
$TESTDIR/foo/bar|50|$((NOW - 100))
$TESTDIR/foo/baz|30|$((NOW - 200))
EOF

result="$(z_echo foo)"
assert_eq "common prefix: highest frecency wins over common parent" \
    "$TESTDIR/foo/bar" "$result"

# Scenario: Two sibling dirs under common parent, no entry for parent itself
# Old behavior: might jump to parent (which isn't even in the DB)
# New behavior: jump to the higher-frecency sibling
setup_db <<EOF
$TESTDIR/project/src|40|$((NOW - 100))
$TESTDIR/project/tests|20|$((NOW - 200))
EOF

result="$(z_echo project)"
assert_eq "common prefix: best sibling wins when parent not in DB" \
    "$TESTDIR/project/src" "$result"

# Scenario: Deep nesting with common prefix
setup_db <<EOF
$TESTDIR/a/b/c/d|10|$((NOW - 500))
$TESTDIR/a/b/c/e|60|$((NOW - 50))
$TESTDIR/a/b/c/f|30|$((NOW - 200))
EOF

result="$(z_echo a b)"
assert_eq "deep nesting: multi-keyword selects best frecency, not common prefix" \
    "$TESTDIR/a/b/c/e" "$result"

# ===========================================================================
# Test Group 2: Echo mode and list mode consistency
# ===========================================================================
echo ""
echo "=== Test Group 2: Echo/list mode consistency ==="
source_z

setup_db <<EOF
$TESTDIR/work/proj-alpha|50|$((NOW - 50))
$TESTDIR/work/proj-beta|30|$((NOW - 100))
$TESTDIR/personal/proj-gamma|10|$((NOW - 500))
EOF

# Echo mode should return the best match
echo_result="$(z_echo proj)"

# List mode should show the same best match as the top entry
list_result="$(z_list proj)"

assert_eq "echo mode returns best frecency match" \
    "$TESTDIR/work/proj-alpha" "$echo_result"

# The best match should appear in list output
assert_contains "list mode includes best match" \
    "$TESTDIR/work/proj-alpha" "$list_result"

# List should show all matches
assert_contains "list mode includes all matches (beta)" \
    "$TESTDIR/work/proj-beta" "$list_result"
assert_contains "list mode includes all matches (gamma)" \
    "$TESTDIR/personal/proj-gamma" "$list_result"

# ===========================================================================
# Test Group 3: Multi-keyword ordered matching
# ===========================================================================
echo ""
echo "=== Test Group 3: Multi-keyword ordered matching ==="
source_z

setup_db <<EOF
$TESTDIR/foo/bar|30|$((NOW - 100))
$TESTDIR/bar/foo|30|$((NOW - 100))
$TESTDIR/foo/baz|10|$((NOW - 200))
EOF

# "foo bar" should match foo.*bar, so /foo/bar but NOT /bar/foo
result="$(z_echo foo bar)"
assert_eq "multi-keyword: z foo bar matches foo/bar not bar/foo" \
    "$TESTDIR/foo/bar" "$result"

# "bar foo" should match bar.*foo, so /bar/foo but NOT /foo/bar
result="$(z_echo bar foo)"
assert_eq "multi-keyword: z bar foo matches bar/foo not foo/bar" \
    "$TESTDIR/bar/foo" "$result"

# ===========================================================================
# Test Group 4: Case-sensitive priority
# ===========================================================================
echo ""
echo "=== Test Group 4: Case-sensitive priority ==="
source_z

setup_db <<EOF
$TESTDIR/Foo/Bar|10|$((NOW - 500))
$TESTDIR/foo/bar|10|$((NOW - 500))
EOF

# When query is lowercase, case-sensitive lowercase match should win
# even if both have same rank
result="$(z_echo foo)"
assert_eq "case-sensitive: lowercase query prefers lowercase path" \
    "$TESTDIR/foo/bar" "$result"

# When query matches case-sensitively, it should prefer that
result="$(z_echo Foo)"
assert_eq "case-sensitive: exact case query prefers exact case path" \
    "$TESTDIR/Foo/Bar" "$result"

# ===========================================================================
# Test Group 5: Rank mode (-r)
# ===========================================================================
echo ""
echo "=== Test Group 5: Rank mode (-r) ==="
source_z

setup_db <<EOF
$TESTDIR/rank/high|100|$((NOW - 99999))
$TESTDIR/rank/low|10|$((NOW - 1))
EOF

# In rank mode, the highest rank wins regardless of recency
result="$(_z -e -r rank 2>/dev/null)"
assert_eq "rank mode: highest rank wins" \
    "$TESTDIR/rank/high" "$result"

# ===========================================================================
# Test Group 6: Recent mode (-t)
# ===========================================================================
echo ""
echo "=== Test Group 6: Recent mode (-t) ==="
source_z

setup_db <<EOF
$TESTDIR/recent/old|100|$((NOW - 99999))
$TESTDIR/recent/new|10|$((NOW - 1))
EOF

# In recent mode, the most recently accessed wins regardless of rank
result="$(_z -e -t recent 2>/dev/null)"
assert_eq "recent mode: most recent access wins" \
    "$TESTDIR/recent/new" "$result"

# ===========================================================================
# Test Group 7: Common prefix behavior is consistent across modes
# ===========================================================================
echo ""
echo "=== Test Group 7: Common prefix consistent across all modes ==="
source_z

setup_db <<EOF
$TESTDIR/team/frontend|50|$((NOW - 50))
$TESTDIR/team/backend|30|$((NOW - 100))
$TESTDIR/team|5|$((NOW - 1000))
EOF

# Frecent mode (default): best frecency = team/frontend
result="$(z_echo team)"
assert_eq "frecent mode: ignores common prefix, picks best frecency" \
    "$TESTDIR/team/frontend" "$result"

# Rank mode: best rank = team/frontend (50)
result="$(_z -e -r team 2>/dev/null)"
assert_eq "rank mode: ignores common prefix, picks best rank" \
    "$TESTDIR/team/frontend" "$result"

# Recent mode: most recent = team/frontend
result="$(_z -e -t team 2>/dev/null)"
assert_eq "recent mode: ignores common prefix, picks most recent" \
    "$TESTDIR/team/frontend" "$result"

# ===========================================================================
# Test Group 8: Single match (no common prefix issue)
# ===========================================================================
echo ""
echo "=== Test Group 8: Single match ==="
source_z

setup_db <<EOF
$TESTDIR/unique/path|25|$((NOW - 300))
EOF

result="$(z_echo unique)"
assert_eq "single match: returns the only match" \
    "$TESTDIR/unique/path" "$result"

# ===========================================================================
# Test Group 9: No match returns non-zero
# ===========================================================================
echo ""
echo "=== Test Group 9: No match ==="
source_z

setup_db <<EOF
$TESTDIR/exists/here|25|$((NOW - 300))
EOF

result="$(_z -e nonexistent 2>/dev/null)" || true
assert_eq "no match: returns empty string" "" "$result"

# ===========================================================================
# Test Group 10: Common prefix shown in list mode (informational only)
# ===========================================================================
echo ""
echo "=== Test Group 10: Common prefix info in list mode ==="
source_z

# The common() function detects a common prefix when the shortest match
# is a prefix of all other matches (i.e., the parent IS in the DB)
setup_db <<EOF
$TESTDIR/shared|5|$((NOW - 1000))
$TESTDIR/shared/alpha|40|$((NOW - 50))
$TESTDIR/shared/beta|20|$((NOW - 100))
EOF

list_output="$(_z -l shared 2>&1)"
assert_contains "list mode shows common prefix info" \
    "common:" "$list_output"

# But the echo mode should NOT go to the common prefix
echo_result="$(z_echo shared)"
assert_eq "list shows common prefix but echo goes to best match" \
    "$TESTDIR/shared/alpha" "$echo_result"

# ===========================================================================
# Test Group 11: Regression - common prefix with very deep nesting
# ===========================================================================
echo ""
echo "=== Test Group 11: Deep nesting regression ==="
source_z

setup_db <<EOF
$TESTDIR/org/team/service/api|80|$((NOW - 10))
$TESTDIR/org/team/service/web|40|$((NOW - 50))
$TESTDIR/org/team/service/worker|20|$((NOW - 100))
$TESTDIR/org/team/service|5|$((NOW - 500))
EOF

result="$(z_echo service)"
assert_eq "deep nesting: picks api (highest frecency), not service parent" \
    "$TESTDIR/org/team/service/api" "$result"

result="$(z_echo team service)"
assert_eq "deep nesting multi-keyword: picks api, not common parent" \
    "$TESTDIR/org/team/service/api" "$result"

# ===========================================================================
# Test Group 12: No common prefix (dirs in completely different trees)
# ===========================================================================
echo ""
echo "=== Test Group 12: No common prefix ==="
source_z

setup_db <<EOF
$TESTDIR/alpha/proj|30|$((NOW - 100))
$TESTDIR/beta/proj|50|$((NOW - 50))
EOF

result="$(z_echo proj)"
assert_eq "no common prefix: picks best frecency from different trees" \
    "$TESTDIR/beta/proj" "$result"

# ===========================================================================
# Test Group 13: Restrict to current directory (-c)
# ===========================================================================
echo ""
echo "=== Test Group 13: Restrict to current directory (-c) ==="
source_z

setup_db <<EOF
$TESTDIR/here/sub|40|$((NOW - 50))
$TESTDIR/there/sub|60|$((NOW - 30))
EOF

# When restricting to $TESTDIR/here, only matches under it should appear
(cd "$TESTDIR/here" && result="$(_z -e -c sub 2>/dev/null)"
 assert_eq "restrict -c: only matches under current dir" \
     "$TESTDIR/here/sub" "$result")

# ===========================================================================
# Test Group 14: Remove entry (-x)
# ===========================================================================
echo ""
echo "=== Test Group 14: Remove entry (-x) ==="
source_z

setup_db <<EOF
$TESTDIR/keep/this|40|$((NOW - 50))
$TESTDIR/remove/this|60|$((NOW - 30))
EOF

# Remove current directory from DB
(cd "$TESTDIR/remove/this" && _z -x 2>/dev/null)

# The removed entry should no longer match
result="$(z_echo remove)"
assert_eq "remove -x: removed entry no longer matches" "" "$result"

# But the other entry still works
result="$(z_echo keep)"
assert_eq "remove -x: other entries unaffected" \
    "$TESTDIR/keep/this" "$result"

# ===========================================================================
# Summary
# ===========================================================================
echo ""
echo "=========================================="
echo "Results: $PASS passed, $FAIL failed"
echo "=========================================="

if [ "$FAIL" -gt 0 ]; then
    echo -e "\nFailures:$FAILURES"
    exit 1
fi

exit 0
