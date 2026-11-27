# Refresh helper function: runs refresh.sh and reloads ~/.bashrc in the current shell.

refresh() {
    local rc="${1:-${HOME}/.bashrc}"
    lazy_run "${LAZY_BASHRC_DIR}/refresh.sh" --quiet || return 1
    if [[ -f "$rc" ]]; then
        # shellcheck source=/dev/null
        lazy_run source "$rc"
    else
        # shellcheck source=../init.sh
        lazy_run source "${LAZY_BASHRC_DIR}/init.sh"
    fi
}
lazy_register refresh
