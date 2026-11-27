#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INIT_FILE="${SCRIPT_DIR}/init.sh"
MARKER_START="# >>> lazy-bashrc >>>"
MARKER_END="# <<< lazy-bashrc <<<"

USER_BASHRC=""
ROOT_BASHRC="/root/.bashrc"
DO_USER=1
DO_ROOT=1
UNINSTALL=0

usage() {
    cat <<'EOF'
Usage: ./install.sh [OPTIONS]

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
            DO_ROOT=0
            shift
            ;;
        --root-only)
            DO_USER=0
            shift
            ;;
        --user-bashrc)
            USER_BASHRC="${2:-}"
            [[ -n "$USER_BASHRC" ]] || { echo "Missing value for --user-bashrc" >&2; exit 2; }
            shift 2
            ;;
        --root-bashrc)
            ROOT_BASHRC="${2:-}"
            [[ -n "$ROOT_BASHRC" ]] || { echo "Missing value for --root-bashrc" >&2; exit 2; }
            shift 2
            ;;
        --uninstall)
            UNINSTALL=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [[ -z "$USER_BASHRC" ]]; then
    if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" ]]; then
        invoking_home="$(getent passwd "$SUDO_USER" | cut -d: -f6 || true)"
        USER_BASHRC="${invoking_home:-$HOME}/.bashrc"
    else
        USER_BASHRC="${HOME}/.bashrc"
    fi
fi

# Run a command directly if target is writable by current user, else via sudo.
run_as_needed() {
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

install_to_file() {
    local target="$1"
    local target_dir
    target_dir="$(dirname "$target")"
    run_as_needed "$target" mkdir -p "$target_dir"

    if run_as_needed "$target" test -f "$target" && run_as_needed "$target" grep -qF "$MARKER_START" "$target"; then
        echo "Already installed in $target"
        return 0
    fi

    local block
    block="$(cat <<EOF

${MARKER_START}
if [ -f "${INIT_FILE}" ]; then
    . "${INIT_FILE}"
fi
${MARKER_END}
EOF
)"

    if [[ -w "$target" || ( ! -e "$target" && -w "$target_dir" ) ]]; then
        printf '%s\n' "$block" >> "$target"
    else
        printf '%s\n' "$block" | sudo tee -a "$target" >/dev/null
    fi
    echo "Installed lazy-bashrc hook into $target"
}

uninstall_from_file() {
    local target="$1"
    if ! run_as_needed "$target" test -f "$target"; then
        echo "Skipped $target (does not exist)"
        return 0
    fi
    if ! run_as_needed "$target" grep -qF "$MARKER_START" "$target"; then
        echo "Not installed in $target"
        return 0
    fi

    local tmp
    tmp="$(mktemp)"
    if [[ -r "$target" ]]; then
        awk -v start="$MARKER_START" -v end="$MARKER_END" '
            $0 == start { skip = 1; next }
            $0 == end   { skip = 0; next }
            !skip       { print }
        ' "$target" > "$tmp"
    else
        sudo awk -v start="$MARKER_START" -v end="$MARKER_END" '
            $0 == start { skip = 1; next }
            $0 == end   { skip = 0; next }
            !skip       { print }
        ' "$target" > "$tmp"
    fi

    run_as_needed "$target" cp "$tmp" "$target"
    rm -f "$tmp"
    echo "Removed lazy-bashrc hook from $target"
}

ensure_config_env() {
    local env_file="${SCRIPT_DIR}/config.env"
    local example_file="${SCRIPT_DIR}/config.env.example"
    if [[ ! -f "$env_file" && -f "$example_file" ]]; then
        cp "$example_file" "$env_file"
        chmod 644 "$env_file"
        echo "Created ${env_file} from config.env.example"
    fi
}

declare -a targets=()
if (( DO_USER )); then
    targets+=("$USER_BASHRC")
fi
if (( DO_ROOT )) && [[ "$ROOT_BASHRC" != "$USER_BASHRC" || $DO_USER -eq 0 ]]; then
    targets+=("$ROOT_BASHRC")
fi

if (( UNINSTALL )); then
    for target in "${targets[@]}"; do
        uninstall_from_file "$target"
    done
else
    ensure_config_env
    for target in "${targets[@]}"; do
        install_to_file "$target"
    done
fi
