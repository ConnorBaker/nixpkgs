set -eu
output=$1
mocks=$2
auditor=$3
profile=$4
loader=$5
nvgpuProvider=$6
probe=$mocks/control/probe
foreign=$mocks/control/observer.so
runtime=$output/runtime/libcudart.so.13
linked=$output/linked/plugin.so
driver=libcuda.so.1
export LD_LIBRARY_PATH="$mocks/host"

expect() {
    local expected=$1 actual status=0
    shift
    actual=$("$@") || status=$?
    if ((status)) || [[ $actual != "$expected" ]]; then
        printf 'expected %q, got %q (exit %d) from %s\n' "$expected" "$actual" "$status" "$*" >&2
        exit 1
    fi
}

mkdir -p dev sys/module/nvidia

# A container can see the running kernel version without injected device nodes.
echo 615.71.09 > sys/module/nvidia/version
expect 615 "$output/bin/direct"
touch dev/nvidiactl
expect 615 "$probe" call "$runtime" "$driver"
rm dev/nvidiactl
ln -s /dev/null dev/nvidiactl
rm sys/module/nvidia/version
expect 615 "$output/bin/direct"
for entry in 615.71.09:620 620.70.05:620 620.70.06:615 625.1:615 590.1:615 unknown:615; do
    printf '%s\n' "${entry%:*}" > sys/module/nvidia/version
    expect "${entry#*:}" "$output/bin/direct"
    expect "${entry#*:}" "$probe" call "$runtime" "$driver"
    expect "${entry#*:}" "$probe" call "$mocks/control/static-runtime.so" "$driver"
done
echo 615.71.09 > sys/module/nvidia/version
# An Arm system with the Orin compute driver needs its separate provider.
mkdir dev/nvgpu
expect "$nvgpuProvider" "$output/bin/direct"
rmdir dev/nvgpu
mkdir sys/module/nvgpu
expect "$nvgpuProvider" "$probe" call "$runtime" "$driver"
rmdir sys/module/nvgpu
expect 0 "$probe" noload "$runtime" "$driver" absent "$driver"
expect 0 "$probe" noload "$mocks/control/static-runtime.so" "$driver" absent "$driver"
expect 615 "$probe" call "$mocks/control/static-runtime.so" '$ORIGIN/../host/libcuda.so'
# A tail call through the extension must preserve the outer requester's search.
expect 615 env -u LD_LIBRARY_PATH "$probe" call "$mocks/control/requester.so" "$driver"
expect 615 "$probe" call "$mocks/control/requester.so" '$ORIGIN/../host/libcuda.so'
expect 615 "$probe" open "$mocks/host/$driver" call "$runtime" "$driver"
expect 615 "$probe" open "$mocks/host/$driver" noload "$runtime" "$driver"
expect 615 "$probe" call "$runtime" libcuda.so
expect 7 "$probe" call "$runtime" libcaller-path.so
expect 615 "$probe" call "$linked" unused

# The selected driver needs its own compiler even when another object loaded the host's first.
compiler=libnvidia-ptxjitcompiler.so.1
expect 620 "$probe" open "$mocks/host/$compiler" call "$mocks/compat/$driver" "$compiler"
expect 615 "$probe" open "$mocks/host/$compiler" call "$mocks/compat/$driver" "$mocks/host/$compiler"

# The same foreign executable with an auditor, without a marker of its own.
expect 620 env LD_AUDIT="$auditor" "$probe" call "$linked" unused
expect 620 env LD_AUDIT="$auditor" "$probe" open "$runtime" call "$foreign" "$driver"
# A relative library name still represents the original mapping after chdir.
mkdir changed
ln -s ../dev ../sys changed/
ln -s "$output" indexed
expect 620 env LD_AUDIT="$auditor" "$probe" open ./indexed/runtime/libcudart.so.13 chdir changed call "$foreign" "$driver"
expect 620 env LD_AUDIT="$auditor" "$probe" open "$output/runtime/private/libcaller-path.so" call "$foreign" "$driver"
expect 615 env LD_AUDIT="$auditor" "$probe" close "$runtime" call "$foreign" "$driver"
expect 615 env LD_AUDIT="$auditor" "$probe" separate "$runtime" call "$foreign" "$driver"
expect 615 env LD_AUDIT="$auditor" "$probe" open "$mocks/host/$driver" call "$linked" unused

# An unmodified library can issue the request on behalf of a packaged executable.
expect 620 "$output/bin/late" call "$foreign" "$driver"
expect 620 "$loader" "$output/bin/late" call "$foreign" "$driver"

# Both candidates apply only to their supported kernel branches. A driver
# already bound remains the provider when another toolkit loads later.
new=$profile/lib/libcudart.so.13
old=$profile/lib/libcudart.so.12
expect 619 "$profile/bin/consumer-12" call "$foreign" "$driver"
expect 620 "$profile/bin/consumer-13" call "$foreign" "$driver"
expect 620 env LD_AUDIT="$auditor" "$probe" open "$old" open "$new" call "$foreign" "$driver"
expect 620 env LD_AUDIT="$auditor" "$probe" open "$new" open "$old" call "$foreign" "$driver"
expect $'619\n619' env LD_AUDIT="$auditor" "$probe" open "$old" call "$foreign" "$driver" open "$new" call "$foreign" "$driver"
# In stock processes only the library that opens the driver supplies policy.
# Both libraries can already be mapped, in either order, without binding it.
oldClient=$profile/lib/libclient-12.so
newClient=$profile/lib/libclient-13.so
echo 620.70.05 > sys/module/nvidia/version
expect $'615\n615' "$probe" open "$oldClient" open "$newClient" absent "$driver" call "$oldClient" "$driver" call "$newClient" "$driver"
expect $'620\n620' "$probe" open "$oldClient" open "$newClient" absent "$driver" call "$newClient" "$driver" call "$oldClient" "$driver"
echo 610.1 > sys/module/nvidia/version
expect 619 "$output/bin/direct"
expect 619 env LD_AUDIT="$auditor" "$probe" open "$runtime" call "$foreign" "$driver"
expect 615 env LD_AUDIT="$auditor" "$probe" open "$new" call "$foreign" "$driver"
expect 615 "$probe" call "$runtime" "$driver"

# Importing the Python adapter leaves the provider unbound until its first call.
for entry in 615.71.09:620 625.1:615; do
    printf '%s\n' "${entry%:*}" > sys/module/nvidia/version
    expect "${entry#*:}" "${PYTHON:-python3}" -I -c '
import ctypes, runpy, sys
from pathlib import Path
load = runpy.run_path(sys.argv[1])["load_driver"]
assert "libcuda.so." not in Path("/proc/self/maps").read_text()
print(ctypes.c_int.in_dll(load(), "fixture_id").value)' "$output/driver.py"
done

# A later auditor can retain the selected name after both drivers have unloaded.
expect '' env -u LD_LIBRARY_PATH LD_AUDIT="$auditor:$mocks/control/retaining-auditor.so" \
    "$mocks/control/retained-path" "$runtime"
