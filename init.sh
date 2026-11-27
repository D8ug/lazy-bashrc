#!/usr/bin/env bash
# Entry point for lazy-bashrc. Source this file from ~/.bashrc and /root/.bashrc.

_lazy_resolve_dir() {
    local src="${BASH_SOURCE[0]}"
    while [[ -L "$src" ]]; do
        local dir
        dir="$(cd -P "$(dirname "$src")" && pwd)"
        src="$(readlink "$src")"
        [[ "$src" != /* ]] && src="$dir/$src"
    done
    cd -P "$(dirname "$src")" && pwd
}

LAZY_BASHRC_DIR="$(_lazy_resolve_dir)"
unset -f _lazy_resolve_dir
export LAZY_BASHRC_DIR

# Load defaults first, then repo config.env (or .env), then optional XDG override.
if [[ -f "${LAZY_BASHRC_DIR}/config.env.example" ]]; then
    # shellcheck source=config.env.example
    source "${LAZY_BASHRC_DIR}/config.env.example"
fi
if [[ -f "${LAZY_BASHRC_DIR}/config.env" ]]; then
    # shellcheck source=config.env
    source "${LAZY_BASHRC_DIR}/config.env"
elif [[ -f "${LAZY_BASHRC_DIR}/.env" ]]; then
    source "${LAZY_BASHRC_DIR}/.env"
fi
if [[ -f "${XDG_CONFIG_HOME:-$HOME/.config}/lazy-bashrc/config.env" ]]; then
    source "${XDG_CONFIG_HOME:-$HOME/.config}/lazy-bashrc/config.env"
fi

# Load core runtime.
# shellcheck source=lib/core.sh
source "${LAZY_BASHRC_DIR}/lib/core.sh"

# Source matching files (*.sh by default, or custom extensions) inside a directory.
_lazy_source_dir() {
    local dir="$1"
    shift
    [[ -d "$dir" ]] || return 0

    local -a exts=("$@")
    (( ${#exts[@]} > 0 )) || exts=("sh")

    local had_nullglob=0
    shopt -q nullglob && had_nullglob=1
    shopt -s nullglob

    local ext file
    for ext in "${exts[@]}"; do
        for file in "$dir"/*."$ext"; do
            if [[ -f "$file" && -r "$file" ]]; then
                # shellcheck source=/dev/null
                source "$file"
            elif [[ -L "$file" ]]; then
                printf 'lazy-bashrc: skipping broken or unreadable link: %s\n' "$file" >&2
            fi
        done
    done

    (( had_nullglob )) || shopt -u nullglob
}

_lazy_source_dir "${LAZY_BASHRC_DIR}/aliases" sh
_lazy_source_dir "${LAZY_BASHRC_DIR}/functions" sh
_lazy_source_dir "${LAZY_PROJECTS_DIR:-${LAZY_BASHRC_DIR}/projects}" bashrc sh bash
_lazy_source_dir "${LAZY_BASHRC_DIR}/local" sh
unset -f _lazy_source_dir
