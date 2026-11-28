use super::*;

#[test]
fn version_has_two_or_three_unsigned_decimal_components() {
    assert_eq!(policy::version(b"620.070.06", true), Some([620, 70, 6]));
    assert_eq!(policy::version(b"620.70", false), Some([620, 70, 0]));
    for bad in [
        b"620.70".as_slice(),
        b"+620.70.6",
        b"620.4294967296.6",
        b"620.70.6.0",
    ] {
        assert_eq!(policy::version(bad, true), None);
    }
}
#[test]
fn malformed_branch_after_a_matching_branch_rejects_provider() {
    let body = b"620.70.6\n615 broken\n/r/compat/libcuda.so.620.70.06\n";
    assert!(policy::eligible(b"/r", body, [615, 0, 0]).is_none());
}
#[test]
fn selected_provider_belongs_to_same_output_and_is_strictly_newer() {
    let body = b"620.70.6\n615 620\n/r/compat/libcuda.so.620.70.06\n";
    assert_eq!(
        policy::eligible(b"/r", body, [615, 1, 0]).unwrap().0,
        [620, 70, 6]
    );
    assert!(policy::eligible(b"/r", body, [620, 70, 6]).is_none());
    assert!(policy::eligible(b"/other", body, [615, 0, 0]).is_none());
    assert!(policy::eligible(b"/r", &body[..body.len() - 1], [615, 0, 0]).is_none());
}
#[test]
fn filename_suffix_accepts_only_nonempty_decimal_components() {
    assert!(host::library(b"libcuda.so", b"libcuda.so"));
    assert!(host::library(b"libcuda.so.1.01", b"libcuda.so"));
    for name in [
        b"libcuda.so.".as_slice(),
        b"libcuda.so.1.",
        b"libcuda.so..1",
        b"libcuda.soX",
        b"libcuda.so.+1",
    ] {
        assert!(!host::library(name, b"libcuda.so"));
    }
}
#[test]
fn composed_names_preserve_raw_bytes_and_enforce_the_c_string_contract() {
    assert_eq!(
        join_path(&[b"/lib/", b"\xff"])
            .unwrap()
            .as_c_str()
            .to_bytes(),
        b"/lib/\xff"
    );
    assert!(join_path(&[b"a\0b"]).is_none());
    assert!(join_path(&[&[1; 4096]]).is_none());
}
#[test]
fn registry_shares_a_key_only_within_its_namespace_and_drops_the_last_owner() {
    let mut s = State::EMPTY;
    let mut open = |ns| s.register(ns, None, join_path(&[b"/index"])).unwrap();
    let a = open(0);
    let b = open(0);
    let other = open(7);
    assert_eq!(a, b);
    assert_ne!(a, other);
    s.close(a);
    assert_eq!(s.entries[a / 2 - 1].as_ref().unwrap().users, 1);
    s.close(b);
    assert!(s.entries[a / 2 - 1].is_none());
    s.close(other);
    assert_eq!(s.entries.capacity(), 0);
}
#[test]
fn interned_names_retain_their_address_across_table_growth() {
    let mut s = State::EMPTY;
    let saved = s.keep(join_path(&[b"first"]).unwrap()).unwrap();
    for i in 1..=200 {
        s.keep(join_path(&[&[i]]).unwrap()).unwrap();
    }
    assert_eq!(s.keep(join_path(&[b"first"]).unwrap()), Some(saved));
}

#[test]
fn overlapping_callbacks_disable_future_lookups_and_preserve_returned_names() {
    extern crate std;
    use std::sync::Barrier;
    let registry = Global::new();
    let name = registry
        .with(|s| s.keep(join_path(&[b"/retained"])?))
        .unwrap();
    let cookie = registry
        .with(|s| s.register(0, None, join_path(&[b"/index"])))
        .unwrap();
    let rendezvous = Barrier::new(2);
    std::thread::scope(|scope| {
        let worker = scope.spawn(|| {
            registry.with(|_| {
                rendezvous.wait();
                rendezvous.wait();
                Some(())
            })
        });
        rendezvous.wait();
        assert!(
            registry
                .with(|s| {
                    s.close(cookie);
                    Some(())
                })
                .is_none()
        );
        rendezvous.wait();
        assert!(worker.join().unwrap().is_none());
    });
    assert!(registry.with(|_| Some(())).is_none());
    assert_eq!(unsafe { CStr::from_ptr(name) }, c"/retained");
}

#[test]
fn fork_inherits_idle_state_and_fails_open_if_an_owner_did_not_survive() {
    fn child_access(registry: &Global, expect_access: bool) {
        // The child takes only the atomic gate and _exit, with no allocation.
        let pid = unsafe { libc::fork() };
        assert!(pid >= 0);
        if pid == 0 {
            let enabled = registry.with(|_| Some(())).is_some();
            unsafe { libc::_exit(i32::from(enabled != expect_access)) };
        }
        let mut status = 0;
        assert_eq!(unsafe { libc::waitpid(pid, &mut status, 0) }, pid);
        assert_eq!(status, 0);
    }
    let registry = Global::new();
    child_access(&registry, true);
    assert!(
        registry
            .with(|_| {
                child_access(&registry, false);
                Some(())
            })
            .is_some()
    );
    assert!(registry.with(|_| Some(())).is_some());
}
