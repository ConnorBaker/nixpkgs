{
  name = "Test that basic tests work when busybox is installed";

  nodes = {
    machine = (
      { pkgs, ... }:
      {
        environment.systemPackages = [
          pkgs.busybox
        ];
      }
    );
  };

  testScript = ''
    import datetime

    start_all()
    machine.wait_for_unit("multi-user.target")

    with subtest("a port probe does not connect to itself"):
        # Connections can only get source port 50001, which nothing is bound to.
        machine.succeed("sysctl -w net.ipv4.ip_local_port_range='50001 50001'")
        machine.wait_for_closed_port(50001, "127.0.0.1", timeout=datetime.timedelta(seconds=5))
        machine.succeed("sysctl -w net.ipv4.ip_local_port_range='32768 60999'")
        machine.succeed("systemd-run nc -lk 127.0.0.1 50001")
        machine.wait_for_open_port(50001, "127.0.0.1", timeout=datetime.timedelta(seconds=5))
        # The probe keeps the machine's own reservations: no source port is left.
        machine.succeed("sysctl -w net.ipv4.ip_local_reserved_ports=50002 net.ipv4.ip_local_port_range='50002 50002'")
        machine.wait_for_closed_port(50001, "127.0.0.1", timeout=datetime.timedelta(seconds=5))
        machine.succeed("[ $(cat /proc/sys/net/ipv4/ip_local_reserved_ports) = 50002 ]")
        # Where the setting cannot be written, the probe runs nc as before.
        machine.succeed("sysctl -w net.ipv4.ip_local_port_range='32768 60999' && mount --bind /proc/sys /proc/sys && mount -o remount,bind,ro /proc/sys")
        machine.wait_for_open_port(50001, "127.0.0.1", timeout=datetime.timedelta(seconds=5))
  '';
}
