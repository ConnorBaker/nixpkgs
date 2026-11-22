use crate::arguments::{Argument, Arguments, RewrittenArgs};
use crate::files::{Artifact, GeneratedFile};
use libc::{SIGCHLD, SIGHUP, SIGINT, SIGPIPE, SIGQUIT, SIGTERM, SIGUSR1, SIGUSR2};
use std::env;
use std::ffi::{OsStr, OsString};
use std::fs::{self, File, OpenOptions};
use std::io;
use std::mem::MaybeUninit;
use std::os::fd::AsRawFd;
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::os::unix::fs::OpenOptionsExt;
use std::os::unix::process::{CommandExt, ExitStatusExt};
use std::path::PathBuf;
use std::process::{Command, ExitCode, ExitStatus};
use std::sync::atomic::{AtomicU8, Ordering};

const IGNORE_SIGPIPE: u8 = 1 << 3;
static INVOCATION: AtomicU8 = AtomicU8::new(0);

// Capture the caller's state before Rust fills closed standard descriptors
// and sets its own SIGPIPE policy.
#[used]
#[unsafe(link_section = ".init_array")]
static SAVE_INVOCATION: extern "C" fn() = save_invocation;

extern "C" fn save_invocation() {
    let mut state = 0;
    for fd in 0..=libc::STDERR_FILENO {
        // SAFETY: F_GETFD takes no third argument and does not modify fd.
        if unsafe { libc::fcntl(fd, libc::F_GETFD) } < 0 {
            state |= 1 << fd;
        }
    }
    let mut action = MaybeUninit::<libc::sigaction>::zeroed();
    // SAFETY: sigaction initializes the output on success. A null input queries the current action.
    if unsafe { libc::sigaction(SIGPIPE, std::ptr::null(), action.as_mut_ptr()) } == 0
        && unsafe { action.assume_init().sa_sigaction } == libc::SIG_IGN
    {
        state |= IGNORE_SIGPIPE;
    }
    INVOCATION.store(state, Ordering::Relaxed);
}

pub struct Tool {
    name: &'static str,
    pub args: Arguments,
    argv0: OsString,
    vendor: PathBuf,
}

impl Tool {
    fn new(name: &'static str) -> io::Result<Self> {
        let executable = fs::read_link("/proc/self/exe")?;
        let mut args = env::args_os();
        let argv0 = args.next().unwrap_or_else(|| OsString::from(name));
        Ok(Self {
            name,
            args: args.map(OsStringExt::into_vec).collect(),
            argv0,
            vendor: executable.with_file_name(format!(".{name}-wrapped")),
        })
    }

    pub fn command(&self, args: &[Argument]) -> Command {
        let mut command = Command::new(&self.vendor);
        command.arg0(&self.argv0);
        command.args(args.iter().map(|arg| OsStr::from_bytes(arg)));
        let state = INVOCATION.load(Ordering::Relaxed);
        if state != 0 {
            // SAFETY: close and signal are async-signal-safe. These descriptors
            // were closed in the caller, and the wrapper installs no stdio pipes.
            unsafe {
                command.pre_exec(move || {
                    for fd in 0..=libc::STDERR_FILENO {
                        if state & (1 << fd) != 0 {
                            libc::close(fd);
                        }
                    }
                    // Command resets SIGPIPE before calling this hook. exec
                    // normally preserves an inherited SIG_IGN disposition.
                    if state & IGNORE_SIGPIPE != 0
                        && libc::signal(SIGPIPE, libc::SIG_IGN) == libc::SIG_ERR
                    {
                        return Err(io::Error::last_os_error());
                    }
                    Ok(())
                });
            }
        }
        command
    }

    pub fn use_installed_name(&mut self) {
        self.argv0 = self.vendor.with_file_name(self.name).into_os_string();
    }

    fn launch_failed(&self, error: io::Error) -> i32 {
        eprintln!(
            "{} wrapper: error: exec {}: {error}",
            self.name,
            self.vendor.display()
        );
        127
    }

    pub fn exec(&self, mut command: Command) -> i32 {
        self.launch_failed(command.exec())
    }

    pub fn exec_rewritten(&self, rewritten: Option<RewrittenArgs>) -> i32 {
        let args = rewritten.as_ref().map_or(&self.args, |result| &result.args);
        self.exec(self.command(args))
    }

    pub fn run(&self, mut command: Command, lease: Option<&File>) -> io::Result<ExitStatus> {
        let mask = SignalMask::block()?;
        let foreground = in_foreground();
        if !foreground {
            command.process_group(0);
        }
        let original = mask.original;
        let original_child = mask.original_child;
        let parent = std::process::id() as libc::pid_t;
        let lease = lease.map(AsRawFd::as_raw_fd);
        // SAFETY: the closure uses only async-signal-safe system calls and
        // constructs errors from errno. Captured descriptors stay open until spawn returns.
        unsafe {
            command.pre_exec(move || {
                check(libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGKILL))?;
                if libc::getppid() != parent {
                    libc::_exit(127);
                }
                if let Some(lease) = lease {
                    // Keep the open file description alive without using stdio.
                    check(libc::fcntl(lease, libc::F_DUPFD, libc::STDERR_FILENO + 1))?;
                }
                restore_signals(&original, &original_child)
            });
        }
        let mut child = match command.spawn() {
            Ok(child) => child,
            Err(error) => {
                return Ok(ExitStatus::from_raw(self.launch_failed(error) << 8));
            }
        };
        let pid = child.id() as libc::pid_t;
        loop {
            if let Some(status) = child.try_wait()? {
                return Ok(status);
            }
            let mut info = MaybeUninit::<libc::siginfo_t>::zeroed();
            // SAFETY: the signal set is blocked and sigwaitinfo initializes info
            // on success. The child is in its requested process group after spawn.
            unsafe {
                let signal = libc::sigwaitinfo(&mask.watched, info.as_mut_ptr());
                if signal < 0 {
                    let error = io::Error::last_os_error();
                    if error.kind() == io::ErrorKind::Interrupted {
                        continue;
                    }
                    return Err(error);
                }
                if signal != SIGCHLD
                    && (!foreground || info.assume_init().si_code != libc::SI_KERNEL)
                {
                    libc::kill(if foreground { pid } else { -pid }, signal);
                }
            }
        }
    }

    pub fn edit_output(
        &self,
        command: Command,
        output: PathBuf,
        edit: impl FnOnce(&mut Artifact<'_>) -> io::Result<()>,
    ) -> io::Result<i32> {
        let output = GeneratedFile::new(output)?;
        let status = exit_status(self.run(command, None)?);
        if status == 0 {
            output.edit(self.name, edit)?;
        }
        Ok(status)
    }
}

pub fn wrapper_main(name: &'static str, wrapper: impl FnOnce(Tool) -> io::Result<i32>) -> ExitCode {
    match Tool::new(name).and_then(wrapper) {
        Ok(code) => ExitCode::from(code as u8),
        Err(error) => {
            eprintln!("{name} wrapper: error: {error}");
            ExitCode::FAILURE
        }
    }
}

struct SignalMask {
    watched: libc::sigset_t,
    original: libc::sigset_t,
    original_child: libc::sigaction,
}

impl SignalMask {
    fn block() -> io::Result<Self> {
        // SAFETY: All-zero sigset_t storage is valid for both libc targets.
        // Zero original before the kernel writes its (possibly smaller) mask.
        unsafe {
            let mut watched = std::mem::zeroed();
            let mut original = std::mem::zeroed();
            libc::sigemptyset(&mut watched);
            for signal in [SIGHUP, SIGINT, SIGQUIT, SIGTERM, SIGUSR1, SIGUSR2, SIGCHLD] {
                libc::sigaddset(&mut watched, signal);
            }
            check(libc::sigprocmask(libc::SIG_BLOCK, &watched, &mut original))?;
            // SIG_IGN or SA_NOCLDWAIT inherited by the supervisor would
            // cause the kernel to reap the vendor before we can wait for it.
            let mut action: libc::sigaction = std::mem::zeroed();
            action.sa_sigaction = libc::SIG_DFL;
            libc::sigemptyset(&mut action.sa_mask);
            let mut original_child = std::mem::zeroed();
            if let Err(error) = check(libc::sigaction(SIGCHLD, &action, &mut original_child)) {
                libc::sigprocmask(libc::SIG_SETMASK, &original, std::ptr::null_mut());
                return Err(error);
            }
            Ok(Self {
                watched,
                original,
                original_child,
            })
        }
    }
}

impl Drop for SignalMask {
    fn drop(&mut self) {
        let _ = restore_signals(&self.original, &self.original_child);
    }
}

fn restore_signals(mask: &libc::sigset_t, child: &libc::sigaction) -> io::Result<()> {
    // SAFETY: SignalMask saved both values before changing them.
    unsafe {
        let action = check(libc::sigaction(SIGCHLD, child, std::ptr::null_mut()));
        let mask = check(libc::sigprocmask(
            libc::SIG_SETMASK,
            mask,
            std::ptr::null_mut(),
        ));
        action.and(mask)
    }
}

fn check(result: libc::c_int) -> io::Result<()> {
    if result < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(())
    }
}

fn in_foreground() -> bool {
    OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOCTTY)
        .open("/dev/tty")
        // SAFETY: the open file descriptor stays valid for the call.
        .is_ok_and(|tty| unsafe { libc::tcgetpgrp(tty.as_raw_fd()) == libc::getpgrp() })
}

pub fn exit_status(status: ExitStatus) -> i32 {
    if let Some(signal) = status.signal() {
        // SAFETY: status supplies a valid signal number.
        unsafe {
            libc::signal(signal, libc::SIG_DFL);
            let mut only = std::mem::zeroed();
            libc::sigemptyset(&mut only);
            libc::sigaddset(&mut only, signal);
            libc::sigprocmask(libc::SIG_UNBLOCK, &only, std::ptr::null_mut());
            libc::raise(signal);
        }
        return 128 + signal;
    }
    status.code().unwrap_or(1)
}
