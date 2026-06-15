# Regression tests for z's --export / --import (backup, restore, merge).
# Runs under both bash and zsh:  bash tests.sh   /   zsh tests.sh
#
# Tests exercise the dirty scenarios that matter for migration:
# empty data, duplicate records (across and within files), malformed
# datafiles, missing target directories, dry-run safety and backups.

ZDIR="$(cd "$(dirname "$0")" && pwd)"

# isolated sandbox; never touches the user's real ~/.z
SB="$(mktemp -d "${TMPDIR:-/tmp}/z-tests.XXXXXX")"
export _Z_DATA="$SB/.z"
export _Z_NO_PROMPT_COMMAND=1
unset _Z_OWNER _Z_EXCLUDE_DIRS _Z_MAX_SCORE _Z_CMD

cleanup() { \rm -rf "$SB"; }
trap cleanup EXIT

# real directories that exist on disk (so -d checks pass)
mkdir -p "$SB/projects/app" "$SB/keep" "$SB/newdir"
# $SB/gone is deliberately never created

. "$ZDIR/z.sh"

pass=0; fail=0
ok()   { pass=$((pass+1)); printf 'ok   - %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf 'FAIL - %s\n' "$1"; [ -n "$2" ] && printf '       %s\n' "$2"; }
eq()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3] got [$2]"; fi; }
has()  { case "$2" in *"$3"*) ok "$1";; *) bad "$1" "[$2] missing [$3]";; esac; }
hasnt(){ case "$2" in *"$3"*) bad "$1" "[$2] unexpectedly has [$3]";; *) ok "$1";; esac; }

OUT="$SB/out"; ERR="$SB/err"
run() { _z "$@" >"$OUT" 2>"$ERR"; ST=$?; O="$(<"$OUT")"; E="$(<"$ERR")"; }

set_db() { printf '%s\n' "$@" >| "$_Z_DATA"; }      # write datafile lines
db()     { [ -f "$_Z_DATA" ] && \sort "$_Z_DATA"; } # sorted datafile content

# ---------------------------------------------------------------- export

# T1: export with no data
\rm -f "$_Z_DATA"
run --export
eq   "export empty: exit 0"          "$ST" "0"
eq   "export empty: no stdout data"  "$O"  ""
has  "export empty: message"         "$E"  "nothing to export"

# T2: export skips malformed lines, data->stdout, summary->stderr
set_db "$SB/keep|2|50" "$SB/projects/app|3|100" "this is broken"
run --export
has  "export: keeps valid line A"    "$O" "$SB/keep|2|50"
has  "export: keeps valid line B"    "$O" "$SB/projects/app|3|100"
hasnt "export: drops malformed line" "$O" "this is broken"
has  "export: summary on stderr"     "$E" "exported 2 entries"
has  "export: reports skipped"       "$E" "1 malformed"

# T2b: export to a file argument
run --export "$SB/backup.z"
eq   "export-to-file: exit 0"        "$ST" "0"
has  "export-to-file: confirms path" "$E"  "$SB/backup.z"
eq   "export-to-file: file matches"  "$(\sort "$SB/backup.z")" "$(printf '%s\n' "$SB/keep|2|50" "$SB/projects/app|3|100")"

# T2c: refuse to export onto the live datafile
run --export "$_Z_DATA"
eq   "export-to-self: exit 1"        "$ST" "1"
has  "export-to-self: refuses"       "$E"  "refusing"

# ---------------------------------------------------------------- import: fresh

# T3: import into a missing datafile (new machine restore)
\rm -f "$_Z_DATA" "$_Z_DATA.bak"
set_db_import() { printf '%s\n' "$@" >| "$SB/imp"; }
set_db_import "$SB/keep|2|50" "$SB/newdir|4|300"
run --import "$SB/imp"
eq   "fresh import: exit 0"           "$ST" "0"
eq   "fresh import: 2 entries"        "$(db)" "$(printf '%s\n' "$SB/keep|2|50" "$SB/newdir|4|300")"
has  "fresh import: both are new"     "$E"  "+ new   : 2"
eq   "fresh import: no .bak created"  "$([ -f "$_Z_DATA.bak" ] && echo yes || echo no)" "no"

# ---------------------------------------------------------------- import: merge

reset_for_merge() {
    set_db "$SB/projects/app|3|100" "$SB/keep|2|50"
    \rm -f "$_Z_DATA.bak"
    set_db_import \
        "$SB/projects/app|5|200" \
        "$SB/newdir|4|300" \
        "$SB/newdir|1|250" \
        "$SB/gone|7|400" \
        "garbage line" \
        "$SB/bad|x|123" \
        "$SB/short|123"
}

# T4/T5/T7: merge with duplicates (across + within), missing dir, malformed
reset_for_merge
run --import "$SB/imp"
EXPECT="$(printf '%s\n' "$SB/gone|7|400" "$SB/keep|2|50" "$SB/newdir|5|300" "$SB/projects/app|8|200")"
eq   "merge: datafile contents"       "$(db)" "$EXPECT"
has  "merge: dup path rank summed"    "$(db)" "$SB/projects/app|8|200"
has  "merge: within-file dup summed"  "$(db)" "$SB/newdir|5|300"
has  "merge: counts new=2"            "$E" "+ new   : 2"
has  "merge: counts merged=1"         "$E" "~ merged: 1"
has  "merge: counts kept=1"           "$E" "= kept  : 1"
has  "merge: counts missing=1"        "$E" "! missing: 1"
has  "merge: reports 3 malformed"     "$E" "3 malformed"

# T9: a .bak of the previous data was written
eq   "merge: .bak has old data"       "$(\sort "$_Z_DATA.bak")" "$(printf '%s\n' "$SB/keep|2|50" "$SB/projects/app|3|100")"

# ---------------------------------------------------------------- import: prune

# T8: --prune drops entries whose directory is gone
reset_for_merge
run --import --prune "$SB/imp"
hasnt "prune: missing dir dropped"    "$(db)" "$SB/gone"
has   "prune: existing kept"          "$(db)" "$SB/newdir|5|300"
has   "prune: reports pruned=1"       "$E" "- pruned: 1"

# ---------------------------------------------------------------- import: dry-run

# T6: dry-run changes nothing
reset_for_merge
BEFORE="$(db)"
run --import --dry-run "$SB/imp"
eq   "dry-run: exit 0"                "$ST" "0"
eq   "dry-run: datafile untouched"    "$(db)" "$BEFORE"
eq   "dry-run: no .bak written"       "$([ -f "$_Z_DATA.bak" ] && echo yes || echo no)" "no"
has  "dry-run: says no changes"       "$E" "no changes written"
has  "dry-run: would be written"      "$E" "would be written"
has  "dry-run: previews a new dir"    "$E" "+ $SB/newdir"

# T6b: -n short flag behaves like --dry-run
reset_for_merge
BEFORE="$(db)"
run --import -n "$SB/imp"
eq   "dry-run (-n): datafile untouched" "$(db)" "$BEFORE"

# ---------------------------------------------------------------- import: stdin

# T10: import reads from stdin (pipe migration)
\rm -f "$_Z_DATA" "$_Z_DATA.bak"
set_db_import "$SB/keep|9|99"
_z --import < "$SB/imp" >"$OUT" 2>"$ERR"; ST=$?
eq   "stdin import: exit 0"           "$ST" "0"
has  "stdin import: stored entry"     "$(db)" "$SB/keep|9|99"
# explicit '-' also means stdin
\rm -f "$_Z_DATA"
_z --import - < "$SB/imp" >"$OUT" 2>"$ERR"
has  "stdin import (-): stored entry" "$(db)" "$SB/keep|9|99"

# ---------------------------------------------------------------- import: nasty

# T11: an all-malformed file imports nothing and leaves data + .bak alone
set_db "$SB/keep|2|50"
\rm -f "$_Z_DATA.bak"
printf '%s\n' "junk" "also|junk" "/x|y|z" >| "$SB/bad.z"
run --import "$SB/bad.z"
eq   "all-bad import: exit 0"         "$ST" "0"
has  "all-bad import: nothing msg"    "$E" "nothing to import"
eq   "all-bad import: data untouched" "$(db)" "$SB/keep|2|50"
eq   "all-bad import: no .bak"        "$([ -f "$_Z_DATA.bak" ] && echo yes || echo no)" "no"

# T11b: importing an empty file imports nothing
: >| "$SB/empty.z"
set_db "$SB/keep|2|50"
run --import "$SB/empty.z"
has  "empty-file import: nothing msg" "$E" "nothing to import"
eq   "empty-file import: untouched"   "$(db)" "$SB/keep|2|50"

# T11c: unreadable / missing source file errors cleanly
run --import "$SB/does-not-exist.z"
eq   "missing source: exit 1"         "$ST" "1"
has  "missing source: error msg"      "$E" "cannot read"

# ---------------------------------------------------------------- completion

# T12: subcommand keyword completion (consistent in bash & zsh)
run --complete "z --imp";  eq "complete: --imp -> --import" "$O" "--import"
run --complete "z --exp";  eq "complete: --exp -> --export" "$O" "--export"
run --complete "z --";     has "complete: -- lists import"  "$O" "--import"
run --complete "z --";     has "complete: -- lists export"  "$O" "--export"
# import-arg path completion
run --complete "z --import $SB/ne"
has  "complete: path arg after --import" "$O" "$SB/newdir"
# import sub-flags
run --complete "z --import --"
has  "complete: --import lists --dry-run" "$O" "--dry-run"
has  "complete: --import lists --prune"   "$O" "--prune"

# T12b: regular directory completion still works (no regression)
set_db "$SB/projects/app|3|100"
run --complete "z proj"
has  "complete: normal dir match"     "$O" "$SB/projects/app"

# ---------------------------------------------------------------- help

run -h
has  "help: mentions --export"        "$E" "--export"
has  "help: mentions --import"        "$E" "--import"
has  "help: mentions dry-run"         "$E" "dry-run"

# ---------------------------------------------------------------- summary

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
