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
#     * z --export [file]    # print the datafile to stdout (or file) for backup
#     * z --import [file]    # merge a datafile (or stdin) into yours
#     * z --import -n file   # preview (dry-run) a merge, change nothing
#     * z --import -p file   # merge, pruning entries whose dir no longer exists

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

    # tab completion (bash and zsh both feed the whole line in as "$2")
    elif [ "$1" = "--complete" ]; then
        local cline="$2"
        local cword="${cline##* }"
        case "$cword" in
            # completing a subcommand or option keyword
            --i*) echo "--import";;
            --e*) echo "--export";;
            --h*) echo "--help";;
            --d*) echo "--dry-run";;
            --p*) echo "--prune";;
            --*) case "$cline" in
                    *' --import'*|*' --export'*) printf '%s\n' --dry-run --prune;;
                    *) printf '%s\n' --export --import --help;;
                 esac;;
            *) case "$cline" in
                    # argument position of --import/--export -> complete a path
                    *' --import '*|*' --export '*)
                        # zsh: null_glob so an unmatched pattern vanishes instead
                        # of erroring; harmless no-op command in bash.
                        [ -n "$ZSH_VERSION" ] && setopt local_options null_glob 2>/dev/null
                        local f
                        for f in "$cword"*; do
                            [ -e "$f" ] && printf '%s\n' "$f"
                        done;;
                    # normal directory completion by frecency match
                    *) [ -s "$datafile" ] && _z_dirs | \awk -v q="$2" -F"|" '
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
                    ' 2>/dev/null;;
                 esac;;
        esac

    # export the datafile to stdout (or a file) for backup / migration.
    # data goes to stdout; all messages go to stderr, so that
    # `z --export > backup` produces a clean datafile.
    elif [ "$1" = "--export" ]; then
        shift
        local out="$1"

        if [ ! -s "$datafile" ]; then
            echo "z: nothing to export ($datafile is empty or missing)" >&2
            return 0
        fi
        if [ -n "$out" ] && [ "$out" != "-" ] && [ "$out" = "$datafile" ]; then
            echo "z: refusing to export onto the live datafile ($datafile)" >&2
            return 1
        fi

        local exportprog='
            {
                if( NF==3 && $1!="" && $2 ~ /^[0-9]+([.][0-9]+)?$/ && $3 ~ /^[0-9]+$/ ) {
                    print; good++
                } else if( length($0) ) bad++
            }
            END {
                printf "z: exported %d entr%s", (good+0), (good==1?"y":"ies") > "/dev/stderr"
                if( bad ) printf " (%d malformed line(s) skipped)", bad > "/dev/stderr"
                printf "\n" > "/dev/stderr"
            }'

        if [ -n "$out" ] && [ "$out" != "-" ]; then
            \awk -F"|" "$exportprog" "$datafile" >| "$out" && \
                echo "z: backup written to $out" >&2
        else
            \awk -F"|" "$exportprog" "$datafile"
        fi

    # import (merge) a datafile exported from another machine.
    #   -n / --dry-run : preview only, never touch the datafile
    #   -p / --prune   : drop entries whose directory is absent here
    # merge rules: duplicate path -> rank summed, newest time kept;
    # new dirs added; existing untouched dirs kept; malformed lines skipped.
    elif [ "$1" = "--import" ]; then
        shift
        local dry=0 prune=0 src=""
        while [ "$1" ]; do case "$1" in
            -n|--dry-run) dry=1;;
            -p|--prune)   prune=1;;
            -)            src="-";;
            --)           shift; [ "$1" ] && src="$1";;
            -*)           echo "z: unknown import option: $1" >&2; return 1;;
            *)            src="$1";;
        esac; [ "$#" -gt 0 ] && shift; done

        local srcdesc="<stdin>"
        [ -n "$src" ] && [ "$src" != "-" ] && srcdesc="$src"

        # validate + normalize the import source into a temp file, so stdin is
        # consumed exactly once and the data can be re-read safely.
        local imptmp="$datafile.imp.$RANDOM"
        local statf="$datafile.stat.$RANDOM"
        local validateprog='
            {
                if( NF==3 && $1!="" && $2 ~ /^[0-9]+([.][0-9]+)?$/ && $3 ~ /^[0-9]+$/ ) {
                    print $1 "|" $2 "|" $3; good++
                } else if( length($0) ) bad++
            }
            END { print (good+0) "|" (bad+0) > st }'

        if [ -n "$src" ] && [ "$src" != "-" ]; then
            if [ ! -f "$src" ] || [ ! -r "$src" ]; then
                echo "z: cannot read import file: $src" >&2
                return 1
            fi
            \awk -F"|" -v st="$statf" "$validateprog" "$src" 2>/dev/null >| "$imptmp"
        else
            \awk -F"|" -v st="$statf" "$validateprog" 2>/dev/null >| "$imptmp"
        fi

        local impgood impbad
        IFS="|" read impgood impbad < "$statf"
        \env rm -f "$statf"
        impgood=${impgood:-0}; impbad=${impbad:-0}

        if [ "$impgood" -eq 0 ]; then
            local why="no valid entries found"
            [ "$impbad" -gt 0 ] && why="$impbad malformed line(s) skipped, none valid"
            echo "z: nothing to import from $srcdesc ($why); datafile unchanged" >&2
            \env rm -f "$imptmp"
            return 0
        fi

        # number of records currently in the datafile (0 if missing); used to
        # split the two concatenated inputs in the merge below (robust even if
        # either side is empty, unlike the FNR==NR idiom).
        local n1=0 cur_in="/dev/null"
        if [ -f "$datafile" ]; then
            n1=$( \awk 'END{ print NR+0 }' "$datafile" 2>/dev/null )
            cur_in="$datafile"
        fi

        local score=${_Z_MAX_SCORE:-9000}
        local mergetmp="$datafile.mrg.$RANDOM"
        \awk -F"|" -v n1="$n1" -v score="$score" '
            {
                if( NR <= n1 ) {
                    # current datafile (skip any malformed lines defensively)
                    if( NF==3 && $1!="" && $2 ~ /^[0-9]+([.][0-9]+)?$/ && $3 ~ /^[0-9]+$/ ) {
                        cr[$1] += $2
                        if( $3 > ct[$1] ) ct[$1] = $3
                        hc[$1] = 1
                    }
                } else {
                    # import file (already validated/normalized)
                    ir[$1] += $2
                    if( $3 > it[$1] ) it[$1] = $3
                    hi[$1] = 1
                }
            }
            END {
                for( p in hc ) all[p] = 1
                for( p in hi ) all[p] = 1
                total = 0
                for( p in all ) {
                    if( hc[p] && hi[p] ) { r = cr[p] + ir[p]; tt = (ct[p] > it[p] ? ct[p] : it[p]); tg = "M" }
                    else if( hi[p] )     { r = ir[p];          tt = it[p];                          tg = "N" }
                    else                 { r = cr[p];          tt = ct[p];                          tg = "U" }
                    rr[p] = r; tm[p] = tt; tag[p] = tg; total += r
                }
                aged = (total > score) ? 1 : 0
                for( p in all )
                    printf "%s|%s|%s|%s\n", tag[p], (aged ? 0.99*rr[p] : rr[p]), tm[p], p
            }
        ' "$cur_in" "$imptmp" 2>/dev/null >| "$mergetmp"
        \env rm -f "$imptmp"

        # sort by path for deterministic output / preview
        \sort -t"|" -k4 "$mergetmp" 2>/dev/null >| "$mergetmp.s" && \
            \env mv -f "$mergetmp.s" "$mergetmp"

        # walk the merged set: classify, check existence, apply prune, build file
        local n_new=0 n_merge=0 n_keep=0 n_missing=0 n_pruned=0 n_total=0
        local finaltmp="$datafile.$RANDOM"
        : >| "$finaltmp"
        local preview="" tg rk tmv pth mark
        while IFS="|" read -r tg rk tmv pth; do
            [ -z "$pth" ] && continue
            mark=""
            if [ ! -d "$pth" ]; then
                n_missing=$((n_missing+1)); mark=" (missing)"
                if [ "$prune" -eq 1 ]; then
                    n_pruned=$((n_pruned+1))
                    preview="$preview
  - $pth (missing, pruned)"
                    continue
                fi
            fi
            printf '%s|%s|%s\n' "$pth" "$rk" "$tmv" >> "$finaltmp"
            n_total=$((n_total+1))
            case "$tg" in
                N) n_new=$((n_new+1));   preview="$preview
  + $pth$mark";;
                M) n_merge=$((n_merge+1)); preview="$preview
  ~ $pth$mark";;
                U) n_keep=$((n_keep+1)); [ -n "$mark" ] && preview="$preview
  !$pth$mark";;
            esac
        done < "$mergetmp"
        \env rm -f "$mergetmp"
        preview="${preview#
}"

        # write (unless this is a dry run)
        local backupnote=""
        if [ "$dry" -eq 0 ]; then
            if [ -s "$datafile" ]; then
                \env cp -f "$datafile" "$datafile.bak" 2>/dev/null && \
                    backupnote="  backup : previous data saved to $datafile.bak"
            fi
            [ "$_Z_OWNER" ] && chown "$_Z_OWNER":"$(id -ng "$_Z_OWNER")" "$finaltmp" 2>/dev/null
            if ! \env mv -f "$finaltmp" "$datafile"; then
                \env rm -f "$finaltmp"
                echo "z: import failed: could not write $datafile" >&2
                return 1
            fi
        else
            \env rm -f "$finaltmp"
        fi

        # report (to stderr, so it never pollutes piped output)
        local malf="" verb="written"
        [ "$impbad" -gt 0 ] && malf=", $impbad malformed skipped"
        [ "$dry" -eq 1 ] && verb="would be written"
        {
            if [ "$dry" -eq 1 ]; then
                echo "z: import preview of $srcdesc - no changes written (dry run)"
            else
                echo "z: imported $srcdesc"
            fi
            echo "  source  : $impgood valid entr$( [ "$impgood" -eq 1 ] && echo y || echo ies )$malf"
            echo "  target  : $datafile ($n1 entr$( [ "$n1" -eq 1 ] && echo y || echo ies ) before)"
            echo "  + new   : $n_new"
            echo "  ~ merged: $n_merge (rank summed, newest time kept)"
            echo "  = kept  : $n_keep"
            if [ "$prune" -eq 1 ]; then
                echo "  - pruned: $n_pruned (missing directories dropped)"
            else
                echo "  ! missing: $n_missing (directory absent here; pass --prune to drop)"
            fi
            echo "  = total : $n_total entr$( [ "$n_total" -eq 1 ] && echo y || echo ies ) $verb"
            [ -n "$backupnote" ] && echo "$backupnote"
            [ -n "$preview" ] && { echo "  ---"; echo "$preview"; }
        } >&2
        return 0

    else
        # list/go
        local echo fnd last list opt typ
        while [ "$1" ]; do case "$1" in
            --) while [ "$1" ]; do shift; fnd="$fnd${fnd:+ }$1";done;;
            -*) opt=${1:1}; while [ "$opt" ]; do case ${opt:0:1} in
                    c) fnd="^$PWD $fnd";;
                    e) echo=1;;
                    h) {
                        echo "${_Z_CMD:-z} [-cehlrtx] args     jump to a frecent dir matching args"
                        echo "${_Z_CMD:-z} --export [file]      print the datafile for backup (no file = stdout)"
                        echo "${_Z_CMD:-z} --import [opts] [file]  merge a datafile (or stdin) into yours"
                        echo "      -n, --dry-run   preview the merge, write nothing"
                        echo "      -p, --prune     drop entries whose directory no longer exists"
                       } >&2; return;;
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
