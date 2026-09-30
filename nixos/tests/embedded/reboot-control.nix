# Control: stock NixOS doing what ./vm-test.nix's last subtest would do with machine.reboot().
{
  nixpkgs ? ../../..,
}:
(import nixpkgs { }).testers.runNixOSTest {
  name = "reboot-control";
  nodes.machine = { };
  testScript = ''
    machine.wait_for_unit("multi-user.target")
    machine.reboot()
    machine.wait_for_unit("multi-user.target")
    machine.shutdown()
  '';
}
