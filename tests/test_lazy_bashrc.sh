#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

PASS_COUNT=0
FAIL_COUNT=0

assert_eq() {
    local expected="$1"
    local actual="$2"
    local label="$3"
    if [[ "$expected" == "$actual" ]]; then
        PASS_COUNT=$(( PASS_COUNT + 1 ))
    else
        FAIL_COUNT=$(( FAIL_COUNT + 1 ))
        printf 'FAIL [%s]:\n  expected: %q\n  actual:   %q\n' "$label" "$expected" "$actual" >&2
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local label="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        PASS_COUNT=$(( PASS_COUNT + 1 ))
    else
        FAIL_COUNT=$(( FAIL_COUNT + 1 ))
        printf 'FAIL [%s]: expected to contain %q, got:\n%s\n' "$label" "$needle" "$haystack" >&2
    fi
}

assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local label="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        PASS_COUNT=$(( PASS_COUNT + 1 ))
    else
        FAIL_COUNT=$(( FAIL_COUNT + 1 ))
        printf 'FAIL [%s]: expected NOT to contain %q, got:\n%s\n' "$label" "$needle" "$haystack" >&2
    fi
}

# Create mock binaries in TMP_DIR/bin to verify commands are called or skipped.
mkdir -p "${TMP_DIR}/bin"
MOCK_LOG="${TMP_DIR}/mock_calls.log"

cat > "${TMP_DIR}/bin/sudo" <<EOF
#!/usr/bin/env bash
printf 'sudo %s\n' "\$*" >> "${MOCK_LOG}"
printf 'MOCK_SUDO_OUT:%s\n' "\$*"
EOF

cat > "${TMP_DIR}/bin/git" <<EOF
#!/usr/bin/env bash
printf 'git %s\n' "\$*" >> "${MOCK_LOG}"
printf 'MOCK_GIT_OUT:%s\n' "\$*"
EOF

chmod +x "${TMP_DIR}/bin/sudo" "${TMP_DIR}/bin/git"

# 1. Syntax check all shell files
bash -n \
    "${REPO_DIR}/init.sh" \
    "${REPO_DIR}/install.sh" \
    "${REPO_DIR}/lib/core.sh" \
    "${REPO_DIR}/aliases/apt.sh" \
    "${REPO_DIR}/aliases/git.sh" \
    "${REPO_DIR}/functions/examples.sh" \
    "${REPO_DIR}/tests/test_lazy_bashrc.sh"
PASS_COUNT=$(( PASS_COUNT + 1 ))

# 2. Test baseline loading, nullglob preservation, and pre-existing alias override
out="$(
    bash -c "
        shopt -u nullglob
        alias sai='echo old_alias'
        source '${REPO_DIR}/init.sh'
        shopt -q nullglob && echo 'NULLGLOB_LEAK' || echo 'NULLGLOB_OK'
        declare -F sai >/dev/null && echo 'SAI_FN_OK'
        declare -F gco >/dev/null && echo 'GCO_FN_OK'
        declare -F dr  >/dev/null && echo 'DR_FN_OK'
        echo \"WORK=\${LAZY_WORK_DIR}\"
    "
)"
assert_contains "$out" "NULLGLOB_OK" "nullglob restored after init.sh"
assert_contains "$out" "SAI_FN_OK" "sai function defined"
assert_contains "$out" "GCO_FN_OK" "gco function defined"
assert_contains "$out" "DR_FN_OK" "dr function defined"
assert_contains "$out" "WORK=/opt/git" "LAZY_WORK_DIR default loaded"

# 3. Test live execution of sai & gco: stdout vs stderr trace & mock execution
: > "$MOCK_LOG"
stdout_file="${TMP_DIR}/stdout.txt"
stderr_file="${TMP_DIR}/stderr.txt"
PATH="${TMP_DIR}/bin:${PATH}" bash -c "
    source '${REPO_DIR}/init.sh'
    LAZY_COLOR=never
    sai vim htop
    gco -b 'feat/hello world'
" >"$stdout_file" 2>"$stderr_file"

assert_eq $'MOCK_SUDO_OUT:apt install -y vim htop\nMOCK_GIT_OUT:checkout -b feat/hello world' "$(cat "$stdout_file")" "sai and gco stdout clean"
assert_eq $'sudo apt install -y vim htop\ngit checkout -b feat/hello\\ world' "$(cat "$stderr_file")" "sai and gco stderr trace"
assert_eq $'sudo apt install -y vim htop\ngit checkout -b feat/hello world' "$(cat "$MOCK_LOG")" "mocks invoked in live mode"

# 4. Test ANSI blue color output & NO_COLOR behavior
color_err="${TMP_DIR}/color_err.txt"
PATH="${TMP_DIR}/bin:${PATH}" bash -c "
    source '${REPO_DIR}/init.sh'
    LAZY_COLOR=always
    dr sai vim
" >/dev/null 2>"$color_err"
assert_eq $'\033[1;34msudo apt install -y vim\033[0m' "$(cat "$color_err")" "blue ANSI escape emitted when LAZY_COLOR=always"

no_color_err="${TMP_DIR}/no_color_err.txt"
PATH="${TMP_DIR}/bin:${PATH}" bash -c "
    source '${REPO_DIR}/init.sh'
    LAZY_COLOR=always
    NO_COLOR=1
    dr sai vim
" >/dev/null 2>"$no_color_err"
assert_eq "sudo apt install -y vim" "$(cat "$no_color_err")" "NO_COLOR suppresses ANSI escapes"

# 5. Test dr (dry-run) does NOT execute mocks or raw commands and does not leak state
: > "$MOCK_LOG"
dr_out="${TMP_DIR}/dr_out.txt"
dr_err="${TMP_DIR}/dr_err.txt"
PATH="${TMP_DIR}/bin:${PATH}" bash -c "
    source '${REPO_DIR}/init.sh'
    LAZY_COLOR=never
    dr sai curl
    dr gco main
    dr echo should-not-print
    echo \"DRY_STATE=\${LAZY_DRY_RUN}\"
" >"$dr_out" 2>"$dr_err"

assert_eq "DRY_STATE=0" "$(cat "$dr_out")" "dr produces no command stdout and restores LAZY_DRY_RUN"
assert_eq $'sudo apt install -y curl\ngit checkout main\necho should-not-print' "$(cat "$dr_err")" "dr prints traced commands to stderr"
assert_eq "" "$(cat "$MOCK_LOG")" "dr does not execute underlying commands"

# 6. Test composite functions (cd-work -> cb) and alias-on-alias (gcob -> gco) with indentation & cd in current shell
: > "$MOCK_LOG"
comp_out="${TMP_DIR}/comp_out.txt"
comp_err="${TMP_DIR}/comp_err.txt"
PATH="${TMP_DIR}/bin:${PATH}" bash -c "
    source '${REPO_DIR}/init.sh'
    LAZY_COLOR=never
    LAZY_WORK_DIR='${TMP_DIR}/work'
    mkdir -p '${TMP_DIR}/work/lazy-bashrc'

    cd-work() {
        lazy_run cd \"\${LAZY_WORK_DIR}/\${1:-}\"
    }
    lazy_register cd-work

    cb() {
        lazy_run cd-work lazy-bashrc
    }
    lazy_register cb

    lazy_alias gcob gco -b

    cd '${TMP_DIR}'
    dr cb
    echo \"PWD_AFTER_DR=\${PWD}\"
    cb
    echo \"PWD_AFTER_CB=\${PWD}\"
    dr gcob topic-1
" >"$comp_out" 2>"$comp_err"

assert_eq "PWD_AFTER_DR=${TMP_DIR}"$'\n'"PWD_AFTER_CB=${TMP_DIR}/work/lazy-bashrc" "$(cat "$comp_out")" "dr cb preserves PWD while live cb changes PWD"
expected_comp_err=$'cd-work lazy-bashrc\n  cd '"${TMP_DIR}"$'/work/lazy-bashrc\ncd-work lazy-bashrc\n  cd '"${TMP_DIR}"$'/work/lazy-bashrc\ngco -b topic-1\n  git checkout -b topic-1'
assert_eq "$expected_comp_err" "$(cat "$comp_err")" "nested indentation trace for composite functions and aliases"
assert_eq "" "$(cat "$MOCK_LOG")" "dr gcob does not execute git"

# 7. Test install.sh and --uninstall in an isolated copy
inst_repo="${TMP_DIR}/repo"
mkdir -p "$inst_repo"
cp "${REPO_DIR}/install.sh" "${REPO_DIR}/init.sh" "${REPO_DIR}/config.env.example" "$inst_repo/"
cp -r "${REPO_DIR}/lib" "${REPO_DIR}/aliases" "$inst_repo/"
chmod +x "${inst_repo}/install.sh"

user_rc="${TMP_DIR}/home/.bashrc"
root_rc="${TMP_DIR}/root/.bashrc"
mkdir -p "$(dirname "$user_rc")" "$(dirname "$root_rc")"
printf '# existing user line\n' > "$user_rc"
printf '# existing root line\n' > "$root_rc"

mkdir -p "${TMP_DIR}/fzf_bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "${TMP_DIR}/fzf_bin/fzf"
chmod +x "${TMP_DIR}/fzf_bin/fzf"

PATH="${TMP_DIR}/fzf_bin:${PATH}" "${inst_repo}/install.sh" --user-bashrc "$user_rc" --root-bashrc "$root_rc" >/dev/null
# Run a second time to verify idempotency
PATH="${TMP_DIR}/fzf_bin:${PATH}" "${inst_repo}/install.sh" --user-bashrc "$user_rc" --root-bashrc "$root_rc" >/dev/null

assert_eq "1" "$(grep -cF '# >>> lazy-bashrc >>>' "$user_rc")" "install adds single block to user bashrc"
assert_eq "1" "$(grep -cF '# >>> lazy-bashrc >>>' "$root_rc")" "install adds single block to root bashrc"
assert_contains "$(cat "$user_rc")" "# existing user line" "install preserves existing user bashrc content"
assert_contains "$(cat "$root_rc")" "# existing root line" "install preserves existing root bashrc content"
assert_eq "yes" "$([[ -f "${inst_repo}/config.env" ]] && echo yes || echo no)" "install creates config.env"

"${inst_repo}/install.sh" --uninstall --user-bashrc "$user_rc" --root-bashrc "$root_rc" >/dev/null
assert_not_contains "$(cat "$user_rc")" "lazy-bashrc" "uninstall removes block from user bashrc"
assert_not_contains "$(cat "$root_rc")" "lazy-bashrc" "uninstall removes block from root bashrc"
assert_contains "$(cat "$user_rc")" "# existing user line" "uninstall preserves existing user bashrc content"
assert_contains "$(cat "$root_rc")" "# existing root line" "uninstall preserves existing root bashrc content"

# 7b. Test sourcing install.sh in an interactive shell auto-sources user bashrc without leaking set -e
sourced_out="$(
    PATH="${TMP_DIR}/fzf_bin:${PATH}" bash --norc -i -c "
        source '${inst_repo}/install.sh' --user-bashrc '${user_rc}' --root-bashrc '${root_rc}' >/dev/null
        [[ \$- == *e* ]] && echo 'SETE_LEAK' || echo 'SETE_OK'
        declare -F sai >/dev/null && echo 'SOURCED_SAI_OK'
    " 2>/dev/null
)"
assert_contains "$sourced_out" "SETE_OK" "sourcing install.sh does not leak set -e"
assert_contains "$sourced_out" "SOURCED_SAI_OK" "sourcing install.sh auto-sources user bashrc into current shell"

# 7c. Test install.sh installs fzf via apt-get when fzf is missing
mkdir -p "${TMP_DIR}/apt_bin"
apt_log="${TMP_DIR}/apt_install.log"
: > "$apt_log"
cat > "${TMP_DIR}/apt_bin/sudo" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${apt_log}"
EOF
printf '#!/usr/bin/env bash\nexit 0\n' > "${TMP_DIR}/apt_bin/apt-get"
chmod +x "${TMP_DIR}/apt_bin/sudo" "${TMP_DIR}/apt_bin/apt-get"
PATH="${TMP_DIR}/apt_bin:/bin:/usr/bin" "${inst_repo}/install.sh" --user-bashrc "$user_rc" --root-bashrc "$root_rc" >/dev/null
assert_eq $'apt-get update\napt-get install -y fzf' "$(cat "$apt_log")" "install.sh installs fzf when missing"

# 8. Test external symlinked project bashrc loading (e.g. snake.bashrc) + broken symlink handling
proj_ext="${TMP_DIR}/external_snake"
proj_links="${TMP_DIR}/proj_links"
mkdir -p "$proj_ext" "$proj_links"
cat > "${proj_ext}/snake.bashrc" <<'EOF'
lazy_alias ms make snake-game

snake_ship() {
    lazy_run gco main
    lazy_run ms
}
lazy_register snake_ship
EOF

ln -s "${proj_ext}/snake.bashrc" "${proj_links}/snake.bashrc"
ln -s "${TMP_DIR}/does_not_exist.bashrc" "${proj_links}/broken.bashrc"

cat > "${TMP_DIR}/bin/make" <<EOF
#!/usr/bin/env bash
printf 'make %s\n' "\$*" >> "${MOCK_LOG}"
EOF
chmod +x "${TMP_DIR}/bin/make"

: > "$MOCK_LOG"
proj_err="${TMP_DIR}/proj_err.txt"
PATH="${TMP_DIR}/bin:${PATH}" bash -c "
    LAZY_PROJECTS_DIR='${proj_links}'
    # Simulate config.env override via XDG_CONFIG_HOME so init.sh uses proj_links
    xdg_dir='${TMP_DIR}/xdg/lazy-bashrc'
    mkdir -p \"\$xdg_dir\"
    printf 'LAZY_PROJECTS_DIR=%q\nLAZY_COLOR=never\n' '${proj_links}' > \"\${xdg_dir}/config.env\"
    XDG_CONFIG_HOME='${TMP_DIR}/xdg' source '${REPO_DIR}/init.sh'
    dr snake_ship
    ms --dry
" >/dev/null 2>"$proj_err"

proj_err_content="$(cat "$proj_err")"
assert_contains "$proj_err_content" "skipping broken or unreadable link" "broken project symlink warns cleanly without failing"
assert_contains "$proj_err_content" $'gco main\n  git checkout main\nms\n  make snake-game' "project function composes on top of lazy-bashrc aliases under dr"
assert_contains "$proj_err_content" "make snake-game --dry" "project alias ms forwards args"
assert_eq "make snake-game --dry" "$(cat "$MOCK_LOG")" "only live ms executes make while dr snake_ship skips git and make"

printf 'Tests finished: %d passed, %d failed\n' "$PASS_COUNT" "$FAIL_COUNT"
(( FAIL_COUNT == 0 ))
