# shellcheck shell=bash
# args.sh — parse install.sh's arguments and set the installer globals.
# Sourced after the other installer libraries so their helpers are available.

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
TARGET=""
TARGETS=()
MODE="local"
MODE_SET=0
COMMAND=""
MCP=0
SETTINGS=0
RULES=0
HOOKS=0
FORCE=0
# Read by targets/opencode-catalog.sh (remove only).
PURGE_CACHE=0
# Read by select.sh (expand_with_deps; install/sync only).
WITH_DEPS=0
EXCLUSIVE_STEPS=0
ONLY_STEPS=()
INTENTS=()
PACKAGE=""
PACKAGE_CONFLICT_FLAG=0
SCOPE=""
# Read by core.sh (merge helper), steps.sh (skip_dry_run_steps) and targets/omp.sh.
export DRY_RUN=0

case "${1:-}" in
    cli|completion|list)
        for arg in "$@"; do
            if [[ "${arg}" == "--package" || "${arg}" == --package=* ]]; then
                err "--package is only supported by the 'install' subcommand"
                exit 1
            fi
        done
        case "$1" in
            cli)        shift; run_cli_command "$@"; exit 0 ;;
            completion) shift; run_completion_command "$@"; exit 0 ;;
            list)       shift; run_list_command "$@"; exit 0 ;;
        esac
        ;;
esac

case "${1:-}" in
    install|sync|remove) COMMAND="$1"; shift ;;
    --help|-h) usage; exit 0 ;;
    "") usage; exit 1 ;;
    migrate)
        err "'migrate' was removed in v6.3.0: install and sync now install the native packages and retire legacy installer state themselves"
        shift
        err "  e.g. $(basename "$0") install $*"
        exit 1
        ;;
    *)
        err "missing or unknown command '$1' (expected: install, sync, remove, cli, completion, list)"
        err "  e.g. $(basename "$0") install $*"
        exit 1
        ;;
esac

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)
            [[ $# -lt 2 ]] && { err "--target requires an argument"; exit 1; }
            TARGET="$2"
            shift 2
            ;;
        --mode)
            [[ $# -lt 2 ]] && { err "--mode requires an argument (local|repo)"; exit 1; }
            MODE="$2"
            MODE_SET=1
            if [[ ! "$MODE" =~ ^(local|repo)$ ]]; then
                err "Invalid --mode: ${MODE} (supported: local, repo)"
                exit 1
            fi
            shift 2
            ;;
        --package)
            if [[ "${COMMAND}" != "install" ]]; then
                err "--package is only supported by the 'install' subcommand"
                exit 1
            fi
            [[ $# -lt 2 ]] && { err "--package requires an argument (a comma-separated list of package ids)"; exit 1; }
            [[ "$2" == --* ]] && { err "--package requires an argument (a comma-separated list of package ids)"; exit 1; }
            [[ -n "$2" ]] || { err "--package contains an empty value"; exit 1; }
            PACKAGE="$2"
            shift 2
            ;;
        --only)
            PACKAGE_CONFLICT_FLAG=1
            [[ $# -lt 2 ]] && { err "--only requires a comma-separated list of steps"; exit 1; }
            IFS=',' read -r -a ONLY_STEPS <<< "$2"
            if [[ ${#ONLY_STEPS[@]} -eq 0 ]]; then
                err "--only requires at least one step"
                exit 1
            fi
            shift 2
            ;;
        --intent)
            PACKAGE_CONFLICT_FLAG=1
            [[ $# -lt 2 ]] && { err "--intent requires a comma-separated list of intents"; exit 1; }
            IFS=',' read -r -a INTENTS <<< "$2"
            shift 2
            ;;
        --mcp)      MCP=1; shift ;;
        --settings) SETTINGS=1; shift ;;
        --rules)    RULES=1; shift ;;
        --hooks)
            # install only: boolean "also run the hooks step" (sync/remove use --intent hooks).
            if [[ "${COMMAND}" != "install" ]]; then
                err "--hooks is install's step flag; ${COMMAND} takes --intent hooks"
                exit 1
            fi
            HOOKS=1
            shift
            ;;
        --dry-run)  DRY_RUN=1; shift ;;
        --purge-cache) PURGE_CACHE=1; shift ;;
        --with-deps) WITH_DEPS=1; shift ;;
        --project|--global)
            if [[ -n "${SCOPE}" && "${SCOPE}" != "${1#--}" ]]; then
                err "--project and --global are mutually exclusive"
                exit 1
            fi
            SCOPE="${1#--}"
            shift
            ;;
        --force)
            # shellcheck disable=SC2034  # read by core.sh, cli.sh, and bundle.sh
            FORCE=1
            shift
            ;;
        --help|-h)  usage; exit 0 ;;
        --*)
            # --<kind> <names>: item selection for any kind in select.sh.
            if is_selectable_kind "${1#--}"; then
                [[ $# -lt 2 ]] && { err "$1 requires a comma-separated list of ${SELECTION_NOUNS[${1#--}]}"; exit 1; }
                parse_selection "${1#--}" "$2"
                shift 2
                continue
            fi
            ;&
        *)
            err "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

if [[ -z "${TARGET}" ]]; then
    err "Missing required --target flag"
    usage
    exit 1
fi

if [[ "${COMMAND}" == "remove" ]]; then
    # remove never guesses: say exactly what to remove.
    if [[ "${SETTINGS}" == "1" || "${RULES}" == "1" || "${MCP}" == "1" ]]; then
        err "remove does not accept --settings, --rules, or --mcp (use --only or --intent)"
        exit 1
    fi
    if [[ "${MODE_SET}" == "1" ]]; then
        err "remove does not accept --mode (it undoes local and repo installs alike)"
        exit 1
    fi
    if [[ ${#ONLY_STEPS[@]} -eq 0 && ${#INTENTS[@]} -eq 0 ]]; then
        err "remove requires --only <steps> or --intent <intents>"
        exit 1
    fi
elif [[ "${PURGE_CACHE}" == "1" ]]; then
    err "--purge-cache is only valid with 'remove'"
    exit 1
fi

if [[ "${WITH_DEPS}" == "1" ]]; then
    if [[ "${COMMAND}" == "remove" ]]; then
        err "--with-deps is only valid with install or sync"
        exit 1
    fi
    if ! has_selection skills; then
        err "--with-deps needs --skills"
        exit 1
    fi
fi

if [[ -n "${PACKAGE}" ]]; then
    if [[ "${COMMAND}" != "install" ]]; then
        err "--package is only supported by the 'install' subcommand"
        exit 1
    fi
    if [[ "${PACKAGE_CONFLICT_FLAG}" == 1 || "${SETTINGS}" == "1" || "${RULES}" == "1" || "${MCP}" == "1" || "${HOOKS}" == "1" ]]; then
        err "--package cannot be combined with --intent, --only, --settings, --rules, --mcp, or --hooks"
        exit 1
    fi
fi

if [[ ${#INTENTS[@]} -gt 0 && "${COMMAND}" != "install" ]]; then
    if [[ ${#ONLY_STEPS[@]} -gt 0 || "${SETTINGS}" == "1" || "${RULES}" == "1" || "${MCP}" == "1" ]]; then
        err "${COMMAND} --intent cannot be combined with --only, --settings, --rules, or --mcp"
        exit 1
    fi

    declare -A seen_intents=()
    unique_intents=()
    for intent in "${INTENTS[@]}"; do
        if [[ -z "${intent}" ]]; then
            err "--intent contains an empty value"
            exit 1
        fi
        intent_valid=0
        for allowed in "${VALID_INTENTS[@]}"; do
            [[ "${intent}" == "${allowed}" ]] && intent_valid=1 && break
        done
        if [[ ${intent_valid} -eq 0 ]]; then
            err "unknown intent '${intent}' (valid: ${VALID_INTENTS[*]})"
            exit 1
        fi
        if [[ -z "${seen_intents[${intent}]:-}" ]]; then
            unique_intents+=("${intent}")
            seen_intents["${intent}"]=1
        fi
    done
    INTENTS=("${unique_intents[@]}")
elif [[ "${COMMAND}" == "sync" ]]; then
    err "sync requires --intent <intent,...>"
    exit 1
elif [[ ${#INTENTS[@]} -gt 0 ]]; then
    err "--intent requires the 'sync' or 'remove' subcommand"
    exit 1
fi

if [[ ${#ONLY_STEPS[@]} -gt 0 ]]; then
    # shellcheck disable=SC2034  # read by steps.sh (step_enabled).
    EXCLUSIVE_STEPS=1
    if [[ "${SETTINGS}" == "1" ]]; then
        warn "--settings is ignored when --only is used"
    fi
    if [[ "${RULES}" == "1" ]]; then
        warn "--rules is ignored when --only is used"
    fi
    if [[ "${MCP}" == "1" ]]; then
        warn "--mcp is ignored when --only is used"
    fi
    if [[ "${HOOKS}" == "1" ]]; then
        warn "--hooks is ignored when --only is used"
    fi
fi
