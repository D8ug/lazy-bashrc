# Project Symlinks (`projects/`)

Drop symlinks to per-project bashrc files (`*.bashrc`, `*.sh`, or `*.bash`) here so they are loaded automatically after `aliases/` and `functions/` without committing project-specific commands into `lazy-bashrc`.

Example (for an external `snake` repo at `/opt/git/snake/snake.bashrc`):

```bash
ln -s /opt/git/snake/snake.bashrc /opt/git/lazy-bashrc/projects/snake.bashrc
```

All files in `projects/*` (except this `README.md`) are gitignored. You can also point `LAZY_PROJECTS_DIR` in `config.env` to a custom directory outside this repo.
