# Git shortcuts and composable workflow functions

lazy_alias gco git checkout
lazy_alias gs git status
lazy_alias gcom gco main
lazy_alias gcod gco develop
lazy_alias gl git log --oneline
lazy_alias gpl git pull
lazy_alias gcmm git commit --amend
lazy_alias gcp git cherry-pick

# Create and check out a new branch; prompts if no name is given.
gcob() {
    local branch="$*"
    [[ -z "$branch" ]] && read -r -p "branch name> " branch
    branch="${branch#"${branch%%[![:space:]]*}"}"
    branch="${branch%"${branch##*[![:space:]]}"}"
    [[ -n "$branch" ]] && lazy_run gco -b "$branch"
}
lazy_register gcob

# Fuzzy branch checkout using fzf.
fgco() {
    command -v fzf >/dev/null 2>&1 || { printf 'fgco: fzf is required (install with: sai fzf)\n' >&2; return 1; }
    local -a fzf_opts=(--height 40% --reverse --prompt="branch> ")
    (( $# )) && fzf_opts+=(--query "$*" --select-1 --exit-0)
    local branch
    branch="$(git branch -a --format='%(refname:short)' | awk '!/\/HEAD$/ { sub(/^origin\//, ""); if (!seen[$0]++) print }' | fzf "${fzf_opts[@]}")" || return 1
    [[ -n "$branch" ]] && lazy_run gco "$branch"
}
lazy_register fgco

_lazy_gps() {
    local branch
    branch="$(git branch --show-current 2>/dev/null)" && [[ -n "$branch" ]] || return 1
    lazy_run git push "$@" origin "$branch"
}

gps()    { _lazy_gps "$@"; }
gpsf()   { _lazy_gps --force-with-lease "$@"; }
gpsfff() { _lazy_gps --force "$@"; }
lazy_register gps gpsf gpsfff

# Show status via gs, then stage only tracked files with unstaged modifications.
gam() {
    lazy_run gs || return 1
    local -a files=()
    mapfile -d '' -t files < <(git status --porcelain -z | awk -v RS='\0' -v ORS='\0' '
        substr($0,2,1) == "M" { print substr($0,4) }
        substr($0,1,1) ~ /^[RC]$/ { getline _ }
    ')
    (( ${#files[@]} )) || return 0
    local top
    top="$(git rev-parse --show-toplevel)"
    if [[ "$PWD" == "$top" ]]; then
        lazy_run git add -- "${files[@]}"
    else
        lazy_run git -C "$top" add -- "${files[@]}"
    fi
}
lazy_register gam

# Add modified files, amend commit, and safely force-push current branch.
gacmmnp() {
    lazy_run gam && lazy_run gcmm "$@" && lazy_run gpsf
}
lazy_register gacmmnp
