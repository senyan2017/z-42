# Copyright (c) 2009 rupa deadwyler. Licensed under the WTFPL license, Version 2

# maintains a jump-list of the directories you actually use
#
# INSTALL:
#     * put something like this in your .bashrc/.zshrc:
#         . /path/to/z.sh
#     * cd around for a while to build up the db
#     * PROFIT!!
#     * optionally:
#         set $_Z_CMD in .bashrc/.zshrc to change the command (default z).
#         set $_Z_DATA in .bashrc/.zshrc to change the datafile (default ~/.z).
#         set $_Z_MAX_SCORE lower to age entries out faster (default 9000).
#         set $_Z_NO_RESOLVE_SYMLINKS to prevent symlink resolution.
#         set $_Z_NO_PROMPT_COMMAND if you're handling PROMPT_COMMAND yourself.
#         set $_Z_EXCLUDE_DIRS to an array of directories to exclude.
#         set $_Z_OWNER to your username if you want use z while sudo with $HOME kept
#
# USE:
#     * z foo     # cd to most frecent dir matching foo
#     * z foo bar # cd to most frecent dir matching foo and bar
#     * z -r foo  # cd to highest ranked dir matching foo
#     * z -t foo  # cd to most recently accessed dir matching foo
#     * z -l foo  # list matches instead of cd
#     * z -e foo  # echo the best match, don't cd
#     * z -c foo  # restrict matches to subdirs of $PWD
#     * z -x      # remove the current directory from the datafile
#     * z -h      # show a brief help message

# ============================================================================
# Data file utilities
# ============================================================================

# Resolve the datafile path, following symlinks.
# Prints the resolved path to stdout.
_z_datafile() {
    local df="${_Z_DATA:-$HOME/.z}"
    [ -h "$df" ] && df=$(readlink "$df")
    printf '%s' "$df"
}

# Check whether the current user owns the datafile (or is $_Z_OWNER).
# Returns 0 if we may read/write, 1 otherwise.
_z_datafile_accessible() {
    local df="$1"
    [ -n "$_Z_OWNER" ] && return 0
    [ -f "$df" ] && [ ! -O "$df" ] && return 1
    return 0
}

# Read the datafile and emit only lines whose directory still exists.
# Each line: path|rank|timestamp
_z_dirs() {
    local df="$(_z_datafile)"
    [ -f "$df" ] || return
    local line
    while read line; do
        [ -d "${line%%\|*}" ] && printf '%s\n' "$line"
    done < "$df"
}

# ============================================================================
# Data file maintenance: add and remove entries
# ============================================================================

# Add a directory to the datafile with updated rank and timestamp.
# Handles aging: when total rank exceeds $_Z_MAX_SCORE, all ranks are
# multiplied by 0.99. Entries with rank < 1 are dropped.
_z_add() {
    local df="$(_z_datafile)"

    # $HOME and / aren't worth matching
    [ "$1" = "$HOME" -o "$1" = '/' ] && return

    # don't track excluded directory trees
    if [ ${#_Z_EXCLUDE_DIRS[@]} -gt 0 ]; then
        local exclude
        for exclude in "${_Z_EXCLUDE_DIRS[@]}"; do
            case "$1" in "$exclude"*) return;; esac
        done
    fi

    # bail if we don't own the datafile
    _z_datafile_accessible "$df" || return

    # maintain the data file
    local tempfile="$df.$RANDOM"
    local score=${_Z_MAX_SCORE:-9000}
    _z_dirs | \awk -v path="$1" -v now="$(\date +%s)" -v score=$score -F"|" '
        BEGIN {
            rank[path] = 1
            time[path] = now
        }
        $2 >= 1 {
            # drop ranks below 1
            if( $1 == path ) {
                rank[$1] = $2 + 1
                time[$1] = now
            } else {
                rank[$1] = $2
                time[$1] = $3
            }
            count += $2
        }
        END {
            if( count > score ) {
                # aging: scale all ranks down by 0.99
                for( x in rank ) print x "|" 0.99*rank[x] "|" time[x]
            } else for( x in rank ) print x "|" rank[x] "|" time[x]
        }
    ' 2>/dev/null >| "$tempfile"

    # do our best to avoid clobbering the datafile in a race condition
    if [ $? -ne 0 -a -f "$df" ]; then
        \env rm -f "$tempfile"
    else
        [ "$_Z_OWNER" ] && chown $_Z_OWNER:"$(id -ng $_Z_OWNER)" "$tempfile"
        \env mv -f "$tempfile" "$df" || \env rm -f "$tempfile"
    fi
}

# Remove the current directory from the datafile.
_z_remove() {
    local df="$(_z_datafile)"
    \sed -i -e "\:^${PWD}|.*:d" "$df"
}

# ============================================================================
# Matching and scoring (awk-based core logic)
# ============================================================================
#
# Matching rules (applied in order):
#   1. Each query argument is joined with ".*" so "foo bar" matches paths
#      containing "foo" then "bar" in order (regex).
#   2. Case-sensitive match is tried first. If no case-sensitive match
#   3. If no case-sensitive match exists, falls back to case-insensitive.
#   4. Scoring depends on -r (rank), -t (recent), or default (frecency).
#   5. When listing (-l), all matches are printed sorted by score.
#   6. When navigating (no -l), if all matches share a common prefix,
#      the shortest matching path is chosen instead of the highest-scored one.
#      This is the "common root" behavior.
#
# Frecency formula:
#   dx = now - last_access_time
#   frecency = int(10000 * rank * (3.75 / ((0.0001 * dx + 1) + 0.25)))
#
# _z_match outputs the chosen directory path (or list) to stdout.
# Returns 0 on success, 1 if no match found.

_z_match() {
    local list="$1" typ="$2" query="$3"
    local df="$(_z_datafile)"

    [ -f "$df" ] || return 1

    < <( _z_dirs ) \awk -v t="$(\date +%s)" -v list="$list" -v typ="$typ" -v q="$query" -F"|" '
        function frecent(rank, time) {
            # Combine frequency and recency into a single score.
            # More recent accesses decay slowly; old accesses decay fast.
            dx = t - time
            return int(10000 * rank * (3.75/((0.0001 * dx + 1) + 0.25)))
        }
        function common(matches) {
            # Find the shortest path among matches, then check if it is
            # a prefix of ALL other matches. If so, return it (the "common root").
            # Otherwise return "" (no common root).
            for( x in matches ) {
                if( !short || length(x) < length(short) ) {
                    short = x
                }
            }
            if( short == "/" ) return
            for( x in matches ) if( index(x, short) != 1 ) {
                return
            }
            return short
        }
        function output(matches, best_match, common_prefix) {
            # In list mode: print all matches sorted by score.
            # In navigate mode: print the best match, or the common prefix
            # if one exists and no explicit sort type (-r/-t) was given.
            if( list ) {
                if( common_prefix ) {
                    printf "%-10s %s\n", "common:", common_prefix > "/dev/stderr"
                }
                cmd = "sort -n >&2"
                for( x in matches ) {
                    printf "%-10s %s\n", matches[x], x | cmd
                }
            } else {
                if( common_prefix && !typ ) best_match = common_prefix
                print best_match
            }
        }
        BEGIN {
            # Convert space-separated query into a regex: "foo bar" -> "foo.*bar"
            gsub(" ", ".*", q)
            hi_rank = ihi_rank = -9999999999
        }
        {
            # Compute the score for this entry based on the sort type.
            if( typ == "rank" ) {
                rank = $2
            } else if( typ == "recent" ) {
                rank = $3 - t
            } else rank = frecent($2, $3)

            # Try case-sensitive match first, then case-insensitive fallback.
            if( $1 ~ q ) {
                matches[$1] = rank
            } else if( tolower($1) ~ tolower(q) ) imatches[$1] = rank

            # Track the best match in each category.
            # Use "in" checks to avoid treating rank=0 as falsy.
            if( ($1 in matches) && matches[$1] > hi_rank ) {
                best_match = $1
                hi_rank = matches[$1]
            } else if( ($1 in imatches) && imatches[$1] > ihi_rank ) {
                ibest_match = $1
                ihi_rank = imatches[$1]
            }
        }
        END {
            # Prefer case-sensitive matches; fall back to case-insensitive.
            if( best_match ) {
                output(matches, best_match, common(matches))
                exit
            } else if( ibest_match ) {
                output(imatches, ibest_match, common(imatches))
                exit
            }
            exit(1)
        }
    '
}

# ============================================================================
# Tab completion
# ============================================================================

# Given a completion query string, print matching directory paths.
# The query has a 2-character prefix (from COMP_LINE or compctl) that is
# stripped before matching.
_z_complete() {
    local query="$1"
    local df="$(_z_datafile)"

    [ -s "$df" ] || return

    _z_dirs | \awk -v q="$query" -F"|" '
        BEGIN {
            # Strip the 2-char prefix added by the completion framework.
            q = substr(q, 3)
            # If the query is all lowercase, do case-insensitive matching.
            if( q == tolower(q) ) imatch = 1
            # Convert spaces to "match anything in between" regex.
            gsub(/ /, ".*", q)
        }
        {
            if( imatch ) {
                if( tolower($1) ~ q ) print $1
            } else if( $1 ~ q ) print $1
        }
    ' 2>/dev/null
}

# ============================================================================
# Argument parsing
# ============================================================================

# Parse command-line arguments into structured results.
# Sets the following variables in the caller's scope via eval:
#   _Z_PARSE_QUERY  - space-separated search terms (with ^PWD prefix for -c)
#   _Z_PARSE_TYPE   - "rank", "recent", or "" (frecency)
#   _Z_PARSE_LIST   - 1 if -l was given, "" otherwise
#   _Z_PARSE_ECHO   - 1 if -e was given, "" otherwise
#   _Z_PARSE_LAST   - the last argument (used for completion shortcut)
_z_parse_args() {
    local fnd last opt typ echo list

    while [ "$1" ]; do case "$1" in
        --) while [ "$1" ]; do shift; [ "$1" ] && fnd="$fnd${fnd:+ }$1"; done;;
        -*) opt=${1:1}; while [ "$opt" ]; do case ${opt:0:1} in
                c) fnd="^$PWD $fnd";;
                e) echo=1;;
                h) printf '%s [-cehlrtx] args\n' "${_Z_CMD:-z}" >&2; return 1;;
                l) list=1;;
                r) typ="rank";;
                t) typ="recent";;
                x) _z_remove; return 1;;
            esac; opt=${opt:1}; done;;
         *) fnd="$fnd${fnd:+ }$1";;
    esac; last=$1; [ "$#" -gt 0 ] && shift; done

    # No query or only -c with no terms => list mode
    [ "$fnd" -a "$fnd" != "^$PWD " ] || list=1

    _Z_PARSE_QUERY="$fnd"
    _Z_PARSE_TYPE="$typ"
    _Z_PARSE_LIST="$list"
    _Z_PARSE_ECHO="$echo"
    _Z_PARSE_LAST="$last"
    return 0
}

# ============================================================================
# Main entry point
# ============================================================================

_z() {

    # --add: called from prompt hook to record directory visits
    if [ "$1" = "--add" ]; then
        shift
        _z_add "$*"
        return
    fi

    # --complete: called from tab-completion framework
    if [ "$1" = "--complete" ]; then
        _z_complete "$2"
        return
    fi

    # Everything else: list or navigate
    _z_parse_args "$@" || return

    local last="$_Z_PARSE_LAST"

    # If the user hit enter on a completion result (absolute path to
    # an existing directory), just go there directly.
    case "$last" in
        /*) [ -z "$_Z_PARSE_LIST" -a -d "$last" ] && builtin cd "$last" && return;;
    esac

    local cd
    cd="$(_z_match "$_Z_PARSE_LIST" "$_Z_PARSE_TYPE" "$_Z_PARSE_QUERY")"

    if [ "$?" -eq 0 ]; then
        if [ "$cd" ]; then
            if [ "$_Z_PARSE_ECHO" ]; then
                printf '%s\n' "$cd"
            else
                builtin cd "$cd"
            fi
        fi
    else
        return $?
    fi
}

# ============================================================================
# Alias
# ============================================================================

alias ${_Z_CMD:-z}='_z 2>&1'

# ============================================================================
# Shell integration: hooks and completion registration
# ============================================================================

[ "$_Z_NO_RESOLVE_SYMLINKS" ] || _Z_RESOLVE_SYMLINKS="-P"

# --- Datafile startup check ------------------------------------------------
[ -d "${_Z_DATA:-$HOME/.z}" ] && {
    echo "ERROR: z.sh's datafile (${_Z_DATA:-$HOME/.z}) is a directory."
}

# --- zsh integration -------------------------------------------------------
if type compctl >/dev/null 2>&1; then

    # Prompt hook: record the current directory after each command.
    [ "$_Z_NO_PROMPT_COMMAND" ] || {
        if [ "$_Z_NO_RESOLVE_SYMLINKS" ]; then
            _z_precmd() {
                (_z --add "${PWD:a}" &)
                : $RANDOM
            }
        else
            _z_precmd() {
                (_z --add "${PWD:A}" &)
                : $RANDOM
            }
        fi
        [[ -n "${precmd_functions[(r)_z_precmd]}" ]] || {
            precmd_functions[$(($#precmd_functions+1))]=_z_precmd
        }
    }

    # Tab completion for zsh.
    _z_zsh_tab_completion() {
        local compl
        read -l compl
        reply=(${(f)"$(_z --complete "$compl")"})
    }
    compctl -U -K _z_zsh_tab_completion _z

# --- bash integration ------------------------------------------------------
elif type complete >/dev/null 2>&1; then

    # Tab completion for bash.
    complete -o filenames -C '_z --complete "$COMP_LINE"' ${_Z_CMD:-z}

    # Prompt hook: record the current directory after each command.
    [ "$_Z_NO_PROMPT_COMMAND" ] || {
        grep "_z --add" <<< "$PROMPT_COMMAND" >/dev/null || {
            PROMPT_COMMAND="$PROMPT_COMMAND"$'\n''(_z --add "$(command pwd '$_Z_RESOLVE_SYMLINKS' 2>/dev/null)" 2>/dev/null &);'
        }
    }
fi
