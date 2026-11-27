#!/usr/bin/env bash
# Core runtime for lazy-bashrc:
#   - Blue command tracing to stderr with nested indentation
#   - Composable aliases & functions via lazy_alias / lazy_register / lazy_run
#   - Dry-run wrapper via `dr <command>`

# Reset registry on source so reloading ~/.bashrc stays clean and idempotent.
declare -gA _LAZY_FUNCTIONS=()
: "${_LAZY_DEPTH:=0}"
: "${LAZY_DRY_RUN:=0}"

# Validate a shell function/alias name.
_lazy_valid_name() {
    local name="$1"
    [[ "$name" =~ ^[a-zA-Z_][a-zA-Z0-9_-]*$ ]]
}

# Return 0 if ANSI color should be emitted on stderr, 1 otherwise.
_lazy_use_color() {
    [[ -n "${NO_COLOR:-}" ]] && return 1
    case "${LAZY_COLOR:-auto}" in
        never)  return 1 ;;
        always) return 0 ;;
        *)      [[ -t 2 ]] ;;
    esac
}

# Format command + arguments into a single readable, shell-safe line.
_lazy_format_cmd() {
    local out="" arg q
    for arg in "$@"; do
        if [[ -n "$arg" && "$arg" =~ ^[a-zA-Z0-9_./:=,@+-]+$ ]]; then
            q="$arg"
        else
            printf -v q '%q' "$arg"
        fi
        if [[ -z "$out" ]]; then
            out="$q"
        else
            out+=" $q"
        fi
    done
    printf '%s' "$out"
}

# Print the command to stderr in blue, indented according to _LAZY_DEPTH.
_lazy_print_cmd() {
    local depth="${_LAZY_DEPTH:-0}"
    local indent_unit="${LAZY_INDENT-  }"
    local indent=""
    local i
    for (( i = 0; i < depth; i++ )); do
        indent+="$indent_unit"
    done

    local prefix="${LAZY_TRACE_PREFIX:-}"
    local formatted
    formatted="$(_lazy_format_cmd "$@")"
    local line="${indent}${prefix}${formatted}"

    if _lazy_use_color; then
        local color="${LAZY_COLOR_CODE:-$'\033[1;34m'}"
        local reset=$'\033[0m'
        printf '%s%s%s\n' "$color" "$line" "$reset" >&2
    else
        printf '%s\n' "$line" >&2
    fi
}

# Register one or more custom functions so `lazy_run` and `dr` trace into them.
lazy_register() {
    local fn
    for fn in "$@"; do
        if ! _lazy_valid_name "$fn"; then
            printf 'lazy-bashrc: invalid function name: %s\n' "$fn" >&2
            return 1
        fi
        _LAZY_FUNCTIONS["$fn"]=1
    done
}

# Print a command in blue and execute it in the current shell.
# Registered lazy-bashrc functions are stepped into even during dry-run (`dr`)
# so full nested traces are printed without running leaf system commands.
lazy_run() {
    [[ $# -eq 0 ]] && return 0
    _lazy_print_cmd "$@"

    if [[ -n "${_LAZY_FUNCTIONS[$1]:-}" ]]; then
        local _prev_depth="${_LAZY_DEPTH:-0}"
        _LAZY_DEPTH=$(( _prev_depth + 1 ))
        local rc=0
        "$@" || rc=$?
        _LAZY_DEPTH="$_prev_depth"
        return "$rc"
    fi

    if [[ "${LAZY_DRY_RUN:-0}" == "1" ]]; then
        return 0
    fi

    "$@"
}

# Define a composable lazy alias backed by a registered Bash function.
# Usage:
#   lazy_alias sai sudo apt install
#   lazy_alias sai "sudo apt install"
lazy_alias() {
    if [[ $# -lt 2 ]]; then
        printf 'Usage: lazy_alias <name> <command...>\n' >&2
        return 2
    fi

    local name="$1"
    shift

    if ! _lazy_valid_name "$name"; then
        printf 'lazy-bashrc: invalid alias name: %s\n' "$name" >&2
        return 1
    fi

    local -a base_cmd=()
    if [[ $# -eq 1 && "$1" == *[[:space:]]* ]]; then
        read -ra base_cmd <<< "$1"
    else
        base_cmd=("$@")
    fi

    local quoted_cmd="" tok
    for tok in "${base_cmd[@]}"; do
        printf -v tok '%q' "$tok"
        quoted_cmd+="${tok} "
    done

    # Remove any pre-existing shell alias so Bash parses the function definition cleanly.
    unalias "$name" 2>/dev/null || true
    eval "${name}() { lazy_run ${quoted_cmd}\"\$@\"; }"
    lazy_register "$name"
}

# Dry-run wrapper: prints the commands that would execute without running them.
# Usage: dr <command> [args...]
dr() {
    if [[ $# -eq 0 ]]; then
        printf 'Usage: dr <command> [args...]\n' >&2
        return 2
    fi

    local _prev_dry="${LAZY_DRY_RUN:-0}"
    LAZY_DRY_RUN=1
    local rc=0

    if [[ -n "${_LAZY_FUNCTIONS[$1]:-}" ]]; then
        "$@" || rc=$?
    else
        _lazy_print_cmd "$@"
    fi

    LAZY_DRY_RUN="$_prev_dry"
    return "$rc"
}
