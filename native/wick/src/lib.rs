//! FUSE transport NIF.
//!
//! This crate owns a raw file descriptor (either `/dev/fuse` in production or
//! one end of a `pipe(2)` pair in tests) and exposes the following operations
//! to Elixir via `Wick.Native`:
//!
//! * `open_dev_fuse/0` — open `/dev/fuse`.
//! * `pipe_pair/0` — allocate a pipe pair (test aid so the CI image does not
//!   need FUSE support).
//! * `select_read/1` — arm a single read-readiness notification via
//!   `enif_select`; the owning process receives a `{select, Resource, Ref,
//!   ready_input}` message when the fd is readable.
//! * `read_frame/1` / `write_frame/2` — non-blocking `read(2)` / `write(2)`
//!   against the fd. Each frame is bounded at 128 KiB (the FUSE protocol's
//!   `max_write`), so a single syscall always returns a complete
//!   request/response — a protocol-bounded read, not a whole-file-buffering
//!   concern.
//! * `fusermount3_mount/2` — invoke the `fusermount3` helper to mount a FUSE
//!   filesystem at `mount_point` with `options`, receive the resulting
//!   `/dev/fuse` fd over a `SCM_RIGHTS` Unix socket, and wrap it as a
//!   `FuseFd` resource. Spawning happens via `posix_spawn(3)` so the
//!   socketpair is inherited as fd 3 in the child — Erlang `Port`-based
//!   spawn cannot pass arbitrary fds to a child. The child is reaped
//!   automatically by the BEAM's `SIGCHLD = SIG_IGN` disposition; success is
//!   signalled by receipt of the fd, failure by EOF on the socket.
//!
//! Rustler 0.37 does not wrap `enif_select`, and the safe `Resource` trait
//! does not let us install a stop callback. Without a stop callback we cannot
//! close the fd safely after tearing down a select registration. We therefore
//! register the resource type by hand via `enif_open_resource_type_x` at NIF
//! load time, installing both a destructor and a stop callback. All the
//! unsafe glue is localised to this file.

use rustler::sys::{
    enif_alloc_resource, enif_get_resource, enif_make_resource, enif_open_resource_type_x,
    enif_release_resource, enif_select, enif_self, ErlNifEnv, ErlNifEvent, ErlNifPid,
    ErlNifResourceFlags, ErlNifResourceType, ErlNifResourceTypeInit, ERL_NIF_SELECT_FAILED,
    ERL_NIF_SELECT_NOTSUP, ERL_NIF_SELECT_READ, ERL_NIF_SELECT_STOP,
};
use rustler::types::atom::{self, Atom};
use rustler::{Binary, Encoder, Env, Error as NifError, NewBinary, NifResult, Term};
use std::ffi::{c_void, CString};
use std::mem;
use std::os::raw::{c_char, c_int};
use std::ptr;
use std::sync::atomic::{AtomicI32, AtomicPtr, Ordering};

mod atoms {
    rustler::atoms! {
        eagain,
        eintr,
        einval,
        enodev,
        enoent,
        enomem,
        enosys,
        eperm,
        epipe,
        fusermount_failed,
        fusermount_no_fd,
        select_already_closed,
        select_failed,
        select_not_supported,
    }
}

/// Opaque resource holding an owned fd.
///
/// The fd is stored in an `AtomicI32` so the destructor and the stop callback
/// (which can run on different threads) can observe/transition it without a
/// data race. A value of `-1` means "closed".
#[repr(C)]
pub struct FuseFd {
    fd: AtomicI32,
}

/// Registered resource type, populated once in [`on_load`].
static RESOURCE_TYPE: AtomicPtr<ErlNifResourceType> = AtomicPtr::new(ptr::null_mut());

fn on_load(env: Env, _info: Term) -> bool {
    let init = ErlNifResourceTypeInit {
        dtor: fuse_fd_dtor as *const _,
        stop: fuse_fd_stop as *const _,
        down: ptr::null(),
        members: 2,
        dyncall: ptr::null(),
    };

    let name = c"FuseFd";
    let rt = unsafe {
        enif_open_resource_type_x(
            env.as_c_arg(),
            name.as_ptr() as *const c_char,
            &init,
            ErlNifResourceFlags::ERL_NIF_RT_CREATE,
            ptr::null_mut(),
        )
    };

    if rt.is_null() {
        return false;
    }

    RESOURCE_TYPE.store(rt as *mut _, Ordering::SeqCst);
    true
}

fn resource_type() -> *const ErlNifResourceType {
    RESOURCE_TYPE.load(Ordering::SeqCst) as *const _
}

/// Destructor invoked by the runtime when the last Erlang reference is
/// dropped. Schedules a stop via `enif_select`; the stop callback then closes
/// the fd.
unsafe extern "C" fn fuse_fd_dtor(env: *mut ErlNifEnv, obj: *mut c_void) {
    let resource = &*(obj as *const FuseFd);
    let fd = resource.fd.load(Ordering::SeqCst);
    if fd < 0 {
        return;
    }

    // `enif_select` with SELECT_STOP queues the stop callback. The stop
    // callback is responsible for the actual `close(2)`. Atoms are not
    // associated with an env, so we can pass `:undefined` by raw term here.
    let undefined = atom::undefined().as_c_arg();
    let _ = enif_select(
        env,
        fd as ErlNifEvent,
        ERL_NIF_SELECT_STOP,
        obj,
        ptr::null(),
        undefined,
    );
}

/// Stop callback invoked after the select registration is torn down. Safe to
/// close the fd now — no scheduler thread is still polling it.
unsafe extern "C" fn fuse_fd_stop(
    _env: *mut ErlNifEnv,
    obj: *mut c_void,
    _event: ErlNifEvent,
    _is_direct_call: c_int,
) {
    let resource = &*(obj as *const FuseFd);
    let fd = resource.fd.swap(-1, Ordering::SeqCst);
    if fd >= 0 {
        libc::close(fd);
    }
}

/// Return an `{:error, atom}` tuple from the NIF.
fn err_term(a: Atom) -> NifError {
    NifError::Term(Box::new(a))
}

/// Decode a resource term into a raw resource pointer and a reference to the
/// underlying `FuseFd`. We need both: the pointer is the `obj` argument
/// expected by `enif_select`; the reference lets us read the stored fd.
fn get_resource_raw<'a>(env: Env<'a>, term: Term<'a>) -> NifResult<(*const c_void, &'a FuseFd)> {
    let rt = resource_type();
    if rt.is_null() {
        return Err(err_term(atoms::enosys()));
    }

    let mut obj: *const c_void = ptr::null();
    let ok = unsafe { enif_get_resource(env.as_c_arg(), term.as_c_arg(), rt, &mut obj) };
    if ok == 0 || obj.is_null() {
        return Err(err_term(atoms::einval()));
    }

    let resource = unsafe { &*(obj as *const FuseFd) };
    Ok((obj, resource))
}

/// Allocate a new resource wrapping `fd`, hand ownership to the runtime, and
/// return a resource term usable from Elixir. On failure, closes `fd`.
fn make_resource(env: Env, fd: c_int) -> NifResult<Term> {
    let rt = resource_type();
    if rt.is_null() {
        unsafe { libc::close(fd) };
        return Err(err_term(atoms::enosys()));
    }

    let obj = unsafe { enif_alloc_resource(rt, std::mem::size_of::<FuseFd>()) };
    if obj.is_null() {
        unsafe { libc::close(fd) };
        return Err(err_term(atoms::enosys()));
    }

    // Initialise the struct in-place. `enif_alloc_resource` returns
    // uninitialised memory; `ptr::write` avoids dropping whatever happens to
    // be there.
    unsafe {
        ptr::write(
            obj as *mut FuseFd,
            FuseFd {
                fd: AtomicI32::new(fd),
            },
        );
    }

    let term = unsafe { enif_make_resource(env.as_c_arg(), obj) };
    // The term now owns a reference; drop our local refcount.
    unsafe { enif_release_resource(obj) };

    Ok(unsafe { Term::new(env, term) })
}

fn errno_to_atom(errno: c_int) -> Atom {
    match errno {
        libc::EAGAIN => atoms::eagain(),
        libc::EINTR => atoms::eintr(),
        libc::EINVAL => atoms::einval(),
        libc::ENODEV => atoms::enodev(),
        libc::ENOENT => atoms::enoent(),
        libc::EPERM | libc::EACCES => atoms::eperm(),
        libc::EPIPE => atoms::epipe(),
        _ => atoms::enosys(),
    }
}

fn last_errno() -> c_int {
    unsafe { *libc::__errno_location() }
}

#[rustler::nif]
pub fn open_dev_fuse(env: Env) -> NifResult<Term> {
    let path = c"/dev/fuse";
    let flags = libc::O_RDWR | libc::O_NONBLOCK | libc::O_CLOEXEC;
    let fd = unsafe { libc::open(path.as_ptr(), flags) };
    if fd < 0 {
        return Err(err_term(errno_to_atom(last_errno())));
    }

    let resource = make_resource(env, fd)?;
    Ok((atom::ok(), resource).encode(env))
}

#[rustler::nif]
pub fn pipe_pair(env: Env) -> NifResult<Term> {
    let mut fds: [c_int; 2] = [-1, -1];
    let rc = unsafe { libc::pipe2(fds.as_mut_ptr(), libc::O_NONBLOCK | libc::O_CLOEXEC) };
    if rc != 0 {
        return Err(err_term(errno_to_atom(last_errno())));
    }

    let read_term = match make_resource(env, fds[0]) {
        Ok(t) => t,
        Err(e) => {
            unsafe { libc::close(fds[1]) };
            return Err(e);
        }
    };
    let write_term = make_resource(env, fds[1])?;
    Ok((atom::ok(), (read_term, write_term)).encode(env))
}

/// Allocate a `socketpair(AF_UNIX, SOCK_STREAM, ...)` pair with
/// `O_NONBLOCK | O_CLOEXEC` on both ends. Each end is wrapped in the
/// same resource type as `pipe_pair`. Both ends are bidirectional —
/// suitable for testing the full kernel-side ↔ Session protocol
/// against a single `Session` fd. Returns `{:ok, {a, b}}`.
#[rustler::nif]
pub fn socketpair_stream(env: Env) -> NifResult<Term> {
    let mut fds: [c_int; 2] = [-1, -1];
    let rc = unsafe {
        libc::socketpair(
            libc::AF_UNIX,
            libc::SOCK_STREAM | libc::SOCK_NONBLOCK | libc::SOCK_CLOEXEC,
            0,
            fds.as_mut_ptr(),
        )
    };
    if rc != 0 {
        return Err(err_term(errno_to_atom(last_errno())));
    }

    let a_term = match make_resource(env, fds[0]) {
        Ok(t) => t,
        Err(e) => {
            unsafe { libc::close(fds[1]) };
            return Err(e);
        }
    };
    let b_term = make_resource(env, fds[1])?;
    Ok((atom::ok(), (a_term, b_term)).encode(env))
}

#[rustler::nif]
pub fn select_read<'a>(env: Env<'a>, resource: Term<'a>) -> NifResult<Atom> {
    let (obj, dev) = get_resource_raw(env, resource)?;
    let fd = dev.fd.load(Ordering::SeqCst);
    if fd < 0 {
        return Err(err_term(atoms::select_already_closed()));
    }

    let mut pid: ErlNifPid = unsafe { std::mem::zeroed() };
    let pid_ok = unsafe { enif_self(env.as_c_arg(), &mut pid) };
    if pid_ok.is_null() {
        return Err(err_term(atoms::einval()));
    }

    // Pass `:undefined` for the select ref so the default `{select, Resource,
    // Ref, ready_input}` tuple is delivered with Ref = undefined.
    let undefined = atom::undefined().as_c_arg();
    let rc = unsafe {
        enif_select(
            env.as_c_arg(),
            fd as ErlNifEvent,
            ERL_NIF_SELECT_READ,
            obj,
            &pid,
            undefined,
        )
    };

    if rc < 0 {
        return Err(err_term(atoms::select_failed()));
    }
    if rc & ERL_NIF_SELECT_FAILED != 0 {
        return Err(err_term(atoms::select_failed()));
    }
    if rc & ERL_NIF_SELECT_NOTSUP != 0 {
        return Err(err_term(atoms::select_not_supported()));
    }

    Ok(atom::ok())
}

#[rustler::nif]
pub fn read_frame<'a>(env: Env<'a>, resource: Term<'a>) -> NifResult<Term<'a>> {
    let (_obj, dev) = get_resource_raw(env, resource)?;
    let fd = dev.fd.load(Ordering::SeqCst);
    if fd < 0 {
        return Err(err_term(atoms::select_already_closed()));
    }

    // 128 KiB matches the FUSE kernel `max_write` — a single read(2) always
    // returns a whole frame.
    const FRAME_CAP: usize = 128 * 1024;
    let mut buf = vec![0u8; FRAME_CAP];

    let n = unsafe { libc::read(fd, buf.as_mut_ptr() as *mut c_void, FRAME_CAP) };
    if n < 0 {
        return Err(err_term(errno_to_atom(last_errno())));
    }

    let n = n as usize;
    let mut bin = NewBinary::new(env, n);
    bin.as_mut_slice().copy_from_slice(&buf[..n]);
    let binary: Binary = bin.into();
    Ok((atom::ok(), binary.to_term(env)).encode(env))
}

#[rustler::nif]
pub fn write_frame<'a>(env: Env<'a>, resource: Term<'a>, frame: Binary<'a>) -> NifResult<Atom> {
    let (_obj, dev) = get_resource_raw(env, resource)?;
    let fd = dev.fd.load(Ordering::SeqCst);
    if fd < 0 {
        return Err(err_term(atoms::select_already_closed()));
    }

    let data = frame.as_slice();
    let n = unsafe { libc::write(fd, data.as_ptr() as *const c_void, data.len()) };
    if n < 0 {
        return Err(err_term(errno_to_atom(last_errno())));
    }
    if (n as usize) != data.len() {
        // Short writes shouldn't happen for bounded frames on `/dev/fuse` or
        // pipes with buffers ≥ 128 KiB. Surface it as EAGAIN so the caller
        // can re-arm a write-ready notification later.
        return Err(err_term(atoms::eagain()));
    }
    Ok(atom::ok())
}

/// Receive a `/dev/fuse` fd over a `SCM_RIGHTS` Unix socket from `fusermount3`.
///
/// `fusermount3` sends a single byte alongside the cmsg (per `unix(7)` —
/// passing fds requires at least one byte of payload). EOF on the socket
/// (return value 0) means the helper exited without sending the fd, i.e. it
/// failed before the mount succeeded — typically because the mount point was
/// invalid or the kernel rejected the options.
fn recv_fuse_fd(sock: c_int) -> Result<c_int, Atom> {
    let mut payload = [0u8; 1];
    let mut iov = libc::iovec {
        iov_base: payload.as_mut_ptr() as *mut c_void,
        iov_len: payload.len(),
    };

    // CMSG_SPACE(sizeof(int)) is comfortably under 64 bytes on every Linux
    // ABI we run on.
    let mut cmsg_buf = [0u8; 64];
    let mut msg: libc::msghdr = unsafe { mem::zeroed() };
    msg.msg_iov = &mut iov;
    msg.msg_iovlen = 1;
    msg.msg_control = cmsg_buf.as_mut_ptr() as *mut c_void;
    msg.msg_controllen = cmsg_buf.len() as _;

    let n = loop {
        let r = unsafe { libc::recvmsg(sock, &mut msg, 0) };
        if r < 0 && last_errno() == libc::EINTR {
            continue;
        }
        break r;
    };

    if n < 0 {
        return Err(errno_to_atom(last_errno()));
    }
    if n == 0 {
        return Err(atoms::fusermount_no_fd());
    }

    let cmsg = unsafe { libc::CMSG_FIRSTHDR(&msg) };
    if cmsg.is_null() {
        return Err(atoms::fusermount_failed());
    }
    let cmsg_ref = unsafe { &*cmsg };
    if cmsg_ref.cmsg_level != libc::SOL_SOCKET || cmsg_ref.cmsg_type != libc::SCM_RIGHTS {
        return Err(atoms::fusermount_failed());
    }

    let fd_ptr = unsafe { libc::CMSG_DATA(cmsg) } as *const c_int;
    let fd = unsafe { ptr::read_unaligned(fd_ptr) };
    Ok(fd)
}

/// Build the env passed to `fusermount3`: the parent's current environment
/// (snapshot via `std::env::vars_os`) with any pre-existing `_FUSE_COMMFD=`
/// stripped, plus `_FUSE_COMMFD=<commfd>` appended. The returned `CString`s
/// back the pointers passed to `posix_spawnp` and must outlive the call.
fn build_fusermount_env(commfd: c_int) -> Vec<CString> {
    use std::os::unix::ffi::OsStrExt;

    let mut out: Vec<CString> = Vec::new();
    for (key, value) in std::env::vars_os() {
        if key.as_bytes() == b"_FUSE_COMMFD" {
            continue;
        }
        let mut bytes = Vec::with_capacity(key.len() + 1 + value.len());
        bytes.extend_from_slice(key.as_bytes());
        bytes.push(b'=');
        bytes.extend_from_slice(value.as_bytes());
        if let Ok(s) = CString::new(bytes) {
            out.push(s);
        }
    }
    if let Ok(s) = CString::new(format!("_FUSE_COMMFD={}", commfd)) {
        out.push(s);
    }
    out
}

/// Spawn `fusermount3 -o <options> -- <mount_point>`, receive the resulting
/// `/dev/fuse` fd via `SCM_RIGHTS` on a socketpair inherited as fd 3 in the
/// child, and wrap the fd in a `FuseFd` resource.
///
/// `options` is the comma-joined argument to `-o` (the format `fusermount3`
/// itself expects); the caller is responsible for joining individual options.
/// An empty `options` is allowed — `-o` takes an empty string.
#[rustler::nif(schedule = "DirtyIo")]
pub fn fusermount3_mount<'a>(
    env: Env<'a>,
    mount_point: String,
    options: String,
) -> NifResult<Term<'a>> {
    let mount_point_c = CString::new(mount_point).map_err(|_| err_term(atoms::einval()))?;
    let options_c = CString::new(options).map_err(|_| err_term(atoms::einval()))?;

    // Socketpair: AF_UNIX SOCK_STREAM with O_CLOEXEC on both ends. The dup2
    // file action clears O_CLOEXEC on the duplicated fd in the child, so the
    // child sees the socket at fd 3 only. The parent end stays CLOEXEC, so a
    // parallel port-spawn elsewhere in the BEAM cannot inherit it.
    //
    // SOCK_STREAM is preferred over SOCK_DGRAM for this protocol: when the
    // peer (the helper) exits without sending the fd, a stream socket
    // returns 0 (EOF) from `recvmsg`, while a datagram socket would block
    // indefinitely. Both socket types support `SCM_RIGHTS` fd passing —
    // fusermount3 itself just calls `sendmsg(2)`, so the socket type is the
    // parent's choice.
    let mut sockets: [c_int; 2] = [-1, -1];
    let rc = unsafe {
        libc::socketpair(
            libc::AF_UNIX,
            libc::SOCK_STREAM | libc::SOCK_CLOEXEC,
            0,
            sockets.as_mut_ptr(),
        )
    };
    if rc != 0 {
        return Err(err_term(errno_to_atom(last_errno())));
    }
    let parent_fd = sockets[0];
    let child_fd = sockets[1];

    // posix_spawn file actions: dup the child's socket end onto fd 3, where
    // fusermount3 looks for it via the `_FUSE_COMMFD` env var.
    let mut actions: libc::posix_spawn_file_actions_t = unsafe { mem::zeroed() };
    if unsafe { libc::posix_spawn_file_actions_init(&mut actions) } != 0 {
        unsafe {
            libc::close(parent_fd);
            libc::close(child_fd);
        }
        return Err(err_term(atoms::enomem()));
    }

    let cleanup_actions = |actions: &mut libc::posix_spawn_file_actions_t| unsafe {
        libc::posix_spawn_file_actions_destroy(actions);
    };

    if unsafe { libc::posix_spawn_file_actions_adddup2(&mut actions, child_fd, 3) } != 0 {
        cleanup_actions(&mut actions);
        unsafe {
            libc::close(parent_fd);
            libc::close(child_fd);
        }
        return Err(err_term(atoms::einval()));
    }

    // posix_spawn attributes: reset SIGCHLD (and a few other ignorable
    // signals) to SIG_DFL in the child. The BEAM runs with
    // `signal(SIGCHLD, SIG_IGN)`, which is inherited across exec — under
    // SIG_IGN, the kernel auto-reaps children, which makes
    // `fusermount3`'s own `waitpid(2)` against its mount.fuse helper fail
    // with ECHILD ("waitpid: No child processes"). Restoring the default
    // disposition gives the helper a normal POSIX environment.
    let mut attr: libc::posix_spawnattr_t = unsafe { mem::zeroed() };
    if unsafe { libc::posix_spawnattr_init(&mut attr) } != 0 {
        cleanup_actions(&mut actions);
        unsafe {
            libc::close(parent_fd);
            libc::close(child_fd);
        }
        return Err(err_term(atoms::enomem()));
    }

    let cleanup_attr = |attr: &mut libc::posix_spawnattr_t| unsafe {
        libc::posix_spawnattr_destroy(attr);
    };

    let mut sigdef: libc::sigset_t = unsafe { mem::zeroed() };
    unsafe {
        libc::sigemptyset(&mut sigdef);
        libc::sigaddset(&mut sigdef, libc::SIGCHLD);
        libc::sigaddset(&mut sigdef, libc::SIGPIPE);
    }

    if unsafe { libc::posix_spawnattr_setsigdefault(&mut attr, &sigdef) } != 0
        || unsafe { libc::posix_spawnattr_setflags(&mut attr, libc::POSIX_SPAWN_SETSIGDEF as i16) }
            != 0
    {
        cleanup_attr(&mut attr);
        cleanup_actions(&mut actions);
        unsafe {
            libc::close(parent_fd);
            libc::close(child_fd);
        }
        return Err(err_term(atoms::einval()));
    }

    let prog = c"fusermount3";
    let arg_dash_o = c"-o";
    let arg_dashdash = c"--";
    let mut argv: [*mut c_char; 6] = [
        prog.as_ptr() as *mut c_char,
        arg_dash_o.as_ptr() as *mut c_char,
        options_c.as_ptr() as *mut c_char,
        arg_dashdash.as_ptr() as *mut c_char,
        mount_point_c.as_ptr() as *mut c_char,
        ptr::null_mut(),
    ];

    let env_strings = build_fusermount_env(3);
    let mut envp: Vec<*mut c_char> = env_strings
        .iter()
        .map(|s| s.as_ptr() as *mut c_char)
        .collect();
    envp.push(ptr::null_mut());

    let mut pid: libc::pid_t = 0;
    let spawn_rc = unsafe {
        libc::posix_spawnp(
            &mut pid,
            prog.as_ptr(),
            &actions,
            &attr,
            argv.as_mut_ptr(),
            envp.as_mut_ptr(),
        )
    };

    cleanup_attr(&mut attr);
    cleanup_actions(&mut actions);
    // The parent never reads or writes the child's socket end.
    unsafe { libc::close(child_fd) };

    if spawn_rc != 0 {
        unsafe { libc::close(parent_fd) };
        return Err(err_term(errno_to_atom(spawn_rc)));
    }

    // The child is auto-reaped by the BEAM (SIGCHLD = SIG_IGN). We rely on
    // EOF over the socket, not waitpid, to detect a fusermount3 failure.
    let recv_result = recv_fuse_fd(parent_fd);
    unsafe { libc::close(parent_fd) };

    match recv_result {
        Ok(fuse_fd) => {
            let term = make_resource(env, fuse_fd)?;
            Ok((atom::ok(), term).encode(env))
        }
        Err(a) => Err(err_term(a)),
    }
}

rustler::init!("Elixir.Wick.Native", load = on_load);
