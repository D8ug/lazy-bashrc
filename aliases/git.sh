# Git shortcuts and composable workflow functions

lazy_alias gco git checkout
lazy_alias gs git status
lazy_alias gcom gco main
lazy_alias gcod gco develop
lazy_alias gl git log --oneline
lazy_alias gcmm git commit --amend
lazy_alias gcp git cherry-pick

# Create a new branch and check it out. Prompts for a name if none is given.
gcob() {
    local branch="$*"
    if [[ -z "$branch" ]]; then
        read -r -p "branch name> " branch || return 1
        branch="${branch#"${branch%%[![:space:]]*}"}"
        branch="${branch%"${branch##*[![:space:]]}"}"
        if [[ -z "$branch" ]]; then
            printf 'gcob: branch name cannot be empty\n' >&2
            return 1
        fi
    fi
    lazy_run gco -b "$branch"
}
lazy_register gcob

# Fuzzy branch checkout using fzf.
fgco() {
    if ! command -v fzf >/dev/null 2>&1; then
        printf 'fgco: fzf is required (install with: sai fzf)\n' >&2
        return 1
    fi

    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        printf 'fgco: not inside a git repository\n' >&2
        return 1
    fi

    local -a unique_branches=()
    local -A seen=()
    local line short
    while IFS= read -r line; do
        [[ -z "$line" || "$line" == "origin/HEAD" || "$line" == */HEAD ]] && continue
        short="${line#origin/}"
        if [[ -z "${seen[$short]:-}" ]]; then
            seen["$short"]=1
            unique_branches+=("$short")
        fi
    done < <(git branch -a --format='%(refname:short)' 2>/dev/null)

    if (( ${#unique_branches[@]} == 0 )); then
        printf 'fgco: no branches found\n' >&2
        return 1
    fi

    local -a fzf_args=(--height 40% --reverse --prompt="branch> ")
    if [[ $# -gt 0 ]]; then
        fzf_args+=(--query "$*" --select-1 --exit-0)
    fi

    local selected
    selected="$(printf '%s\n' "${unique_branches[@]}" | fzf "${fzf_args[@]}")" || return 1
    [[ -n "$selected" ]] || return 1
    lazy_run gco "$selected"
}
lazy_register fgco

_lazy_git_current_branch() {
    local branch
    branch="$(git branch --show-current 2>/dev/null || true)"
    if [[ -z "$branch" ]]; then
        printf 'lazy-bashrc: not on a branch (detached HEAD or not a git repository)\n' >&2
        return 1
    fi
    printf '%s' "$branch"
}

_lazy_git_push_current() {
    local branch
    branch="$(_lazy_git_current_branch)" || return 1
    lazy_run git push "$@" origin "$branch"
}

gps() {
    _lazy_git_push_current "$@"
}
lazy_register gps

gpsf() {
    _lazy_git_push_current --force-with-lease "$@"
}
lazy_register gpsf

gpsfff() {
    _lazy_git_push_current --force "$@"
}
lazy_register gpsfff

# Show status via gs, then stage only tracked files with unstaged modifications.
gam() {
    local repo_root
    repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
        printf 'gam: not inside a git repository\n' >&2
        return 1
    }

    lazy_run gs

    local -a files=()
    local entry x y path
    while IFS= read -r -d '' entry; do
        x="${entry:0:1}"
        y="${entry:1:1}"
        path="${entry:3}"
        if [[ "$x" == "R" || "$x" == "C" ]]; then
            IFS= read -r -d '' _
        fi
        if [[ "$y" == "M" ]]; then
            files+=("$path")
        fi
    done < <(git -C "$repo_root" status --porcelain -z)

    if (( ${#files[@]} == 0 )); then
        printf 'gam: no unstaged modified files to add\n' >&2
        return 0
    fi

    if [[ "$PWD" == "$repo_root" ]]; then
        lazy_run git add -- "${files[@]}"
    else
        lazy_run git -C "$repo_root" add -- "${files[@]}"
    fi
}
lazy_register gam

# Add modified files, amend commit, and safely force-push current branch.
gacmmnp() {
    lazy_run gam && lazy_run gcmm "$@" && lazy_run gpsf
}
lazy_register gacmmnp
