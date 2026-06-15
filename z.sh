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
#
# INTERNALS:
#     The command is one thin dispatcher (_z) over a handful of single-purpose
#     helpers, so each concern can be read and tested in isolation:
#         _z_datafile  resolve the datafile path (symlink aware)
#         _z_dirs      read the datafile, keep only entries that still exist
#         _z_add       record/age a visit and rewrite the datafile atomically
#         _z_remove    drop a directory's entry from the datafile
#         _z_query     match candidates on stdin and pick (or list) the winner
#         _z_complete  emit completion candidates for the current command line
#     Shell wiring (prompt hook + tab completion) lives in the bash/zsh blocks
#     at the bottom of this file.

[ -d "${_Z_DATA:-$HOME/.z}" ] && {
    echo "ERROR: z.sh's datafile (${_Z_DATA:-$HOME/.z}) is a directory."
}

# ---------------------------------------------------------------------------
# datafile location
# ---------------------------------------------------------------------------

# Print the datafile path, dereferencing it once if it is a symlink.
_z_datafile() {
    local datafile="${_Z_DATA:-$HOME/.z}"
    [ -h "$datafile" ] && datafile=$(readlink "$datafile")
    echo "$datafile"
}

# ---------------------------------------------------------------------------
# data file reading
# ---------------------------------------------------------------------------

# Emit every datafile entry ("dir|rank|time") whose directory still exists,
# one per line. This is the only place the datafile is read from disk.
_z_dirs() {
    local datafile="$1" line
    [ -f "$datafile" ] || return

    while read line; do
        # only count directories that still exist
        [ -d "${line%%\|*}" ] && echo "$line"
    done < "$datafile"
    return 0
}

# ---------------------------------------------------------------------------
# directory writing / maintenance
# ---------------------------------------------------------------------------

# _z_add DATAFILE DIR...
# Record a visit to DIR, then rewrite DATAFILE atomically.
#
# Aging rule:
#     * the visited dir starts at rank 1, or is bumped by +1, with time=now
#     * entries whose rank has decayed below 1 are forgotten
#     * once the summed rank of existing entries passes $_Z_MAX_SCORE every
#       rank is multiplied by 0.99 (keeps the datafile from growing forever)
_z_add() {
    local datafile="$1"; shift
    local path="$*"

    # $HOME and / aren't worth matching
    [ "$path" = "$HOME" -o "$path" = '/' ] && return

    # don't track excluded directory trees
    if [ ${#_Z_EXCLUDE_DIRS[@]} -gt 0 ]; then
        local exclude
        for exclude in "${_Z_EXCLUDE_DIRS[@]}"; do
            case "$path" in "$exclude"*) return;; esac
        done
    fi

    # maintain the data file
    local tempfile="$datafile.$RANDOM"
    local score=${_Z_MAX_SCORE:-9000}
    _z_dirs "$datafile" | \awk -v path="$path" -v now="$(\date +%s)" -v score=$score -F"|" '
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
                # aging
                for( x in rank ) print x "|" 0.99*rank[x] "|" time[x]
            } else for( x in rank ) print x "|" rank[x] "|" time[x]
        }
    ' 2>/dev/null >| "$tempfile"
    # do our best to avoid clobbering the datafile in a race condition.
    if [ $? -ne 0 -a -f "$datafile" ]; then
        \env rm -f "$tempfile"
    else
        [ "$_Z_OWNER" ] && chown $_Z_OWNER:"$(id -ng $_Z_OWNER)" "$tempfile"
        \env mv -f "$tempfile" "$datafile" || \env rm -f "$tempfile"
    fi
}

# _z_remove DATAFILE DIR
# Delete DIR's entry from the datafile in place.
_z_remove() {
    local datafile="$1" dir="$2"
    \sed -i -e "\:^${dir}|.*:d" "$datafile"
}

# ---------------------------------------------------------------------------
# completion
# ---------------------------------------------------------------------------

# _z_complete DATAFILE COMPLINE
# Print directories matching the partial command line COMPLINE.
_z_complete() {
    local datafile="$1" compline="$2"
    [ -s "$datafile" ] || return

    _z_dirs "$datafile" | \awk -v q="$compline" -F"|" '
        BEGIN {
            # the completion line still carries the command + space prefix;
            # drop those two leading characters to recover the query
            q = substr(q, 3)
            # an all-lowercase query matches case-insensitively
            if( q == tolower(q) ) imatch = 1
            gsub(/ /, ".*", q)
        }
        {
            if( imatch ) {
                if( tolower($1) ~ q ) print $1
            } else if( $1 ~ q ) print $1
        }
    ' 2>/dev/null
}

# ---------------------------------------------------------------------------
# candidate matching + sort decision
# ---------------------------------------------------------------------------

# _z_query NOW LIST TYP QUERY   (reads "dir|rank|time" lines on stdin)
# Print the single best directory on stdout, or - when LIST is set - print all
# matches to stderr. Exits non-zero when nothing matches.
#
# Selection rules, applied in order:
#   1. scoring mode (TYP) decides each row's score:
#        rank    -> the raw rank ($2)
#        recent  -> recency ($3 - now; the least negative is most recent)
#        (unset) -> frecency: rank weighted by how recently it was accessed
#   2. a case-sensitive regex match is preferred; only if nothing matches with
#      case sensitivity do we fall back to the case-insensitive matches
#   3. when every match shares a common path prefix (and we are not in rank or
#      recent mode) that shortest common directory wins, ignoring score
_z_query() {
    \awk -v t="$1" -v list="$2" -v typ="$3" -v q="$4" -F"|" '
        function frecent(rank, time) {
            # relate frequency and time
            dx = t - time
            return int(10000 * rank * (3.75/((0.0001 * dx + 1) + 0.25)))
        }
        function output(matches, best_match, common) {
            # list or return the desired directory
            if( list ) {
                if( common ) {
                    printf "%-10s %s\n", "common:", common > "/dev/stderr"
                }
                cmd = "sort -n >&2"
                for( x in matches ) {
                    if( matches[x] ) {
                        printf "%-10s %s\n", matches[x], x | cmd
                    }
                }
            } else {
                if( common && !typ ) best_match = common
                print best_match
            }
        }
        function common(matches) {
            # find the common root of a list of matches, if it exists
            for( x in matches ) {
                if( matches[x] && (!short || length(x) < length(short)) ) {
                    short = x
                }
            }
            if( short == "/" ) return
            for( x in matches ) if( matches[x] && index(x, short) != 1 ) {
                return
            }
            return short
        }
        BEGIN {
            # the query is a series of regexes that must all match, in order
            gsub(" ", ".*", q)
            hi_rank = ihi_rank = -9999999999
        }
        {
            # score this row, then file it as a case-sensitive or, failing
            # that, case-insensitive match, tracking the best of each
            if( typ == "rank" ) {
                rank = $2
            } else if( typ == "recent" ) {
                rank = $3 - t
            } else rank = frecent($2, $3)
            if( $1 ~ q ) {
                matches[$1] = rank
            } else if( tolower($1) ~ tolower(q) ) imatches[$1] = rank
            if( matches[$1] && matches[$1] > hi_rank ) {
                best_match = $1
                hi_rank = matches[$1]
            } else if( imatches[$1] && imatches[$1] > ihi_rank ) {
                ibest_match = $1
                ihi_rank = imatches[$1]
            }
        }
        END {
            # prefer case sensitive
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

# ---------------------------------------------------------------------------
# command dispatch
# ---------------------------------------------------------------------------

_z() {
    local datafile
    datafile="$(_z_datafile)"

    # bail if we don't own ~/.z and $_Z_OWNER not set
    [ -z "$_Z_OWNER" -a -f "$datafile" -a ! -O "$datafile" ] && return

    # add entries
    if [ "$1" = "--add" ]; then
        shift
        _z_add "$datafile" "$@"
        return
    fi

    # tab completion
    if [ "$1" = "--complete" ]; then
        _z_complete "$datafile" "$2"
        return
    fi

    # list/go
    local echo fnd last list opt typ
    while [ "$1" ]; do case "$1" in
        --) while [ "$1" ]; do shift; fnd="$fnd${fnd:+ }$1";done;;
        -*) opt=${1:1}; while [ "$opt" ]; do case ${opt:0:1} in
                c) fnd="^$PWD $fnd";;
                e) echo=1;;
                h) echo "${_Z_CMD:-z} [-cehlrtx] args" >&2; return;;
                l) list=1;;
                r) typ="rank";;
                t) typ="recent";;
                x) _z_remove "$datafile" "$PWD";;
            esac; opt=${opt:1}; done;;
         *) fnd="$fnd${fnd:+ }$1";;
    esac; last=$1; [ "$#" -gt 0 ] && shift; done
    [ "$fnd" -a "$fnd" != "^$PWD " ] || list=1

    # if we hit enter on a completion just go there
    case "$last" in
        # completions will always start with /
        /*) [ -z "$list" -a -d "$last" ] && builtin cd "$last" && return;;
    esac

    # no file yet
    [ -f "$datafile" ] || return

    local cd
    cd="$( _z_dirs "$datafile" | _z_query "$(\date +%s)" "$list" "$typ" "$fnd" )"

    if [ "$?" -eq 0 ]; then
      if [ "$cd" ]; then
        if [ "$echo" ]; then echo "$cd"; else builtin cd "$cd"; fi
      fi
    else
      return $?
    fi
}

alias ${_Z_CMD:-z}='_z 2>&1'

[ "$_Z_NO_RESOLVE_SYMLINKS" ] || _Z_RESOLVE_SYMLINKS="-P"

# ---------------------------------------------------------------------------
# shell wiring
# ---------------------------------------------------------------------------

if type compctl >/dev/null 2>&1; then
    #### zsh ###################################################################

    # datafile maintenance: feed each prompt's $PWD to the adder in the
    # background, without clobbering any other precmd hooks.
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

    # tab completion: hand the current line to `_z --complete`
    _z_zsh_tab_completion() {
        local compl
        read -l compl
        reply=(${(f)"$(_z --complete "$compl")"})
    }
    compctl -U -K _z_zsh_tab_completion _z

elif type complete >/dev/null 2>&1; then
    #### bash ##################################################################

    # tab completion: hand the current line to `_z --complete`
    complete -o filenames -C '_z --complete "$COMP_LINE"' ${_Z_CMD:-z}

    # datafile maintenance: append the adder to PROMPT_COMMAND, without
    # clobbering any other PROMPT_COMMANDs already in place.
    [ "$_Z_NO_PROMPT_COMMAND" ] || {
        grep "_z --add" <<< "$PROMPT_COMMAND" >/dev/null || {
            PROMPT_COMMAND="$PROMPT_COMMAND"$'\n''(_z --add "$(command pwd '$_Z_RESOLVE_SYMLINKS' 2>/dev/null)" 2>/dev/null &);'
        }
    }
fi
