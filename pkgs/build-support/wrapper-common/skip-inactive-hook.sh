# In a strict build only a compiler that runs on BUILD can supply tools.
# Return before the concatenated role helpers change the enclosing shell.
[[ -z ${strictDeps-} ]] || (( hostOffset < 0 )) || return 0
