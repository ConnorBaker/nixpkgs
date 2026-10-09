# What a NixOS system with the appliance's systemd requires of the kernel, on top of ./default.nix's `common`.
{ lib }:
let
  inherit (lib.kernel) yes no;
in
{
  # The embedded profile adds system.requiredKernelConfig; these are what those options depend on.
  CRYPTO = yes; # the menu of the CRYPTO_* options
  DMI = yes; # for DMIID; tinyconfig's EXPERT makes it a question

  # systemd (its README) for what the appliance enables: sandboxing, resource control, oomd, networkd.
  NAMESPACES = yes;
  USER_NS = yes;
  MEMCG = yes;
  CGROUP_SCHED = yes;
  CGROUP_PIDS = yes;
  CGROUP_BPF = yes; # device access control of units
  BPF_SYSCALL = yes;
  PSI = yes; # oomd
  POSIX_MQUEUE = yes;
  SYSVIPC = yes;
  INET = yes;
  IPV6_SIT = no; # IPv6-in-IPv4 tunnels, a module by default (with INET_TUNNEL and NET_IP_TUNNEL)
  PACKET = yes; # networkd's DHCP client

  TIME_NS = no; # time namespaces: containers'
  # (Not INET_TABLE_PERTURB_ORDER, the 256 KiB table that randomizes the source ports of outgoing connections:
  # with 2^8 entries, as before 5.17.9, a server can recognize a device by its ports, CVE-2022-32296.)
}
