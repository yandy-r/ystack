# bash completion for ycc (install.sh) — install: ycc completion --shell bash --install

# _ycc_list [<kind>] — 'ycc list' output (the selectable kinds, or a kind's
# names for the --target on the line), space-separated. Reads _ycc_words /
# _ycc_cword from _ycc.
_ycc_list() {
    local i targets="all"
    for ((i = 1; i < _ycc_cword; i++)); do
        [[ "${_ycc_words[i]}" == "--target" ]] && targets="${_ycc_words[i+1]}"
    done
    if [[ $# -eq 0 ]]; then
        "${_ycc_words[0]}" list 2>/dev/null | tr '\n' ' '
    else
        "${_ycc_words[0]}" list "$1" --target "${targets}" 2>/dev/null | tr '\n' ' '
    fi
}

# _ycc_join_words — COMP_WORDS/COMP_CWORD as _ycc_words/_ycc_cword with the
# '@' splits undone: the default COMP_WORDBREAKS breaks 'name@mkt' (plugin
# names, scoped npm packages) into 'name' '@' 'mkt'. A word is glued back to
# the previous one when no whitespace separates them in COMP_LINE and either
# side of the join is '@'. Without COMP_LINE the words are taken as given.
_ycc_join_words() {
    _ycc_words=() _ycc_cword=0
    if [[ -z "${COMP_LINE:-}" ]]; then
        _ycc_words=("${COMP_WORDS[@]}")
        _ycc_cword=${COMP_CWORD}
        return
    fi
    local line="${COMP_LINE:0:${COMP_POINT:-${#COMP_LINE}}}" rest trimmed word
    local i pos=0 gap n
    for ((i = 0; i <= COMP_CWORD; i++)); do
        word="${COMP_WORDS[i]}"
        rest="${line:pos}"
        trimmed="${rest#"${rest%%[![:space:]]*}"}"
        gap=$((${#rest} - ${#trimmed}))
        pos=$((pos + gap + ${#word}))
        n=${#_ycc_words[@]}
        if ((n > 0 && gap == 0)) && [[ "${word}" == @* || "${_ycc_words[n-1]}" == *@ ]]; then
            _ycc_words[n-1]+="${word}"
        else
            _ycc_words+=("${word}")
        fi
    done
    _ycc_cword=$((${#_ycc_words[@]} - 1))
}

_ycc() {
    local -a _ycc_words=()
    local _ycc_cword=0
    _ycc_join_words
    local cur="${_ycc_words[_ycc_cword]}" prev="${_ycc_words[_ycc_cword-1]:-}"
    # Readline replaces COMP_WORDS[COMP_CWORD] plus a '@' right before it ('@'
    # is one of bash's special prefixes); replies drop the rest of the joined head.
    local joined_head="${cur%"${COMP_WORDS[COMP_CWORD]}"}"
    joined_head="${joined_head%@}"
    local sub="" values="" kinds="" kind
    [[ ${_ycc_cword} -gt 1 ]] && sub="${_ycc_words[1]}"
    [[ "${sub}" =~ ^(install|sync|remove|list)$ ]] && kinds="$(_ycc_list)"

    case "${prev}" in
        --target) values="claude cursor codex opencode agents omp all" ;;
        --skills-home) mapfile -t COMPREPLY < <(compgen -W "agents native" -- "${cur}"); return ;;
        --intent) values="base skills agents commands settings rules mcp hooks plugins mods" ;;
        --package) [[ "${sub}" == "install" ]] && values="ycc ycc-mcp ycc-hooks ycc-rules ycc-all" ;;
        --only)   values="base dedupe skills agents commands settings rules mcp hooks mods" ;;
        --mode)   mapfile -t COMPREPLY < <(compgen -W "local repo" -- "${cur}"); return ;;
        --shell)  mapfile -t COMPREPLY < <(compgen -W "bash zsh fish" -- "${cur}"); return ;;
        --dir) mapfile -t COMPREPLY < <(compgen -d -- "${cur}"); return ;;
        --*)
            # --<kind> selectors: names from 'ycc list <kind>'.
            kind="${prev#--}"
            [[ "${sub}" != list && " ${kinds} " == *" ${kind} "* ]] && values="$(_ycc_list "${kind}")"
            ;;
    esac

    # Comma lists: complete the item after the last comma, keep the prefix.
    if [[ -n "${values}" ]]; then
        local head="" item="${cur}"
        if [[ "${cur}" == *,* ]]; then
            head="${cur%,*},"
            item="${cur##*,}"
        fi
        mapfile -t COMPREPLY < <(compgen -P "${head}" -W "${values}" -- "${item}")
        [[ -n "${joined_head}" ]] && COMPREPLY=("${COMPREPLY[@]#"${joined_head}"}")
        compopt -o nospace 2>/dev/null
        return
    fi

    local words selectors=""
    for kind in ${kinds}; do
        selectors+=" --${kind}"
    done
    if [[ ${_ycc_cword} -eq 1 ]]; then
        words="install sync remove cli completion list list-mcps"
    else
        case "${sub}" in
            cli)        words="--dir --force --help" ;;
            completion) words="--shell --install --force --help" ;;
            list)       words="--target --help"; [[ ${_ycc_cword} -eq 2 ]] && words+=" ${kinds}" ;;
            list-mcps)  words="--target --help" ;;
            install)    words="--target --package --only --mode --skills-home --settings --rules --mcp --hooks --with-deps --project --global --force --dry-run --help${selectors}" ;;
            sync)       words="--target --intent --mode --skills-home --with-deps --project --global --force --dry-run --help${selectors}" ;;
            remove)     words="--target --only --intent --project --global --force --purge-cache --dry-run --help${selectors}" ;;
            *)          words="" ;;
        esac
    fi
    mapfile -t COMPREPLY < <(compgen -W "${words}" -- "${cur}")
}

complete -F _ycc ycc
