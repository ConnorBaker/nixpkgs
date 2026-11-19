getTargetRole
getTargetRoleWrapper

export FC${role_post}=@named_fc@

if [[ -z $role_post ]]; then
    source @out@/nix-support/set-default-hardening.sh
fi

unset -v role_post
