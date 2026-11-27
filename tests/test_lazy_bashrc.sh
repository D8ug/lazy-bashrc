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
    "${REPO_DIR}/refresh.sh" \
    "${REPO_DIR}/lib/core.sh" \
    "${REPO_DIR}/aliases/apt.sh" \
    "${REPO_DIR}/aliases/git.sh" \
    "${REPO_DIR}/functions/examples.sh" \
    "${REPO_DIR}/functions/navigation.sh" \
    "${REPO_DIR}/functions/refresh.sh" \
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

    lazy_alias gcob_alias gco -b

    cd '${TMP_DIR}'
    dr cb
    echo \"PWD_AFTER_DR=\${PWD}\"
    cb
    echo \"PWD_AFTER_CB=\${PWD}\"
    dr gcob_alias topic-1
" >"$comp_out" 2>"$comp_err"

assert_eq "PWD_AFTER_DR=${TMP_DIR}"$'\n'"PWD_AFTER_CB=${TMP_DIR}/work/lazy-bashrc" "$(cat "$comp_out")" "dr cb preserves PWD while live cb changes PWD"
expected_comp_err=$'cd-work lazy-bashrc\n  cd '"${TMP_DIR}"$'/work/lazy-bashrc\ncd-work lazy-bashrc\n  cd '"${TMP_DIR}"$'/work/lazy-bashrc\ngco -b topic-1\n  git checkout -b topic-1'
assert_eq "$expected_comp_err" "$(cat "$comp_err")" "nested indentation trace for composite functions and aliases"
assert_eq "" "$(cat "$MOCK_LOG")" "dr gcob_alias does not execute git"

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

# 9. Test git aliases & workflow functions against a real temp git repo + bare remote
git_bare="${TMP_DIR}/remote.git"
git_work="${TMP_DIR}/work_repo"
git init --bare -b main "$git_bare" >/dev/null 2>&1
git clone "$git_bare" "$git_work" >/dev/null 2>&1
git -C "$git_work" config user.name "Test User"
git -C "$git_work" config user.email "test@example.com"
printf 'v1\n' > "${git_work}/tracked.txt"
printf 'other\n' > "${git_work}/other.txt"
git -C "$git_work" add tracked.txt other.txt
git -C "$git_work" commit -m "initial" >/dev/null 2>&1
git -C "$git_work" push -u origin main >/dev/null 2>&1
git -C "$git_work" checkout -b develop >/dev/null 2>&1
git -C "$git_work" checkout -b feature/alpha >/dev/null 2>&1
git -C "$git_work" checkout main >/dev/null 2>&1

# 9a. Test dr traces for gs, gcom, gcod, gl, gcmm, gcp, gps, gpsf, gpsfff, gcob (arg & prompt)
git_dr_err="${TMP_DIR}/git_dr_err.txt"
bash -c "
    cd '${git_work}'
    source '${REPO_DIR}/init.sh'
    LAZY_COLOR=never
    dr gs
    dr gcom
    dr gcod
    dr gl -n 5
    dr gcmm --no-edit
    dr gcp abc123
    dr gps
    dr gpsf
    dr gpsfff
    dr gcob feat/arg-branch
    dr gcob <<< '  feat/from-prompt  '
" >/dev/null 2>"$git_dr_err"

git_dr_content="$(cat "$git_dr_err")"
assert_contains "$git_dr_content" "git status" "dr gs trace"
assert_contains "$git_dr_content" $'gco main\n  git checkout main' "dr gcom nested trace"
assert_contains "$git_dr_content" $'gco develop\n  git checkout develop' "dr gcod nested trace"
assert_contains "$git_dr_content" "git log --oneline -n 5" "dr gl trace"
assert_contains "$git_dr_content" "git commit --amend --no-edit" "dr gcmm trace"
assert_contains "$git_dr_content" "git cherry-pick abc123" "dr gcp trace"
assert_contains "$git_dr_content" "git push origin main" "dr gps trace"
assert_contains "$git_dr_content" "git push --force-with-lease origin main" "dr gpsf trace"
assert_contains "$git_dr_content" "git push --force origin main" "dr gpsfff trace"
assert_contains "$git_dr_content" $'gco -b feat/arg-branch\n  git checkout -b feat/arg-branch' "dr gcob with arg"
assert_contains "$git_dr_content" $'gco -b feat/from-prompt\n  git checkout -b feat/from-prompt' "dr gcob prompts and trims branch name"

# 9b. Test live gcod, gcom, gcob (prompted), fgco (fzf + missing fzf check), gl, gcp
mkdir -p "${TMP_DIR}/fzf_bin"
cat > "${TMP_DIR}/fzf_bin/fzf" <<'EOF'
#!/usr/bin/env bash
query=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --query) query="${2:-}"; shift 2 ;;
        *) shift ;;
    esac
done
if [[ -n "$query" ]]; then
    grep -m1 "$query"
else
    grep -m1 '^develop$'
fi
EOF
chmod +x "${TMP_DIR}/fzf_bin/fzf"

live_git_out="${TMP_DIR}/live_git_out.txt"
PATH="${TMP_DIR}/fzf_bin:${PATH}" bash -c "
    cd '${git_work}'
    source '${REPO_DIR}/init.sh'
    LAZY_COLOR=never
    gcod
    echo \"AFTER_GCOD=\$(git branch --show-current)\"
    gcom
    echo \"AFTER_GCOM=\$(git branch --show-current)\"
    gcob <<< 'feat/live-prompt'
    echo \"AFTER_GCOB=\$(git branch --show-current)\"
    printf 'cherry\n' > '${git_work}/cherry.txt'
    git add cherry.txt && git commit -m 'cherry commit' >/dev/null
    cherry_sha=\$(git rev-parse HEAD)
    fgco alpha
    echo \"AFTER_FGCO_QUERY=\$(git branch --show-current)\"
    gcp \"\$cherry_sha\" >/dev/null
    gl -n 2
    fgco
    echo \"AFTER_FGCO_PICK=\$(git branch --show-current)\"
" >"$live_git_out" 2>/dev/null

live_git_content="$(cat "$live_git_out")"
assert_contains "$live_git_content" "AFTER_GCOD=develop" "gcod checks out develop"
assert_contains "$live_git_content" "AFTER_GCOM=main" "gcom checks out main"
assert_contains "$live_git_content" "AFTER_GCOB=feat/live-prompt" "gcob creates and checks out prompted branch"
assert_contains "$live_git_content" "AFTER_FGCO_QUERY=feature/alpha" "fgco passes query to fzf and checks out feature/alpha"
assert_contains "$live_git_content" "AFTER_FGCO_PICK=develop" "fgco uses fzf interactively without query"
assert_contains "$live_git_content" "cherry commit" "gcp cherry-picks commit and gl prints oneline log"

missing_fzf_err="$(
    PATH="/usr/bin:/bin" bash -c "
        cd '${git_work}'
        source '${REPO_DIR}/init.sh'
        fgco
    " 2>&1 || true
)"
assert_contains "$missing_fzf_err" "fgco: fzf is required" "fgco reports missing fzf clearly"

# 9c. Test gam (only unstaged modified files, not untracked or already staged) + gacmmnp (dr & live)
bash -c "
    cd '${git_work}'
    source '${REPO_DIR}/init.sh'
    LAZY_COLOR=never
    gcob feat/amend-push >/dev/null 2>&1
    printf 'base\n' > '${git_work}/tracked.txt'
    git add tracked.txt && git commit -m 'base feature' >/dev/null
    gps >/dev/null 2>&1
"
printf 'modified\n' > "${git_work}/tracked.txt"
printf 'untracked\n' > "${git_work}/untracked.txt"
printf 'pre-staged\n' > "${git_work}/prestaged.txt"
git -C "$git_work" add prestaged.txt

gacmmnp_dr_err="${TMP_DIR}/gacmmnp_dr_err.txt"
bash -c "
    cd '${git_work}'
    source '${REPO_DIR}/init.sh'
    LAZY_COLOR=never
    dr gacmmnp --no-edit
" >/dev/null 2>"$gacmmnp_dr_err"

gacmmnp_dr_content="$(cat "$gacmmnp_dr_err")"
assert_contains "$gacmmnp_dr_content" $'gam\n  gs\n    git status\n  git add -- tracked.txt' "dr gacmmnp traces gam -> gs and adds only unstaged modified file"
assert_contains "$gacmmnp_dr_content" $'gcmm --no-edit\n  git commit --amend --no-edit' "dr gacmmnp traces gcmm"
assert_contains "$gacmmnp_dr_content" $'gpsf\n  git push --force-with-lease origin feat/amend-push' "dr gacmmnp traces gpsf"
assert_eq " M tracked.txt" "$(git -C "$git_work" status --porcelain | grep ' tracked\.txt$')" "dr gacmmnp leaves tracked.txt unstaged"

# Now run live gacmmnp --no-edit and verify untracked.txt stays untracked, tracked.txt is amended & pushed
bash -c "
    cd '${git_work}'
    source '${REPO_DIR}/init.sh'
    LAZY_COLOR=never
    gacmmnp --no-edit
" >/dev/null 2>&1

assert_eq "?? untracked.txt" "$(git -C "$git_work" status --porcelain)" "live gacmmnp commits tracked & prestaged files while leaving untracked.txt untracked"
assert_eq "$(git -C "$git_work" rev-parse HEAD)" "$(git -C "$git_bare" rev-parse refs/heads/feat/amend-push)" "live gacmmnp force-pushes amended commit to origin"

# 10. Test gpl, cb, and refresh.sh (both sourced and executed)
refresh_work="${TMP_DIR}/refresh_work"
refresh_bare="${TMP_DIR}/refresh_bare.git"
refresh_repo="${refresh_work}/lazy-bashrc"
mkdir -p "$refresh_work"
git init --bare -b main "$refresh_bare" >/dev/null 2>&1
git clone "$refresh_bare" "$refresh_repo" >/dev/null 2>&1
git -C "$refresh_repo" config user.name "Test User"
git -C "$refresh_repo" config user.email "test@example.com"

cp "${REPO_DIR}/init.sh" "${REPO_DIR}/refresh.sh" "${REPO_DIR}/config.env.example" "$refresh_repo/"
cp -r "${REPO_DIR}/lib" "${REPO_DIR}/aliases" "${REPO_DIR}/functions" "$refresh_repo/"
chmod +x "${refresh_repo}/init.sh" "${refresh_repo}/refresh.sh"
printf 'LAZY_WORK_DIR=%q\nLAZY_COLOR=never\n' "$refresh_work" > "${refresh_repo}/config.env"

git -C "$refresh_repo" add -A
git -C "$refresh_repo" commit -m "initial lazy-bashrc" >/dev/null 2>&1
git -C "$refresh_repo" push -u origin main >/dev/null 2>&1

# Push a new commit from a second clone so main is behind origin/main
refresh_other="${TMP_DIR}/refresh_other"
git clone "$refresh_bare" "$refresh_other" >/dev/null 2>&1
git -C "$refresh_other" config user.name "Test User"
git -C "$refresh_other" config user.email "test@example.com"
printf '\nlazy_alias test_new_alias echo refreshed\n' >> "${refresh_other}/aliases/git.sh"
git -C "$refresh_other" add aliases/git.sh
git -C "$refresh_other" commit -m "add test_new_alias" >/dev/null 2>&1
git -C "$refresh_other" push origin main >/dev/null 2>&1

# Put refresh_repo on a feature branch before running source ./refresh.sh from TMP_DIR
git -C "$refresh_repo" checkout -b feat/old-topic >/dev/null 2>&1
refresh_rc="${TMP_DIR}/refresh_bashrc"
printf 'source %q\n' "${refresh_repo}/init.sh" > "$refresh_rc"

refresh_out="$(
    bash --norc -i -c "
        cd '${TMP_DIR}'
        source '${refresh_repo}/refresh.sh' --rc '${refresh_rc}'
        [[ \$- == *e* ]] && echo 'REFRESH_SETE_LEAK' || echo 'REFRESH_SETE_OK'
        echo \"REFRESH_PWD=\${PWD}\"
        echo \"REFRESH_BRANCH=\$(git branch --show-current)\"
        declare -F test_new_alias >/dev/null && echo 'NEW_ALIAS_LOADED'
    " 2>/dev/null
)"

assert_contains "$refresh_out" "REFRESH_SETE_OK" "sourcing refresh.sh does not leak set -e"
assert_contains "$refresh_out" "REFRESH_PWD=${refresh_repo}" "refresh.sh moves PWD via cb to lazy-bashrc repo"
assert_contains "$refresh_out" "REFRESH_BRANCH=main" "refresh.sh checks out main via gcom"
assert_contains "$refresh_out" "NEW_ALIAS_LOADED" "refresh.sh pulls via gpl and reloads commands into current shell"

# Also verify executing ./refresh.sh in a subshell prints reload notice and exits 0
sub_refresh_out="$("${refresh_repo}/refresh.sh" 2>/dev/null)"
assert_contains "$sub_refresh_out" "source ~/.bashrc" "executed refresh.sh prints reload reminder"

# 10b. Test refresh() function (dr refresh + live refresh pulling another new commit & reloading)
printf '\nlazy_alias test_refresh_fn_alias echo refreshed_via_fn\n' >> "${refresh_other}/aliases/git.sh"
git -C "$refresh_other" add aliases/git.sh
git -C "$refresh_other" commit -m "add test_refresh_fn_alias" >/dev/null 2>&1
git -C "$refresh_other" push origin main >/dev/null 2>&1
git -C "$refresh_repo" checkout -b feat/another-topic >/dev/null 2>&1

refresh_fn_out="$(
    bash --norc -i -c "
        source '${refresh_repo}/init.sh'
        dr refresh '${refresh_rc}'
        refresh '${refresh_rc}'
        echo \"FN_BRANCH=\$(git -C '${refresh_repo}' branch --show-current)\"
        declare -F test_refresh_fn_alias >/dev/null && echo 'FN_NEW_ALIAS_LOADED'
    " 2>/dev/null
)"
assert_contains "$refresh_fn_out" "FN_BRANCH=main" "refresh function updates repo to main"
assert_contains "$refresh_fn_out" "FN_NEW_ALIAS_LOADED" "refresh function sources rc and loads new commands"

printf 'Tests finished: %d passed, %d failed\n' "$PASS_COUNT" "$FAIL_COUNT"
(( FAIL_COUNT == 0 ))
