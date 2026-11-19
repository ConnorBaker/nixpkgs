# Binutils Wrapper hygiene
#
# See comments in cc-wrapper's setup hook. This works exactly the same way.

# See ../setup-hooks/role.bash
getTargetRole
getTargetRoleWrapper

source @out@/nix-support/add-env-hooks.sh

# shellcheck disable=SC2157
if [ -n "@bintools_bin@" ]; then
    addToSearchPath _PATH @bintools_bin@/bin
fi

# shellcheck disable=SC2157
if [ -n "@libc_bin_for_host@" ]; then
    addToSearchPath _PATH @libc_bin_for_host@/bin
fi

# shellcheck disable=SC2157
if [ -n "@coreutils_bin@" ]; then
    addToSearchPath _PATH @coreutils_bin@/bin
fi

# Export tool environment variables so various build systems use the right ones.

export NIX_BINTOOLS${role_post}=@out@

for cmd in \
    ar as ld nm objcopy objdump readelf ranlib strip strings size windres rc
do
    if
        PATH=$_PATH type -p "@targetPrefix@${cmd}" > /dev/null
    then
        upper_case="$(echo "$cmd" | tr "a-z" "A-Z")"
        export "${upper_case}${role_post}=@targetPrefix@${cmd}";
    fi
done

# If there is no `<prefix>rc`, but there is a `<prefix>windres`, define
# `RC<suffix>=${WINDRES<suffix>}`.
if
    [[ ! -v "RC${role_post}" ]] && [[ -v "WINDRES${role_post}" ]]
then
    windres_var="WINDRES${role_post}"
    export "RC${role_post}=${!windres_var}"
    unset -v windres_var
fi

if [[ -z $role_post ]]; then
    source @out@/nix-support/set-default-hardening.sh
fi

# No local scope in sourced file
unset -v role_post cmd upper_case
