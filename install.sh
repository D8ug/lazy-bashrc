#!/usr/bin/env bash
# Installer for lazy-bashrc.
# Run `source ./install.sh` to install and immediately reload ~/.bashrc in your current shell,
# or `./install.sh` to install in a subshell.

_lazy_install_main() {
    local is_sourced="$1"
    shift

    local script_dir
    script_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local init_file="${script_dir}/init.sh"
    local marker_start="# >>> lazy-bashrc >>>"
    local marker_end="# <<< lazy-bashrc <<<"

    local user_bashrc=""
    local root_bashrc="/root/.bashrc"
    local do_user=1
    local do_root=1
    local uninstall=0

    _lazy_install_usage() {
        cat <<'EOF'
Usage: source ./install.sh [OPTIONS]   (installs and reloads ~/.bashrc in current shell)
   or: ./install.sh [OPTIONS]

Install or uninstall lazy-bashrc in both user and root bashrc files
(so interactive shells and `sudo su` sessions both load lazy-bashrc).

Options:
  --user-only             Only modify the user's bashrc (skip /root/.bashrc)
  --root-only             Only modify /root/.bashrc
  --user-bashrc <path>    Custom path for user bashrc (default: ~/.bashrc)
  --root-bashrc <path>    Custom path for root bashrc (default: /root/.bashrc)
  --uninstall             Remove the lazy-bashrc block from target bashrc files
  -h, --help              Show this help message
EOF
    }

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --user-only)
                do_root=0
                shift
                ;;
            --root-only)
                do_user=0
                shift
                ;;
            --user-bashrc)
                user_bashrc="${2:-}"
                [[ -n "$user_bashrc" ]] || { echo "Missing value for --user-bashrc" >&2; return 2; }
                shift 2
                ;;
            --root-bashrc)
                root_bashrc="${2:-}"
                [[ -n "$root_bashrc" ]] || { echo "Missing value for --root-bashrc" >&2; return 2; }
                shift 2
                ;;
            --uninstall)
                uninstall=1
                shift
                ;;
            -h|--help)
                _lazy_install_usage
                return 0
                ;;
            *)
                echo "Unknown option: $1" >&2
                _lazy_install_usage >&2
                return 2
                ;;
        esac
    done

    if [[ -z "$user_bashrc" ]]; then
        if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" ]]; then
            local invoking_home
            invoking_home="$(getent passwd "$SUDO_USER" | cut -d: -f6 || true)"
            user_bashrc="${invoking_home:-$HOME}/.bashrc"
        else
            user_bashrc="${HOME}/.bashrc"
        fi
    fi

    # Run a command directly if target is writable by current user, else via sudo.
    _lazy_run_as_needed() {
        local target="$1"
        shift
        local check_path="$target"
        [[ -e "$check_path" ]] || check_path="$(dirname "$target")"

        if [[ -w "$check_path" ]]; then
            "$@"
        else
            if ! command -v sudo >/dev/null 2>&1; then
                echo "Cannot write to $target and sudo is unavailable." >&2
                return 1
            fi
            sudo "$@"
        fi
    }

    _lazy_install_to_file() {
        local target="$1"
        local target_dir
        target_dir="$(dirname "$target")"
        _lazy_run_as_needed "$target" mkdir -p "$target_dir" || return 1

        if _lazy_run_as_needed "$target" test -f "$target" && _lazy_run_as_needed "$target" grep -qF "$marker_start" "$target"; then
            echo "Already installed in $target"
            return 0
        fi

        local block
        block="$(cat <<EOF

${marker_start}
if [ -f "${init_file}" ]; then
    . "${init_file}"
fi
${marker_end}
EOF
)"

        if [[ -w "$target" || ( ! -e "$target" && -w "$target_dir" ) ]]; then
            printf '%s\n' "$block" >> "$target"
        else
            printf '%s\n' "$block" | sudo tee -a "$target" >/dev/null
        fi
        echo "Installed lazy-bashrc hook into $target"
    }

    _lazy_uninstall_from_file() {
        local target="$1"
        if ! _lazy_run_as_needed "$target" test -f "$target"; then
            echo "Skipped $target (does not exist)"
            return 0
        fi
        if ! _lazy_run_as_needed "$target" grep -qF "$marker_start" "$target"; then
            echo "Not installed in $target"
            return 0
        fi

        local tmp
        tmp="$(mktemp)"
        if [[ -r "$target" ]]; then
            awk -v start="$marker_start" -v end="$marker_end" '
                $0 == start { skip = 1; next }
                $0 == end   { skip = 0; next }
                !skip       { print }
            ' "$target" > "$tmp"
        else
            sudo awk -v start="$marker_start" -v end="$marker_end" '
                $0 == start { skip = 1; next }
                $0 == end   { skip = 0; next }
                !skip       { print }
            ' "$target" > "$tmp"
        fi

        _lazy_run_as_needed "$target" cp "$tmp" "$target"
        rm -f "$tmp"
        echo "Removed lazy-bashrc hook from $target"
    }

    _lazy_ensure_config_env() {
        local env_file="${script_dir}/config.env"
        local example_file="${script_dir}/config.env.example"
        if [[ ! -f "$env_file" && -f "$example_file" ]]; then
            cp "$example_file" "$env_file"
            chmod 644 "$env_file"
            echo "Created ${env_file} from config.env.example"
        fi
    }

    local -a targets=()
    if (( do_user )); then
        targets+=("$user_bashrc")
    fi
    if (( do_root )) && [[ "$root_bashrc" != "$user_bashrc" || $do_user -eq 0 ]]; then
        targets+=("$root_bashrc")
    fi

    local target
    if (( uninstall )); then
        for target in "${targets[@]}"; do
            _lazy_uninstall_from_file "$target" || return 1
        done
    else
        _lazy_ensure_config_env || return 1
        for target in "${targets[@]}"; do
            _lazy_install_to_file "$target" || return 1
        done

        if (( do_user )) && [[ -f "$user_bashrc" ]]; then
            if (( is_sourced )); then
                # shellcheck source=/dev/null
                source "$user_bashrc"
                echo "Sourced $user_bashrc in current shell"
            else
                echo "Run 'source ${user_bashrc}' (or 'source ./install.sh' next time) to load lazy-bashrc in your current shell."
            fi
        fi
    fi
}

_lazy_install_is_sourced=0
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    _lazy_install_is_sourced=1
else
    set -euo pipefail
fi

_lazy_install_rc=0
_lazy_install_main "$_lazy_install_is_sourced" "$@" || _lazy_install_rc=$?

unset -f _lazy_install_main _lazy_install_usage _lazy_run_as_needed \
    _lazy_install_to_file _lazy_uninstall_from_file _lazy_ensure_config_env 2>/dev/null || true

if (( _lazy_install_is_sourced )); then
    eval "unset _lazy_install_is_sourced _lazy_install_rc; return ${_lazy_install_rc}"
else
    exit "$_lazy_install_rc"
fi
