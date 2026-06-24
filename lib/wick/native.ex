defmodule Wick.Native do
  @moduledoc """
  Low-level transport bindings for the Linux FUSE kernel ABI.

  This module wraps a raw non-blocking file descriptor (either `/dev/fuse`
  in production or one end of a `pipe(2)` pair in tests) in a Rustler
  resource. The following operations are exposed:

    * `open_dev_fuse/0` — open `/dev/fuse`.
    * `pipe_pair/0` — allocate a pipe pair for testing against hosts
      without FUSE support.
    * `select_read/1` — arm a single read-readiness notification; the
      owning process receives
      `{:select, handle, :undefined, :ready_input}` when the fd is
      readable. Must be re-armed after each notification.
    * `read_frame/1` / `write_frame/2` — non-blocking `read(2)` /
      `write(2)` of a bounded frame (up to 128 KiB — the FUSE kernel
      `max_write`).
    * `fusermount3_mount/2` — invoke the `fusermount3` helper to mount a
      FUSE filesystem and return the resulting `/dev/fuse` fd as a
      handle. Higher-level callers should use `Wick.Fusermount`,
      which also covers unmount.

  The fd is owned by the resource and closed when the last Erlang
  reference is released. Errors surface as `{:error, atom}` tuples using
  the POSIX errno atoms declared in `t:error/0`.

  This module owns the `enif_select` integration; higher-level FUSE
  protocol handling (opcode dispatch, INIT handshake, backend callbacks)
  lives elsewhere in the future `Wick` supervision tree.
  """

  use Rustler,
    otp_app: :wick,
    crate: :wick

  @typedoc """
  Opaque handle wrapping a non-blocking file descriptor. The fd is closed
  when the last Erlang reference is released.
  """
  @type handle :: reference()

  @typedoc """
  Error atoms returned by the transport NIFs. `:eagain` means the fd is
  not currently ready — re-arm via `select_read/1` and wait for the
  `{:select, handle, :undefined, :ready_input}` message.

  `:fusermount_no_fd` means the `fusermount3` helper exited without
  sending a `/dev/fuse` fd back over the SCM_RIGHTS socket (typically
  because the mount point does not exist or the kernel rejected the
  options); `:fusermount_failed` means the helper sent something
  unexpected on the control channel.
  """
  @type error ::
          :eagain
          | :eintr
          | :einval
          | :enodev
          | :enoent
          | :enomem
          | :enosys
          | :eperm
          | :epipe
          | :fusermount_failed
          | :fusermount_no_fd
          | :select_already_closed
          | :select_failed
          | :select_not_supported

  @doc """
  Open `/dev/fuse` with `O_RDWR | O_NONBLOCK | O_CLOEXEC` and return a
  resource handle owning the fd.
  """
  @spec open_dev_fuse() :: {:ok, handle()} | {:error, error()}
  def open_dev_fuse, do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Allocate a non-blocking `pipe(2)` pair wrapped in the same resource
  type. Primarily a test aid so the select / read / write path can be
  exercised on hosts without FUSE support.

  Returns `{:ok, {read_handle, write_handle}}`.
  """
  @spec pipe_pair() :: {:ok, {handle(), handle()}} | {:error, error()}
  def pipe_pair, do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Allocate a non-blocking `socketpair(AF_UNIX, SOCK_STREAM)` pair —
  bidirectional ends suitable for end-to-end testing of the kernel ↔
  Session FUSE protocol from BEAM (one end fed synthetic kernel
  frames, the other passed to a session process).

  Returns `{:ok, {a, b}}` where each end can be both read and written.
  """
  @spec socketpair_stream() :: {:ok, {handle(), handle()}} | {:error, error()}
  def socketpair_stream, do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Arm a single read-readiness notification for `handle`. The calling
  process receives `{:select, handle, :undefined, :ready_input}` when
  the fd becomes readable. The registration is consumed on delivery and
  must be re-armed after each notification.
  """
  @spec select_read(handle()) :: :ok | {:error, error()}
  def select_read(_handle), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Perform a single non-blocking `read(2)` and return the bytes read.
  Returns `{:error, :eagain}` if the fd is not currently readable — in
  that case, re-arm via `select_read/1`.

  The returned binary is bounded at 128 KiB (the FUSE kernel
  `max_write`), which is a protocol-defined ceiling, not a scaling bound
  — so this is not a whole-file-buffering violation.
  """
  @spec read_frame(handle()) :: {:ok, binary()} | {:error, error()}
  def read_frame(_handle), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Perform a single non-blocking `write(2)` of a complete frame. Returns
  `{:error, :eagain}` on a short write.
  """
  @spec write_frame(handle(), binary()) :: :ok | {:error, error()}
  def write_frame(_handle, _frame), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Spawn `fusermount3 -o <options> -- <mount_point>`, receive the
  resulting `/dev/fuse` fd over the helper's `SCM_RIGHTS` socket, and
  return it wrapped in a handle.

  `options` is the comma-joined argument expected by `fusermount3 -o`
  (for example `"allow_other,max_read=131072"`). Pass an empty string
  for no options. The caller is responsible for joining individual
  options — this NIF performs no parsing.

  Spawning happens via `posix_spawn(3)` rather than an Erlang `Port` so
  that one end of a parent-allocated `socketpair(2)` can be inherited
  in the child as fd 3 (where `fusermount3` looks for it via the
  `_FUSE_COMMFD` environment variable). Erlang `Port`-based spawn
  cannot pass arbitrary file descriptors to a child.

  The helper is short-lived: it opens `/dev/fuse`, sends the fd back
  via `SCM_RIGHTS`, and exits. The BEAM auto-reaps the child via its
  `SIGCHLD = SIG_IGN` disposition, so this function does not call
  `waitpid(2)`. A `fusermount3` failure surfaces as
  `{:error, :fusermount_no_fd}` (the helper closed the control socket
  without sending anything).
  """
  @spec fusermount3_mount(mount_point :: String.t(), options :: String.t()) ::
          {:ok, handle()} | {:error, error()}
  def fusermount3_mount(_mount_point, _options), do: :erlang.nif_error(:nif_not_loaded)
end
