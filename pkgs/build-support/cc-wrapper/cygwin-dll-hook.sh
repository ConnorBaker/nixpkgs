# These paths and configure flags affect the package being built (HOST).
if [[ -z ${strictDeps-} ]] || (( hostOffset == 0 || targetOffset == 0 )); then
    addToSearchPath _linkDeps_inputPath "@cc_solib@/bin"
    # Work around build failure caused by the gnulib workaround for
    # https://gcc.gnu.org/bugzilla/show_bug.cgi?id=114870. Remove once the
    # gnulib workaround is updated in core packages (gawk, gnupatch, gnugrep).
    appendToVar configureFlags gl_cv_clean_version_stddef=yes
fi
