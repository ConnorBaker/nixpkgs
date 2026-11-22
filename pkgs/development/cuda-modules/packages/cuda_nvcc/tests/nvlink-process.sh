cp "$nvlinkWrapper" nvlink
cp "$fakeNvlink" .nvlink-wrapped
chmod +w nvlink
chmod +x .nvlink-wrapped
patchShebangs .nvlink-wrapped
mkdir alone
cp nvlink alone/nvlink
export FAKE_LOG=$PWD/log

status() { "$@" && echo 0 || echo $?; }
signal() { python3 -P "$signalHelper" "$@"; }
expect() {
  if [[ $1 != "$2" ]]; then
    nixErrorLog "$3: expected $2, got $1"
    exit 1
  fi
}

# Exit statuses, arguments, and the environment are passed through.
expect "$(FAKE=exit FAKE_STATUS=3 status ./nvlink)" 3 "nvlink's exit status"
FAKE=exit FAKE_STATUS=0 FAKE_ENV="a b" ./nvlink "x y" ""
# Outside the foreground of a terminal, as here, nvlink runs in a process group of its own.
expect "$(cat log)" $'x y\n\nFAKE_ENV=a b\npid='"$(sed -n 's/^pid=//p' log)"$'\ngroup=own' \
  "nvlink's arguments, environment, and process group"
FAKE=exit FAKE_STATUS=0 ./nvlink -L -o
FAKE=exit FAKE_STATUS=0 ./nvlink -L -optf
FAKE=exit FAKE_STATUS=0 ./nvlink -o unused --version
[[ ! -e unused ]]
expect "$(status ./alone/nvlink)" 127 "the exit status without .nvlink-wrapped next to the wrapper"
# The wrapper finds nvlink next to itself rather than to the link it was run through.
mkdir linked
ln -s ../nvlink linked/nvlink
expect "$(FAKE=exit FAKE_STATUS=4 status ./linked/nvlink)" 4 "nvlink's exit status through a symbolic link"
# The wrapper forwards SIGTERM rather than exiting, so the timeout kills it.
ignoringSigchld='import os, signal, sys; signal.signal(signal.SIGCHLD, signal.SIG_IGN); os.execv(sys.argv[1], sys.argv[1:])'
expect "$(FAKE=exit FAKE_STATUS=3 status timeout -s KILL 60 python3 -c "$ignoringSigchld" ./nvlink)" 3 \
  "nvlink's exit status with SIGCHLD ignored, which is inherited"

# If nvlink is killed by a signal, so is the wrapper.
expect "$(FAKE=kill FAKE_SIGNAL=TERM signal none - ./nvlink)" -15 "how the wrapper exits when nvlink is killed"

# Signals sent to the wrapper, or to its process group, are forwarded to nvlink once.
for sig in HUP INT QUIT TERM USR1 USR2 group:TERM group:USR1; do
  rm -f log*
  expect "$(FAKE="wait" signal "$sig" log.ready ./nvlink)" 0 "the exit status after $sig"
  expect "$(grep -c "received ${sig#group:}" log)" 1 "$sig received by nvlink"
done
# In the foreground of a terminal, nvlink shares the wrapper's process group, so signals from the terminal reach
# it directly, and aren't forwarded.
rm -f log*
expect "$(FAKE="wait" signal ctrl-c log.ready ./nvlink)" 0 "the exit status after Ctrl-C"
expect "$(grep -c "received INT" log)" 1 "SIGINT received by nvlink after Ctrl-C"
expect "$(sed -n 's/^group=//p' log)" shared "nvlink's process group in the foreground of a terminal"
rm -f log*
expect "$(FAKE=detached signal ctrl-c log.ready ./nvlink)" 0 "the exit status after Ctrl-C"
expect "$(grep -c "received INT" log || true)" 0 "SIGINT forwarded to nvlink after Ctrl-C"

# nvlink doesn't outlive the wrapper.
rm -f log*
expect "$(FAKE="sleep" signal KILL log.ready ./nvlink)" -9 "how the wrapper exits when killed"
for _ in $(seq 50); do
  kill -0 "$(sed -n 's/^pid=//p' log)" 2> /dev/null || break
  sleep 0.1
done
if kill -0 "$(sed -n 's/^pid=//p' log)" 2> /dev/null; then
  nixErrorLog "nvlink outlived the wrapper"
  exit 1
fi
