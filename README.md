# lazy-bashrc

A modular, composable Bash alias and function framework with blue execution tracing and dry-run (`dr`) support.

## Features

- **Composable aliases & functions**: Aliases created with `lazy_alias` are backed by Bash functions, so functions can call aliases and other functions seamlessly while preserving `cd` and environment changes in the current shell.
- **Blue command tracing (`stderr`)**: Every command and registered function call prints to `stderr` in blue before running, with indentation for nested calls.
- **Dry-run mode (`dr <command>`)**: Prints the full nested command trace without executing underlying system or builtin commands.
- **Environment config (`config.env`)**: Keeps machine-specific paths and display settings (such as `LAZY_WORK_DIR`) out of version control.
- **User + Root (`sudo su`) support**: `install.sh` hooks `init.sh` into both `~/.bashrc` and `/root/.bashrc`.

## Project Layout

```text
lazy-bashrc/
├── init.sh              # Entry point sourced by ~/.bashrc and /root/.bashrc
├── install.sh           # Adds/removes bashrc hooks and creates config.env
├── config.env.example   # Config template (copy to config.env)
├── lib/
│   └── core.sh          # lazy_alias, lazy_register, lazy_run, dr
├── aliases/
│   ├── apt.sh           # sai -> sudo apt install -y
│   └── git.sh           # gco -> git checkout
├── functions/
│   └── examples.sh      # Example composite functions (commented out)
├── projects/
│   └── README.md        # Drop symlinks here (e.g. snake.bashrc -> external repo)
└── tests/
    └── test_lazy_bashrc.sh
```

## Quick Start

```bash
cd /opt/git/lazy-bashrc
source ./install.sh
```

Sourcing `install.sh` installs the hooks in `~/.bashrc` and `/root/.bashrc`, creates `config.env`, and immediately runs `source ~/.bashrc` in your current shell.

To install only for the current user (skipping `/root/.bashrc`), run `source ./install.sh --user-only`. To uninstall, run `./install.sh --uninstall`.

## Baseline Commands

| Command | Expands to |
| --- | --- |
| `sai <pkg...>` | `sudo apt install -y <pkg...>` |
| `gco <args...>` | `git checkout <args...>` |
| `dr <cmd> [args...]` | Dry-run: prints what `<cmd>` will run without executing |

## Adding Aliases and Composite Functions

Add new aliases in `aliases/*.sh`:

```bash
lazy_alias gcob gco -b
```

Add composite functions in `functions/*.sh` using `lazy_run` and `lazy_register`:

```bash
cd-work() {
    lazy_run cd "${LAZY_WORK_DIR}/${1:-}"
}
lazy_register cd-work

cb() {
    lazy_run cd-work lazy-bashrc
}
lazy_register cb
```

Running `cb` or `dr cb` prints:

```text
cd-work lazy-bashrc
  cd /opt/git/lazy-bashrc
```

## Per-Project Bashrc Symlinks

Each of your repositories can maintain its own `*.bashrc` file outside `lazy-bashrc` and compose on top of `lazy-bashrc` functions:

```bash
# Inside /opt/git/snake/snake.bashrc:
lazy_alias ms make snake-game

snake-ship() {
    lazy_run gco main
    lazy_run ms
}
lazy_register snake-ship
```

Symlink it into `projects/` (gitignored) or set `LAZY_PROJECTS_DIR` in `config.env`:

```bash
ln -s /opt/git/snake/snake.bashrc /opt/git/lazy-bashrc/projects/snake.bashrc
```

## Running Tests

```bash
bash tests/test_lazy_bashrc.sh
```
