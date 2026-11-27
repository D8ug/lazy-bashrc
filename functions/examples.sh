# Custom composite functions for lazy-bashrc.
# All *.sh files in this directory are sourced automatically by init.sh.
#
# Example: building composite functions on top of other functions and config.env:
#
# cd-work() {
#     local target="${LAZY_WORK_DIR}/${1:-}"
#     lazy_run cd "$target"
# }
# lazy_register cd-work
#
# cb() {
#     lazy_run cd-work lazy-bashrc
# }
# lazy_register cb
#
# Running `cb` (or `dr cb`) will print:
#   cd-work lazy-bashrc
#     cd /opt/git/lazy-bashrc
