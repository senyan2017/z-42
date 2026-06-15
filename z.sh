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
#     * z --export [file]                # export database (to file or stdout)
#     * z --import [--keep-dead] <file>  # import and merge from file
#     * z --import-dry-run [--keep-dead] <file>  # preview import without changes

[ -d "${_Z_DATA:-$HOME/.z}" ] && {
    echo "ERROR: z.sh's datafile (${_Z_DATA:-$HOME/.z}) is a directory."
}

_z() {

    local datafile="${_Z_DATA:-$HOME/.z}"

    # if symlink, dereference
    [ -h "$datafile" ] && datafile=$(readlink "$datafile")

    # bail if we don't own ~/.z and $_Z_OWNER not set
    [ -z "$_Z_OWNER" -a -f "$datafile" -a ! -O "$datafile" ] && return

    _z_dirs () {
        [ -f "$datafile" ] || return

        local line
        while read line; do
            # only count directories
            [ -d "${line%%\|*}" ] && echo "$line"
        done < "$datafile"
        return 0
    }

    # add entries
    if [ "$1" = "--add" ]; then
        shift

        # $HOME and / aren't worth matching
        [ "$*" = "$HOME" -o "$*" = '/' ] && return

        # don't track excluded directory trees
        if [ ${#_Z_EXCLUDE_DIRS[@]} -gt 0 ]; then
            local exclude
            for exclude in "${_Z_EXCLUDE_DIRS[@]}"; do
                case "$*" in "$exclude"*) return;; esac
            done
        fi

        # maintain the data file
        local tempfile="$datafile.$RANDOM"
        local score=${_Z_MAX_SCORE:-9000}
        _z_dirs | \awk -v path="$*" -v now="$(\date +%s)" -v score=$score -F"|" '
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

    # tab completion
    elif [ "$1" = "--complete" -a -s "$datafile" ]; then
        _z_dirs | \awk -v q="$2" -F"|" '
            BEGIN {
                q = substr(q, 3)
                if( q == tolower(q) ) imatch = 1
                gsub(/ /, ".*", q)
            }
            {
                if( imatch ) {
                    if( tolower($1) ~ q ) print $1
                } else if( $1 ~ q ) print $1
            }
        ' 2>/dev/null

    # export database
    elif [ "$1" = "--export" ]; then
        shift
        if [ -f "$datafile" ]; then
            if [ -n "$1" ]; then
                _z_dirs >| "$1" 2>/dev/null
                [ $? -eq 0 ] && echo "Exported $(\awk 'END{print NR}' "$1") entries to $1" >&2
            else
                _z_dirs
            fi
        else
            echo "No datafile found at $datafile" >&2
            return 1
        fi

    # import and merge database
    elif [ "$1" = "--import" ]; then
        shift
        local keep_dead=""
        [ "$1" = "--keep-dead" ] && { keep_dead=1; shift; }
        local import_file="$1"
        if [ -z "$import_file" ]; then
            echo "Usage: ${_Z_CMD:-z} --import [--keep-dead] <file>" >&2
            return 1
        fi
        if [ ! -f "$import_file" ]; then
            echo "Import file not found: $import_file" >&2
            return 1
        fi
        # ensure datafile exists so awk processes both files correctly (mawk compat)
        [ -f "$datafile" ] || touch "$datafile"
        local tempfile="$datafile.$RANDOM"
        local summary_file="$datafile.summary.$$"
        \awk -v keep_dead="$keep_dead" -v summary_file="$summary_file" '
            BEGIN { FS="|"; OFS="|" }
            # Pass 1 (NR==FNR): read import file
            NR==FNR {
                if( NF < 3 ) { bad++; next }
                if( $2+0 != $2 || $3+0 != $3 ) { bad++; next }
                path = $1; rank = $2+0; ts = $3+0
                if( rank < 1 ) { skipped++; next }
                i_rank[path] = rank; i_time[path] = ts; i_paths[path] = 1
                next
            }
            # Pass 2: read existing datafile
            FNR!=NR {
                if( NF < 3 ) next
                path = $1
                if( path in i_paths ) {
                    if( i_rank[path] > $2+0 ) { rank = i_rank[path] } else { rank = $2+0 }
                    if( i_time[path] > $3+0 ) { ts = i_time[path] } else { ts = $3+0 }
                    delete i_paths[path]
                } else {
                    rank = $2+0; ts = $3+0
                }
                if( keep_dead || system("test -d \"" path "\"") == 0 ) {
                    e_rank[path] = rank
                    e_time[path] = ts
                } else {
                    dead++
                }
            }
            END {
                for( p in i_paths ) {
                    if( keep_dead || system("test -d \"" p "\"") == 0 ) {
                        e_rank[p] = i_rank[p]; e_time[p] = i_time[p]; added++
                    } else {
                        dead++; skipped++
                    }
                }
                for( p in e_rank ) print p, e_rank[p], e_time[p]
                printf "%d added, %d dead entries skipped\n", added+0, dead+0 > summary_file
            }
        ' "$import_file" "$datafile" >| "$tempfile"
        if [ $? -ne 0 ]; then
            \env rm -f "$tempfile" "$summary_file"
            echo "Import failed" >&2
            return 1
        fi
        local imported_count=$(\awk 'END{print NR}' "$tempfile")
        [ "$_Z_OWNER" ] && \chown "$_Z_OWNER":"$(\id -ng "$_Z_OWNER")" "$tempfile"
        \env mv -f "$tempfile" "$datafile" || { \env rm -f "$tempfile" "$summary_file"; return 1; }
        local dead_info=""
        [ -f "$summary_file" ] && { dead_info=$(\cat "$summary_file"); \env rm -f "$summary_file"; }
        echo "Import complete: $imported_count entries in database" >&2
        [ -n "$dead_info" ] && echo "$dead_info" >&2

    # import dry-run: preview merge without modifying datafile
    elif [ "$1" = "--import-dry-run" ]; then
        shift
        local keep_dead=""
        [ "$1" = "--keep-dead" ] && { keep_dead=1; shift; }
        local import_file="$1"
        if [ -z "$import_file" ]; then
            echo "Usage: ${_Z_CMD:-z} --import-dry-run [--keep-dead] <file>" >&2
            return 1
        fi
        if [ ! -f "$import_file" ]; then
            echo "Import file not found: $import_file" >&2
            return 1
        fi
        # use empty temp file if datafile doesn't exist (mawk compat)
        local existing_datafile="$datafile"
        if [ ! -f "$existing_datafile" ]; then
            existing_datafile="$datafile.dryrun.$$"
            touch "$existing_datafile"
        fi
        \awk -v keep_dead="$keep_dead" '
            BEGIN { FS="|"; OFS="|" }
            NR==FNR {
                if( NF < 3 ) { bad++; next }
                if( $2+0 != $2 || $3+0 != $3 ) { bad++; next }
                path = $1; rank = $2+0; ts = $3+0
                if( rank < 1 ) { skipped++; next }
                i_rank[path] = rank; i_time[path] = ts; i_paths[path] = 1
                next
            }
            FNR!=NR {
                if( NF < 3 ) { bad++; next }
                path = $1; e_rank[path] = $2+0; e_time[path] = $3+0
                if( path in i_paths ) {
                    if( i_rank[path] > e_rank[path] ) { nr = i_rank[path] } else { nr = e_rank[path] }
                    if( i_time[path] > e_time[path] ) { nt = i_time[path] } else { nt = e_time[path] }
                    if( nr != e_rank[path] || nt != e_time[path] ) {
                        printf "  UPDATE %s (rank: %s -> %s, time: %s -> %s)\n", path, e_rank[path], nr, e_time[path], nt
                        updated++
                    } else { unchanged++ }
                    delete i_paths[path]
                } else { unchanged++ }
            }
            END {
                added=0; dead=0
                for( p in i_paths ) {
                    if( keep_dead || system("test -d \"" p "\"") == 0 ) {
                        printf "  NEW    %s (rank: %s, time: %s)\n", p, i_rank[p], i_time[p]
                        added++
                    } else {
                        printf "  SKIP   %s (directory does not exist)\n", p
                        dead++
                    }
                }
                printf "\nSummary: %d new, %d updated, %d unchanged", added, updated+0, unchanged+0
                if( bad+0 > 0 ) printf ", %d malformed lines skipped", bad
                if( skipped+0 > 0 ) printf ", %d low-rank entries skipped", skipped
                if( dead > 0 ) printf ", %d dead directories skipped", dead
                printf "\n"
            }
        ' "$import_file" "$existing_datafile" 2>/dev/null
        # clean up temp file if we created one
        [ "$existing_datafile" != "$datafile" ] && \env rm -f "$existing_datafile"

    else
        # list/go
        local echo fnd last list opt typ
        while [ "$1" ]; do case "$1" in
            --) while [ "$1" ]; do shift; fnd="$fnd${fnd:+ }$1";done;;
            -*) opt=${1:1}; while [ "$opt" ]; do case ${opt:0:1} in
                    c) fnd="^$PWD $fnd";;
                    e) echo=1;;
                    h) echo "Usage: ${_Z_CMD:-z} [-cehlrtx] [args]" >&2
                       echo "       ${_Z_CMD:-z} --export [file]        export database to file (stdout if no file)" >&2
                       echo "       ${_Z_CMD:-z} --import [--keep-dead] <file>  import and merge database" >&2
                       echo "       ${_Z_CMD:-z} --import-dry-run [--keep-dead] <file>  preview import without changes" >&2;;
                    l) list=1;;
                    r) typ="rank";;
                    t) typ="recent";;
                    x) \sed -i -e "\:^${PWD}|.*:d" "$datafile";;
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
        cd="$( < <( _z_dirs ) \awk -v t="$(\date +%s)" -v list="$list" -v typ="$typ" -v q="$fnd" -F"|" '
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
                gsub(" ", ".*", q)
                hi_rank = ihi_rank = -9999999999
            }
            {
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
        ')"

        if [ "$?" -eq 0 ]; then
          if [ "$cd" ]; then
            if [ "$echo" ]; then echo "$cd"; else builtin cd "$cd"; fi
          fi
        else
          return $?
        fi
    fi
}

alias ${_Z_CMD:-z}='_z 2>&1'

[ "$_Z_NO_RESOLVE_SYMLINKS" ] || _Z_RESOLVE_SYMLINKS="-P"

if type compctl >/dev/null 2>&1; then
    # zsh
    [ "$_Z_NO_PROMPT_COMMAND" ] || {
        # populate directory list, avoid clobbering any other precmds.
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
    _z_zsh_tab_completion() {
        # tab completion
        local compl
        read -l compl
        reply=(${(f)"$(_z --complete "$compl")"})
    }
    compctl -U -K _z_zsh_tab_completion _z
elif type complete >/dev/null 2>&1; then
    # bash
    # tab completion
    complete -o filenames -C '_z --complete "$COMP_LINE"' ${_Z_CMD:-z}
    [ "$_Z_NO_PROMPT_COMMAND" ] || {
        # populate directory list. avoid clobbering other PROMPT_COMMANDs.
        grep "_z --add" <<< "$PROMPT_COMMAND" >/dev/null || {
            PROMPT_COMMAND="$PROMPT_COMMAND"$'\n''(_z --add "$(command pwd '$_Z_RESOLVE_SYMLINKS' 2>/dev/null)" 2>/dev/null &);'
        }
    }
fi
