# Navigation shortcuts using config.env (LAZY_WORK_DIR)

# Change directory into a project under LAZY_WORK_DIR.
cd-work() {
    lazy_run cd "${LAZY_WORK_DIR}/${1:-}"
}
lazy_register cd-work

# Change directory to the lazy-bashrc repository.
cb() {
    if [[ -n "${LAZY_WORK_DIR:-}" && -d "${LAZY_WORK_DIR}/lazy-bashrc" ]]; then
        lazy_run cd-work lazy-bashrc
    else
        lazy_run cd "${LAZY_BASHRC_DIR}"
    fi
}
lazy_register cb

# Directory-up shortcuts: c -> cd .., cc -> cd ../.., cccc -> cd ../../../.., etc.
_lazy_c_name="c"
_lazy_c_path=".."
for (( _lazy_i = 1; _lazy_i <= ${LAZY_MAX_CD_UP:-16}; _lazy_i++ )); do
    lazy_alias "$_lazy_c_name" cd "$_lazy_c_path"
    _lazy_c_name+="c"
    _lazy_c_path+="/.."
done
unset _lazy_c_name _lazy_c_path _lazy_i
