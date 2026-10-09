# The hardware of a QEMU x86_64 guest, as far as the systems use it: virtio devices on PCI (disk, network,
# entropy), the 8250 serial console, and virtio's hvc console (the NixOS test driver's backdoor). Nothing for
# the hypervisor itself (kvmclock, paravirtualization): the guest runs without.
{ lib }:
let
  inherit (lib.kernel) yes no;
in
{
  PCI = yes;
  PCI_MSI = yes; # virtio-pci's interrupts
  VIRTIO_MENU = yes;
  VIRTIO_PCI = yes;
  VIRTIO_BLK = yes;
  NETDEVICES = yes;
  VIRTIO_NET = yes;
  HW_RANDOM = yes;
  HW_RANDOM_VIRTIO = yes;
  VIRTIO_CONSOLE = yes; # hvc
  SERIAL_8250 = yes;
  SERIAL_8250_CONSOLE = yes;

  # Defaults that come along and none of it needs: the text console on a display (VT), 8250 variants of other
  # buses and SoCs, swap.
  VT = no;
  SERIAL_8250_PNP = no;
  SERIAL_8250_PCI = no;
  SERIAL_8250_LPSS = no;
  SERIAL_8250_MID = no;
  SWAP = no;
  # The performance counters of Intel's uncore, power (RAPL) and C-states, which a guest has none of.
  PERF_EVENTS_INTEL_UNCORE = no;
  PERF_EVENTS_INTEL_RAPL = no;
  PERF_EVENTS_INTEL_CSTATE = no;
  # The ACPI processor driver (idle states, performance limits, thermal), which a guest has no use for, and
  # which without CPU_FREQ warns at every boot that it cannot handle performance limits.
  ACPI_PROCESSOR = no;
}
