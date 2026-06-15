#!/bin/bash
# Test suite for z import/export functionality
# Run with: bash tests/test_import_export.sh

# Don't use set -e since we test expected error exit codes

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
Z_SH="$SCRIPT_DIR/../z.sh"

PASS=0
FAIL=0
TOTAL=0

# Colors (if terminal supports them)
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    NC=''
fi

pass() {
    PASS=$((PASS + 1))
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: $1"
}

fail() {
    FAIL=$((FAIL + 1))
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: $1"
    [ -n "$2" ] && echo "        detail: $2"
}

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        pass "$desc"
    else
        fail "$desc" "expected='$expected' actual='$actual'"
    fi
}

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if echo "$haystack" | grep -qF -- "$needle"; then
        pass "$desc"
    else
        fail "$desc" "output does not contain '$needle'"
    fi
}

assert_not_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if echo "$haystack" | grep -qF -- "$needle"; then
        fail "$desc" "output should not contain '$needle'"
    else
        pass "$desc"
    fi
}

assert_exit_code() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        pass "$desc"
    else
        fail "$desc" "expected exit code $expected, got $actual"
    fi
}

assert_file_exists() {
    local desc="$1" path="$2"
    if [ -f "$path" ]; then
        pass "$desc"
    else
        fail "$desc" "file $path does not exist"
    fi
}

assert_file_line_count() {
    local desc="$1" path="$2" expected="$3"
    local actual
    if [ -f "$path" ]; then
        actual=$(awk 'END{print NR}' "$path")
    else
        actual=0
    fi
    assert_eq "$desc" "$expected" "$actual"
}

# Setup: create a temporary test environment
setup() {
    TEST_DIR=$(mktemp -d)
    export _Z_DATA="$TEST_DIR/.z"
    export _Z_NO_PROMPT_COMMAND=1

    # Create some real directories for testing
    mkdir -p "$TEST_DIR/projects/foo"
    mkdir -p "$TEST_DIR/projects/bar"
    mkdir -p "$TEST_DIR/work/client-a"
    mkdir -p "$TEST_DIR/work/client-b"
    mkdir -p "$TEST_DIR/tmp/stuff"

    # Source z.sh in a clean way
    # We need to unset PROMPT_COMMAND to avoid side effects
    unset PROMPT_COMMAND
    . "$Z_SH"
}

# Teardown
teardown() {
    rm -rf "$TEST_DIR"
    unset _Z_DATA _Z_NO_PROMPT_COMMAND
}

# Helper: write datafile directly
write_datafile() {
    echo "$1" > "$_Z_DATA"
}

# Helper: read datafile
read_datafile() {
    [ -f "$_Z_DATA" ] && cat "$_Z_DATA"
}

# Helper: count entries in datafile
count_entries() {
    [ -f "$_Z_DATA" ] && awk 'END{print NR}' "$_Z_DATA" || echo 0
}

# Helper: get rank for a path from datafile
get_rank() {
    local path="$1"
    [ -f "$_Z_DATA" ] && awk -F"|" -v p="$path" '$1==p{print $2}' "$_Z_DATA"
}

# Helper: get time for a path from datafile
get_time() {
    local path="$1"
    [ -f "$_Z_DATA" ] && awk -F"|" -v p="$path" '$1==p{print $3}' "$_Z_DATA"
}

# ============================================================
# TESTS
# ============================================================

echo ""
echo "=== z import/export test suite ==="
echo ""

# ----------------------------------------------------------
echo "--- Export Tests ---"
# ----------------------------------------------------------

setup

# Test 1: Export to stdout with populated datafile
write_datafile "$TEST_DIR/projects/foo|10|1700000000
$TEST_DIR/projects/bar|5|1700000100"

output=$(_z --export 2>/dev/null)
assert_contains "export to stdout includes first entry" "$output" "$TEST_DIR/projects/foo|10|1700000000"
assert_contains "export to stdout includes second entry" "$output" "$TEST_DIR/projects/bar|5|1700000100"

# Test 2: Export to file
export_file="$TEST_DIR/exported.z"
output=$(_z --export "$export_file" 2>&1)
assert_file_exists "export creates output file" "$export_file"
assert_file_line_count "export file has correct line count" "$export_file" 2
assert_contains "export to file reports count" "$output" "Exported 2 entries"

# Test 3: Export with no datafile
teardown; setup
rm -f "$_Z_DATA"
output=$(_z --export 2>&1)
rc=$?
assert_exit_code "export with no datafile returns error" 1 "$rc"
assert_contains "export with no datafile shows error message" "$output" "No datafile found"

# Test 4: Export to file (content matches datafile)
teardown; setup
write_datafile "$TEST_DIR/projects/foo|10|1700000000
$TEST_DIR/projects/bar|5|1700000100
$TEST_DIR/work/client-a|20|1700000200"
export_file="$TEST_DIR/export2.z"
_z --export "$export_file" >/dev/null 2>&1
original_md5=$(md5sum "$_Z_DATA" | awk '{print $1}')
export_md5=$(md5sum "$export_file" | awk '{print $1}')
assert_eq "export file matches datafile exactly" "$original_md5" "$export_md5"

teardown

# ----------------------------------------------------------
echo ""
echo "--- Import Tests (basic) ---"
# ----------------------------------------------------------

# Test 5: Import into non-existent datafile (fresh install)
setup
rm -f "$_Z_DATA"
import_file="$TEST_DIR/import_data.z"
cat > "$import_file" <<EOF
$TEST_DIR/projects/foo|10|1700000000
$TEST_DIR/projects/bar|5|1700000100
EOF

output=$(_z --import "$import_file" 2>&1)
assert_contains "fresh import reports entries" "$output" "2 entries in database"
assert_eq "fresh import creates datafile with correct count" "2" "$(count_entries)"
assert_eq "fresh import preserves rank for foo" "10" "$(get_rank "$TEST_DIR/projects/foo")"
assert_eq "fresh import preserves time for bar" "1700000100" "$(get_time "$TEST_DIR/projects/bar")"

# Test 6: Import merges with existing data - higher rank wins
teardown; setup
write_datafile "$TEST_DIR/projects/foo|5|1700000000"
import_file="$TEST_DIR/import_merge.z"
echo "$TEST_DIR/projects/foo|20|1699999000" > "$import_file"

_z --import "$import_file" >/dev/null 2>&1
assert_eq "merge keeps higher rank from import" "20" "$(get_rank "$TEST_DIR/projects/foo")"

# Test 7: Import merges - existing higher rank preserved
teardown; setup
write_datafile "$TEST_DIR/projects/foo|30|1700000000"
import_file="$TEST_DIR/import_lower.z"
echo "$TEST_DIR/projects/foo|10|1700000500" > "$import_file"

_z --import "$import_file" >/dev/null 2>&1
assert_eq "merge keeps higher existing rank" "30" "$(get_rank "$TEST_DIR/projects/foo")"

# Test 8: Import merges - higher time wins
teardown; setup
write_datafile "$TEST_DIR/projects/foo|10|1700000000"
import_file="$TEST_DIR/import_time.z"
echo "$TEST_DIR/projects/foo|10|1700001000" > "$import_file"

_z --import "$import_file" >/dev/null 2>&1
assert_eq "merge keeps higher time from import" "1700001000" "$(get_time "$TEST_DIR/projects/foo")"

# Test 9: Import preserves existing entries not in import file
teardown; setup
write_datafile "$TEST_DIR/projects/foo|10|1700000000
$TEST_DIR/work/client-a|15|1700000500"
import_file="$TEST_DIR/import_new.z"
echo "$TEST_DIR/projects/bar|8|1700000200" > "$import_file"

_z --import "$import_file" >/dev/null 2>&1
assert_eq "import preserves existing entry foo" "10" "$(get_rank "$TEST_DIR/projects/foo")"
assert_eq "import preserves existing entry client-a" "15" "$(get_rank "$TEST_DIR/work/client-a")"
assert_eq "import adds new entry bar" "8" "$(get_rank "$TEST_DIR/projects/bar")"
assert_eq "import result has 3 entries" "3" "$(count_entries)"

teardown

# ----------------------------------------------------------
echo ""
echo "--- Import Tests (dead directories) ---"
# ----------------------------------------------------------

# Test 10: Import skips directories that don't exist
setup
rm -f "$_Z_DATA"
import_file="$TEST_DIR/import_dead.z"
cat > "$import_file" <<EOF
$TEST_DIR/projects/foo|10|1700000000
$TEST_DIR/nonexistent/path|20|1700000100
$TEST_DIR/projects/bar|5|1700000200
EOF

output=$(_z --import "$import_file" 2>&1)
assert_contains "import reports dead entries skipped" "$output" "1 dead entries skipped"
assert_eq "import with dead dir has 2 entries" "2" "$(count_entries)"
# Make sure the dead directory is NOT in the datafile
datafile_content=$(read_datafile)
assert_not_contains "dead directory not in datafile" "$datafile_content" "nonexistent/path"

# Test 11: Import --keep-dead preserves non-existent directories
teardown; setup
rm -f "$_Z_DATA"
import_file="$TEST_DIR/import_keepdead.z"
cat > "$import_file" <<EOF
$TEST_DIR/projects/foo|10|1700000000
$TEST_DIR/nonexistent/path|20|1700000100
EOF

output=$(_z --import --keep-dead "$import_file" 2>&1)
assert_eq "keep-dead import has 2 entries" "2" "$(count_entries)"
assert_eq "keep-dead preserves dead directory rank" "20" "$(get_rank "$TEST_DIR/nonexistent/path")"

teardown

# ----------------------------------------------------------
echo ""
echo "--- Import Tests (malformed data) ---"
# ----------------------------------------------------------

# Test 12: Import with malformed lines (missing fields)
setup
rm -f "$_Z_DATA"
import_file="$TEST_DIR/import_bad.z"
cat > "$import_file" <<EOF
$TEST_DIR/projects/foo|10|1700000000
this line has no pipes
$TEST_DIR/projects/bar|5|1700000200
|missing|path
$TEST_DIR/work/client-a|notanumber|1700000300
EOF

output=$(_z --import "$import_file" 2>&1)
# Should only have the 2 valid entries (foo and bar)
assert_eq "malformed import: only valid entries kept" "2" "$(count_entries)"
assert_eq "malformed import: foo preserved" "10" "$(get_rank "$TEST_DIR/projects/foo")"
assert_eq "malformed import: bar preserved" "5" "$(get_rank "$TEST_DIR/projects/bar")"

# Test 13: Import with completely empty file
teardown; setup
rm -f "$_Z_DATA"
import_file="$TEST_DIR/import_empty.z"
touch "$import_file"

output=$(_z --import "$import_file" 2>&1)
assert_contains "empty import reports 0 entries" "$output" "0 entries in database"

# Test 14: Import with no file argument
teardown; setup
output=$(_z --import 2>&1)
rc=$?
assert_exit_code "import with no file returns error" 1 "$rc"
assert_contains "import with no file shows usage" "$output" "Usage:"

# Test 15: Import with non-existent file
output=$(_z --import "$TEST_DIR/does_not_exist.z" 2>&1)
rc=$?
assert_exit_code "import with missing file returns error" 1 "$rc"
assert_contains "import with missing file shows error" "$output" "not found"

teardown

# ----------------------------------------------------------
echo ""
echo "--- Import Dry-Run Tests ---"
# ----------------------------------------------------------

# Test 16: Dry-run does not modify datafile
setup
write_datafile "$TEST_DIR/projects/foo|10|1700000000"
original_content=$(read_datafile)
import_file="$TEST_DIR/import_dry.z"
cat > "$import_file" <<EOF
$TEST_DIR/projects/foo|50|1700001000
$TEST_DIR/projects/bar|8|1700000500
EOF

output=$(_z --import-dry-run "$import_file" 2>/dev/null)
after_content=$(read_datafile)
assert_eq "dry-run does not modify datafile" "$original_content" "$after_content"
assert_contains "dry-run shows UPDATE for foo" "$output" "UPDATE"
assert_contains "dry-run shows NEW for bar" "$output" "NEW"

# Test 17: Dry-run with no existing datafile
teardown; setup
rm -f "$_Z_DATA"
import_file="$TEST_DIR/import_dry_fresh.z"
cat > "$import_file" <<EOF
$TEST_DIR/projects/foo|10|1700000000
$TEST_DIR/projects/bar|5|1700000100
$TEST_DIR/nonexistent/dir|20|1700000200
EOF

output=$(_z --import-dry-run "$import_file" 2>/dev/null)
assert_contains "dry-run fresh shows NEW entries" "$output" "NEW"
assert_contains "dry-run fresh shows SKIP for dead dir" "$output" "SKIP"
assert_contains "dry-run fresh summary includes dead" "$output" "dead directories skipped"
# Verify no datafile was created
if [ ! -f "$_Z_DATA" ]; then
    pass "dry-run does not create datafile"
else
    fail "dry-run does not create datafile" "datafile was created"
fi

# Test 18: Dry-run with unchanged entries
teardown; setup
write_datafile "$TEST_DIR/projects/foo|10|1700000000"
import_file="$TEST_DIR/import_dry_same.z"
echo "$TEST_DIR/projects/foo|10|1700000000" > "$import_file"

output=$(_z --import-dry-run "$import_file" 2>/dev/null)
assert_contains "dry-run unchanged shows 'unchanged' in summary" "$output" "1 unchanged"
assert_not_contains "dry-run unchanged has no UPDATE" "$output" "UPDATE"
assert_not_contains "dry-run unchanged has no NEW" "$output" "NEW"

# Test 19: Dry-run with --keep-dead
teardown; setup
rm -f "$_Z_DATA"
import_file="$TEST_DIR/import_dry_keep.z"
echo "$TEST_DIR/nonexistent/dir|20|1700000200" > "$import_file"

output=$(_z --import-dry-run --keep-dead "$import_file" 2>/dev/null)
assert_contains "dry-run keep-dead shows NEW instead of SKIP" "$output" "NEW"
assert_not_contains "dry-run keep-dead has no SKIP" "$output" "SKIP"

# Test 20: Dry-run summary with malformed lines
teardown; setup
rm -f "$_Z_DATA"
import_file="$TEST_DIR/import_dry_bad.z"
cat > "$import_file" <<EOF
$TEST_DIR/projects/foo|10|1700000000
garbage line here
$TEST_DIR/projects/bar|5|1700000200
EOF

output=$(_z --import-dry-run "$import_file" 2>/dev/null)
assert_contains "dry-run reports malformed lines" "$output" "malformed lines skipped"

teardown

# ----------------------------------------------------------
echo ""
echo "--- Round-trip Tests ---"
# ----------------------------------------------------------

# Test 21: Export then import preserves data
setup
write_datafile "$TEST_DIR/projects/foo|10|1700000000
$TEST_DIR/projects/bar|5|1700000100
$TEST_DIR/work/client-a|20|1700000200"

export_file="$TEST_DIR/roundtrip.z"
_z --export "$export_file" >/dev/null 2>&1

# Clear datafile and reimport
rm -f "$_Z_DATA"
_z --import "$export_file" >/dev/null 2>&1

assert_eq "round-trip preserves foo rank" "10" "$(get_rank "$TEST_DIR/projects/foo")"
assert_eq "round-trip preserves bar time" "1700000100" "$(get_time "$TEST_DIR/projects/bar")"
assert_eq "round-trip preserves client-a" "20" "$(get_rank "$TEST_DIR/work/client-a")"
assert_eq "round-trip has correct entry count" "3" "$(count_entries)"

# Test 22: Export-import-export produces identical files
export_file2="$TEST_DIR/roundtrip2.z"
_z --export "$export_file2" >/dev/null 2>&1
md5_1=$(sort "$export_file" | md5sum | awk '{print $1}')
md5_2=$(sort "$export_file2" | md5sum | awk '{print $1}')
assert_eq "double round-trip produces same data" "$md5_1" "$md5_2"

# Test 23: Import is idempotent (importing same data twice = same result)
teardown; setup
import_file="$TEST_DIR/idempotent.z"
cat > "$import_file" <<EOF
$TEST_DIR/projects/foo|10|1700000000
$TEST_DIR/projects/bar|5|1700000100
EOF

_z --import "$import_file" >/dev/null 2>&1
snapshot1=$(read_datafile | sort)
_z --import "$import_file" >/dev/null 2>&1
snapshot2=$(read_datafile | sort)
assert_eq "import is idempotent" "$snapshot1" "$snapshot2"

teardown

# ----------------------------------------------------------
echo ""
echo "--- Edge Case Tests ---"
# ----------------------------------------------------------

# Test 24: Import with rank below 1 should be skipped
setup
rm -f "$_Z_DATA"
import_file="$TEST_DIR/import_lowrank.z"
cat > "$import_file" <<EOF
$TEST_DIR/projects/foo|0.5|1700000000
$TEST_DIR/projects/bar|5|1700000100
EOF

_z --import "$import_file" >/dev/null 2>&1
assert_eq "low-rank entry skipped" "1" "$(count_entries)"
assert_eq "only bar survives import" "5" "$(get_rank "$TEST_DIR/projects/bar")"

# Test 25: Datafile with entries pointing to dead dirs
teardown; setup
write_datafile "$TEST_DIR/projects/foo|10|1700000000
$TEST_DIR/nonexistent/dead|50|1700000100
$TEST_DIR/projects/bar|5|1700000200"

# Export should only include live directories
output=$(_z --export 2>/dev/null)
assert_contains "export includes live dir foo" "$output" "projects/foo"
assert_contains "export includes live dir bar" "$output" "projects/bar"
assert_not_contains "export excludes dead dir" "$output" "nonexistent/dead"

# Test 26: Help text includes new subcommands
teardown; setup
output=$(_z -h 2>&1)
assert_contains "help shows --export" "$output" "--export"
assert_contains "help shows --import" "$output" "--import"
assert_contains "help shows --import-dry-run" "$output" "--import-dry-run"

# Test 27: Import with duplicate paths in import file (last one wins in awk)
teardown; setup
rm -f "$_Z_DATA"
import_file="$TEST_DIR/import_dup.z"
cat > "$import_file" <<EOF
$TEST_DIR/projects/foo|5|1700000000
$TEST_DIR/projects/foo|20|1700001000
$TEST_DIR/projects/bar|8|1700000200
EOF

_z --import "$import_file" >/dev/null 2>&1
# With awk, the second line for foo should overwrite the first in i_rank/i_time
# So foo should have rank 20 and time 1700001000
rank_foo=$(get_rank "$TEST_DIR/projects/foo")
# The awk takes the last seen values from the import file
assert_eq "duplicate in import: higher rank survives" "20" "$rank_foo"
assert_eq "import with dups has 2 entries" "2" "$(count_entries)"

# Test 28: Import merging complex scenario
teardown; setup
write_datafile "$TEST_DIR/projects/foo|10|1700000000
$TEST_DIR/projects/bar|30|1699999000
$TEST_DIR/work/client-a|5|1700000500"

import_file="$TEST_DIR/import_complex.z"
cat > "$import_file" <<EOF
$TEST_DIR/projects/foo|15|1699999000
$TEST_DIR/projects/bar|10|1700002000
$TEST_DIR/work/client-b|12|1700000800
$TEST_DIR/nonexistent/gone|100|1700000000
EOF

output=$(_z --import "$import_file" 2>&1)
# foo: import rank 15 > existing 10, existing time 1700000000 > import 1699999000
assert_eq "complex merge: foo rank from import" "15" "$(get_rank "$TEST_DIR/projects/foo")"
assert_eq "complex merge: foo time from existing" "1700000000" "$(get_time "$TEST_DIR/projects/foo")"
# bar: existing rank 30 > import 10, import time 1700002000 > existing 1699999000
assert_eq "complex merge: bar rank from existing" "30" "$(get_rank "$TEST_DIR/projects/bar")"
assert_eq "complex merge: bar time from import" "1700002000" "$(get_time "$TEST_DIR/projects/bar")"
# client-a: unchanged (only in existing)
assert_eq "complex merge: client-a unchanged" "5" "$(get_rank "$TEST_DIR/work/client-a")"
# client-b: new entry
assert_eq "complex merge: client-b added" "12" "$(get_rank "$TEST_DIR/work/client-b")"
# nonexistent: skipped
assert_contains "complex merge: dead entry reported" "$output" "dead entries skipped"
# Total entries: foo, bar, client-a, client-b = 4
assert_eq "complex merge: correct total" "4" "$(count_entries)"

teardown

# ----------------------------------------------------------
echo ""
echo "--- Datafile Integrity Tests ---"
# ----------------------------------------------------------

# Test 29: After import, datafile is valid and readable by _z
setup
rm -f "$_Z_DATA"
import_file="$TEST_DIR/import_integrity.z"
cat > "$import_file" <<EOF
$TEST_DIR/projects/foo|10|1700000000
$TEST_DIR/projects/bar|5|1700000100
EOF

_z --import "$import_file" >/dev/null 2>&1

# Verify the datafile can be used by the list function
output=$(_z -l 2>&1)
assert_contains "imported data works with z -l (foo)" "$output" "projects/foo"
assert_contains "imported data works with z -l (bar)" "$output" "projects/bar"

# Test 30: After import, _z --add still works
_z --add "$TEST_DIR/tmp/stuff" 2>/dev/null
sleep 0.1  # give subshell time to complete
stuff_rank=$(get_rank "$TEST_DIR/tmp/stuff")
if [ -n "$stuff_rank" ]; then
    pass "z --add works after import"
else
    fail "z --add works after import" "tmp/stuff not found in datafile"
fi

teardown

# ============================================================
# Summary
# ============================================================

echo ""
echo "=========================================="
echo -e "Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}, $TOTAL total"
echo "=========================================="
echo ""

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
