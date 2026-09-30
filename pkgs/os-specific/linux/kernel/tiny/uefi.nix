# Booting as a UKI from UEFI firmware: the kernel's EFI stub, which systemd-stub hands over to. On x86 EFI
# depends on ACPI, which the firmware describes the machine with.
{ lib }:
let
  inherit (lib.kernel) yes no;
in
{
  ACPI = yes;
  EFI = yes;
  EFI_STUB = yes;
  EFIVAR_FS = no; # a module by default; systemd reads EFI variables only for optional boot loader integration
}
