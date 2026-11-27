#!/usr/bin/env bash
# Update lazy-bashrc (cb -> gcom -> gpl) and reload shell configuration.
# Run `source ./refresh.sh` to keep the directory change and reload ~/.bashrc
# in your current interactive shell.

_lazy_refresh_main() {
    local is_sourced="$1"
    shift

    local script_dir
    script_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local target_rc="${HOME}/.bashrc"
    local quiet=0

    _lazy_refresh_usage() {
        cat <<'EOF'
Usage: refresh                         (lazy-bashrc function: updates repo and reloads ~/.bashrc)
   or: source ./refresh.sh [OPTIONS]   (updates repo and reloads ~/.bashrc in current shell)
   or: ./refresh.sh [OPTIONS]          (updates repo on main in a subshell)

Runs cb -> gcom -> gpl and refreshes lazy-bashrc commands.

Options:
  --rc <path>   Custom bashrc file to source when sourced (default: ~/.bashrc)
  --quiet       Suppress the reload reminder when executed in a subshell
  -h, --help    Show this help message
EOF
    }

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --rc)
                target_rc="${2:-}"
                [[ -n "$target_rc" ]] || { echo "Missing value for --rc" >&2; return 2; }
                shift 2
                ;;
            --quiet)
                quiet=1
                shift
                ;;
            -h|--help)
                _lazy_refresh_usage
                return 0
                ;;
            *)
                echo "Unknown option: $1" >&2
                _lazy_refresh_usage >&2
                return 2
                ;;
        esac
    done

    # Ensure lazy-bashrc runtime & commands are available even if not yet sourced.
    if ! declare -F lazy_run >/dev/null 2>&1 || ! declare -F cb >/dev/null 2>&1 || ! declare -F gcom >/dev/null 2>&1 || ! declare -F gpl >/dev/null 2>&1; then
        # shellcheck source=init.sh
        source "${script_dir}/init.sh" || return 1
    fi

    lazy_run cb || return 1
    lazy_run gcom || return 1
    lazy_run gpl || return 1

    if (( is_sourced )); then
        if [[ -f "$target_rc" ]]; then
            # shellcheck source=/dev/null
            lazy_run source "$target_rc" || return 1
        else
            # shellcheck source=init.sh
            lazy_run source "${script_dir}/init.sh" || return 1
        fi
    else
        (( quiet )) || echo "Run 'source ~/.bashrc' (or use 'refresh' / 'source ./refresh.sh') to reload commands in your current shell."
    fi
}

_lazy_refresh_is_sourced=0
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    _lazy_refresh_is_sourced=1
else
    set -euo pipefail
fi

_lazy_refresh_rc=0
_lazy_refresh_main "$_lazy_refresh_is_sourced" "$@" || _lazy_refresh_rc=$?

unset -f _lazy_refresh_main _lazy_refresh_usage 2>/dev/null || true

if (( _lazy_refresh_is_sourced )); then
    eval "unset _lazy_refresh_is_sourced _lazy_refresh_rc; return ${_lazy_refresh_rc}"
else
    exit "$_lazy_refresh_rc"
fi
