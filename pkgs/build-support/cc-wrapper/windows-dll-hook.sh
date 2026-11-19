# DLL discovery supplies the package being built (HOST).
if [[ -z ${strictDeps-} ]] || (( hostOffset == 0 || targetOffset == 0 )); then
    addToSearchPath LINK_DLL_FOLDERS "@cc_solib@/lib"
    addToSearchPath LINK_DLL_FOLDERS "@cc_solib@/lib64"
    addToSearchPath LINK_DLL_FOLDERS "@cc_solib@/lib32"
fi
