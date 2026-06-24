defmodule Wick.Fusermount do
  @moduledoc """
  Mount and unmount FUSE filesystems via the `fusermount3` helper.

  The Linux FUSE kernel ABI requires a userspace helper for unprivileged
  mounts: a setuid `fusermount3` binary opens `/dev/fuse`, performs the
  `mount(2)` syscall on behalf of the caller, and returns the resulting
  fd over a `SCM_RIGHTS` Unix socket. This module wraps that protocol.

  ## Mount

  `mount/2` invokes `fusermount3` via `Wick.Native.fusermount3_mount/2`
  and returns the handle wrapping the FUSE fd, ready to use with
  `Wick.Native.select_read/1`, `read_frame/1` and `write_frame/2`.

  ## Unmount

  `unmount/1` invokes `fusermount3 -u <mount_point>` via an Erlang
  `Port` so that the BEAM's child-process management (through
  `erl_child_setup`) reaps the helper without colliding with
  `SIGCHLD = SIG_IGN`. The fuser crate's direct `fusermount3` invocation
  is broken under the BEAM for exactly this reason — see the parent
  epic (#107) for context.

  ## Example

      {:ok, handle} =
        Wick.Fusermount.mount(
          "/tmp/my-mount",
          ["fsname=wick", "subtype=wick", "default_permissions"]
        )

      # ... use the handle to drive the FUSE protocol ...

      :ok = Wick.Fusermount.unmount("/tmp/my-mount")

  ## Options

  `mount/2` accepts options as a list of strings; they are joined with
  `,` and passed as a single argument to `fusermount3 -o`. Each option
  is either a flag (`"allow_other"`) or a `key=value` pair
  (`"max_read=131072"`). The list may be empty, in which case
  `fusermount3` is invoked with `-o ""`, accepting only the kernel
  defaults. No validation is performed here — invalid options surface
  as `{:error, :fusermount_no_fd}` from the helper.
  """

  alias Wick.Native

  @typedoc """
  Errors returned by `mount/2` and `unmount/1`.

  Mount errors are the union of `t:Wick.Native.error/0`. Unmount
  errors include `:timeout` if the helper does not exit within the
  configured window, and `{:fusermount, status}` if it exits with a
  non-zero status (typically because the mount point is not currently
  mounted, or the user lacks permission).
  """
  @type error ::
          Native.error()
          | :timeout
          | {:fusermount, non_neg_integer()}

  @typedoc """
  Mount option list. Each entry is a string in the form `"flag"` or
  `"key=value"`, matching the format accepted by `fusermount3 -o`.
  """
  @type options :: [String.t()]

  @typedoc """
  Options accepted by `unmount/2`.

    * `:lazy` (boolean, default `false`) — pass `-z` to `fusermount3`,
      requesting `MNT_DETACH` semantics. The mount is removed from the
      namespace immediately and finalised once all open file
      descriptors against it close. Use this when the caller cannot
      guarantee the FUSE fd has been closed before unmounting.
    * `:timeout` (positive integer, default `5_000`) — milliseconds to
      wait for `fusermount3` to exit before returning
      `{:error, :timeout}`.
  """
  @type unmount_opts :: [{:lazy, boolean()} | {:timeout, pos_integer()}]

  @default_unmount_timeout 5_000

  @doc """
  Mount a FUSE filesystem at `mount_point` with the given `options` and
  return a handle wrapping the `/dev/fuse` fd.

  See the module documentation for the option format.
  """
  @spec mount(mount_point :: String.t(), options()) ::
          {:ok, Native.handle()} | {:error, Native.error()}
  def mount(mount_point, options \\ []) when is_binary(mount_point) and is_list(options) do
    Native.fusermount3_mount(mount_point, Enum.join(options, ","))
  end

  @doc """
  Unmount the FUSE filesystem at `mount_point` by invoking
  `fusermount3 -u`.

  See `t:unmount_opts/0` for the supported options. With the defaults
  this performs a regular `umount(2)`, which fails with EBUSY if the
  caller still holds the FUSE fd open — release the handle (or pass
  `lazy: true`) before calling this.
  """
  @spec unmount(mount_point :: String.t(), unmount_opts()) :: :ok | {:error, error()}
  def unmount(mount_point, opts \\ []) when is_binary(mount_point) and is_list(opts) do
    lazy? = Keyword.get(opts, :lazy, false)
    timeout = Keyword.get(opts, :timeout, @default_unmount_timeout)

    unless is_integer(timeout) and timeout > 0 do
      raise ArgumentError, "timeout must be a positive integer, got: #{inspect(timeout)}"
    end

    case System.find_executable("fusermount3") do
      nil -> {:error, :enoent}
      path -> run_unmount_port(path, mount_point, lazy?, timeout)
    end
  end

  defp run_unmount_port(executable, mount_point, lazy?, timeout) do
    args =
      if lazy?,
        do: ["-u", "-z", "--", mount_point],
        else: ["-u", "--", mount_point]

    port =
      Port.open({:spawn_executable, executable}, [
        :exit_status,
        :hide,
        :stderr_to_stdout,
        {:args, args}
      ])

    receive do
      {^port, {:exit_status, 0}} ->
        :ok

      {^port, {:exit_status, status}} ->
        {:error, {:fusermount, status}}
    after
      timeout ->
        Port.close(port)
        {:error, :timeout}
    end
  end
end
