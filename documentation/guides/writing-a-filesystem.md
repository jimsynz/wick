# Writing a filesystem

Wick gives you two things: a **transport** (`Wick.Native`,
`Wick.Fusermount`) that moves bytes between the kernel and the BEAM,
and a **codec** (`Wick.Protocol`) that turns those bytes into request
structs and back into reply frames. It deliberately stops there — it
does not impose a filesystem abstraction, so you write the event loop
that ties the two together. This guide walks through a complete,
read-only filesystem to show exactly what that loop looks like.

> #### Linux only {: .warning}
>
> The transport binds the Linux FUSE kernel ABI, so a running FUSE
> server needs Linux, a mounted `/dev/fuse`, and `fusermount3` on the
> `PATH` (the `fuse3` package on most distributions). `Wick.Protocol`
> is pure Elixir and runs anywhere, which is why the codec is testable
> without a kernel.

## The request/response loop

A FUSE server is an event loop over a single mounted file descriptor:

1. `Wick.Fusermount.mount/2` mounts the filesystem and returns a
   handle wrapping the `/dev/fuse` fd.
2. `Wick.Native.select_read/1` arms **one** read-readiness
   notification. When a request is waiting, the owning process
   receives `{:select, handle, :undefined, :ready_input}`.
3. `Wick.Native.read_frame/1` reads exactly one request frame.
4. `Wick.Protocol.decode_request/1` decodes the frame into
   `{:ok, opcode, header, request}` — `opcode` is an atom, `header` is
   a `Wick.Protocol.InHeader`, and `request` is an opcode-specific
   struct from `Wick.Protocol.Request`.
5. You build a reply struct, encode it with
   `Wick.Protocol.encode_response/3`, and write it back with
   `Wick.Native.write_frame/2`. Errors are sent as a negative POSIX
   errno via `Wick.Protocol.encode_error/2`.
6. Re-arm with `select_read/1` and wait for the next request.

The notification is one-shot — you **must** re-arm after every frame.

## The INIT handshake

The kernel's very first request after a mount is `:init`, and nothing
else happens until you answer it. Reply with a
`Wick.Protocol.Response.Init` that echoes the kernel's major version,
clamps the minor down to what the codec understands (31), and
advertises your `max_write`. Keep `max_write` comfortably below the
128 KiB `read_frame/1` ceiling so a maximum-sized `WRITE` request
still fits in one frame — 64 KiB is the safe libfuse default.

## A complete example

`HelloFS` is a read-only filesystem with a single file, `hello`,
containing `"Hello from Wick!\n"`. It implements just the read-path
opcodes: `INIT`, `LOOKUP`, `GETATTR`, `OPEN`/`OPENDIR`, `READ`,
`READDIR`, plus the no-reply housekeeping opcodes. Everything else is
answered with `ENOSYS`, which tells the kernel to stop asking.

```elixir
defmodule HelloFS do
  @moduledoc "A read-only FUSE filesystem exposing a single file, `hello`."

  use GenServer

  alias Wick.Fusermount
  alias Wick.Native
  alias Wick.Protocol
  alias Wick.Protocol.{Attr, Request, Response}

  @root_ino 1
  @file_ino 2
  @filename "hello"
  @contents "Hello from Wick!\n"

  # POSIX mode bits: S_IFDIR | 0755 and S_IFREG | 0444.
  @dir_mode 0o040755
  @file_mode 0o100444

  # dirent d_type values.
  @dt_dir 4
  @dt_reg 8

  # errno values (the kernel wants the negative).
  @enoent 2
  @enosys 38

  # Protocol version the codec speaks, and a safe max_write.
  @major 7
  @minor 31
  @max_write 64 * 1024

  def start_link(mount_point) when is_binary(mount_point) do
    GenServer.start_link(__MODULE__, mount_point)
  end

  @impl GenServer
  def init(mount_point) do
    Process.flag(:trap_exit, true)

    case Fusermount.mount(mount_point, ["fsname=hellofs", "subtype=hellofs"]) do
      {:ok, fd} ->
        :ok = Native.select_read(fd)
        {:ok, %{fd: fd, mount_point: mount_point}}

      {:error, reason} ->
        {:stop, {:mount_failed, reason}}
    end
  end

  @impl GenServer
  def handle_info({:select, fd, _ref, :ready_input}, %{fd: fd} = state) do
    case Native.read_frame(fd) do
      {:ok, frame} ->
        dispatch(frame, state)
        :ok = Native.select_read(fd)
        {:noreply, state}

      {:error, :eagain} ->
        :ok = Native.select_read(fd)
        {:noreply, state}

      # The kernel unmounted us — shut down cleanly.
      {:error, :enodev} ->
        {:stop, :normal, state}

      {:error, reason} ->
        {:stop, {:read_failed, reason}, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    Fusermount.unmount(state.mount_point, lazy: true)
    :ok
  end

  # ── Frame dispatch ──────────────────────────────────────────────

  defp dispatch(frame, state) do
    case Protocol.decode_request(frame) do
      {:ok, opcode, header, request} ->
        handle(opcode, header, request, state)

      # An opcode the codec doesn't decode: reply ENOSYS so the kernel
      # stops sending it. The unique is still in the raw header.
      {:error, {:unknown_opcode, _n}} ->
        reply_error(state.fd, unique(frame), @enosys)

      {:error, _reason} ->
        :ok
    end
  end

  # INIT must be answered before anything else works.
  defp handle(:init, header, %Request.Init{} = req, state) do
    reply(state.fd, header.unique, %Response.Init{
      major: @major,
      minor: min(req.minor, @minor),
      max_readahead: req.max_readahead,
      flags: 0,
      max_background: 0,
      congestion_threshold: 0,
      max_write: @max_write,
      time_gran: 1,
      max_pages: 0,
      map_alignment: 0
    })
  end

  defp handle(:lookup, %{nodeid: @root_ino} = header, %Request.Lookup{name: @filename}, state) do
    reply(state.fd, header.unique, %Response.Entry{
      nodeid: @file_ino,
      entry_valid: 1,
      attr_valid: 1,
      attr: file_attr()
    })
  end

  defp handle(:lookup, header, %Request.Lookup{}, state) do
    reply_error(state.fd, header.unique, @enoent)
  end

  defp handle(:getattr, header, %Request.GetAttr{}, state) do
    case attr_for(header.nodeid) do
      nil -> reply_error(state.fd, header.unique, @enoent)
      attr -> reply(state.fd, header.unique, %Response.AttrReply{attr_valid: 1, attr: attr})
    end
  end

  # OPEN and OPENDIR share the fuse_open_in layout. This filesystem is
  # stateless, so hand back a zero file handle.
  defp handle(op, header, %Request.Open{}, state) when op in [:open, :opendir] do
    reply(state.fd, header.unique, %Response.Open{fh: 0})
  end

  defp handle(:read, %{nodeid: @file_ino} = header, %Request.Read{} = req, state) do
    reply(state.fd, header.unique, %Response.Read{data: slice(@contents, req.offset, req.size)})
  end

  defp handle(:read, header, %Request.Read{}, state) do
    reply_error(state.fd, header.unique, @enoent)
  end

  defp handle(:readdir, %{nodeid: @root_ino} = header, %Request.Readdir{} = req, state) do
    reply(state.fd, header.unique, %Response.Readdir{entries: dirents(req.offset, req.size)})
  end

  defp handle(:readdir, header, %Request.Readdir{}, state) do
    reply_error(state.fd, header.unique, @enoent)
  end

  # RELEASE / RELEASEDIR / FLUSH have nothing to do here — reply empty.
  defp handle(op, header, _request, state) when op in [:release, :releasedir, :flush] do
    reply(state.fd, header.unique, %Response.Empty{})
  end

  # FORGET and BATCH_FORGET never get a reply.
  defp handle(op, _header, _request, _state) when op in [:forget, :batch_forget] do
    :ok
  end

  defp handle(:statfs, header, %Request.Statfs{}, state) do
    reply(state.fd, header.unique, %Response.Statfs{
      files: 1,
      bsize: 4096,
      namelen: 255,
      frsize: 4096
    })
  end

  # Everything else: not implemented.
  defp handle(_op, header, _request, state) do
    reply_error(state.fd, header.unique, @enosys)
  end

  # ── Attributes ──────────────────────────────────────────────────

  defp attr_for(@root_ino), do: dir_attr()
  defp attr_for(@file_ino), do: file_attr()
  defp attr_for(_), do: nil

  defp dir_attr, do: %Attr{ino: @root_ino, mode: @dir_mode, nlink: 2, blksize: 4096}

  defp file_attr do
    size = byte_size(@contents)
    %Attr{ino: @file_ino, size: size, blocks: div(size + 511, 512), mode: @file_mode, nlink: 1, blksize: 4096}
  end

  # ── Directory and file helpers ──────────────────────────────────

  # `off` is the cookie the kernel sends back to resume after this
  # entry; skip everything at or before the requested `offset`, and
  # stop before the reply exceeds the kernel's `size` budget.
  defp dirents(offset, size) do
    [
      {".", 1, @dt_dir, @root_ino},
      {"..", 2, @dt_dir, @root_ino},
      {@filename, 3, @dt_reg, @file_ino}
    ]
    |> Enum.filter(fn {_name, off, _type, _ino} -> off > offset end)
    |> Enum.reduce_while({[], 0}, fn {name, off, type, ino}, {acc, used} ->
      need = dirent_size(byte_size(name))

      if used + need > size do
        {:halt, {acc, used}}
      else
        entry = %Response.Dirent{ino: ino, off: off, type: type, name: name}
        {:cont, {[entry | acc], used + need}}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp dirent_size(namelen), do: 24 + namelen + rem(8 - rem(24 + namelen, 8), 8)

  defp slice(bin, offset, _size) when offset >= byte_size(bin), do: ""
  defp slice(bin, offset, size), do: binary_part(bin, offset, min(size, byte_size(bin) - offset))

  # ── Reply helpers ───────────────────────────────────────────────

  defp reply(fd, unique, struct) do
    bytes = unique |> Protocol.encode_response(struct, 0) |> :erlang.iolist_to_binary()
    Native.write_frame(fd, bytes)
  end

  defp reply_error(fd, unique, errno) do
    Native.write_frame(fd, Protocol.encode_error(unique, -errno))
  end

  defp unique(<<_len::little-32, _opcode::little-32, unique::little-64, _rest::binary>>), do: unique
end
```

## Running it

The mount point must exist before you mount:

```elixir
File.mkdir_p!("/tmp/hellofs")
{:ok, _pid} = HelloFS.start_link("/tmp/hellofs")
```

Then, from a shell:

```sh
$ ls /tmp/hellofs
hello
$ cat /tmp/hellofs/hello
Hello from Wick!
```

Stopping the GenServer runs `terminate/2`, which unmounts. The unmount
is lazy (`MNT_DETACH`) because the process still holds the FUSE fd; the
kernel detaches the mount immediately and finalises it once the fd is
released.

## Replying with errors

Any handler can return an errno instead of a reply struct — encode it
with `Wick.Protocol.encode_error/2`, passing the **negative** value:

```elixir
# "No such file or directory"
Native.write_frame(fd, Protocol.encode_error(header.unique, -2))
```

`encode_error/2` and `encode_response(unique, nil, errno)` are
equivalent; both emit a header-only frame with no body, which is what
the kernel expects for an error reply.

## Going further

`HelloFS` is read-only. To build a writable filesystem, handle the
write-path opcodes — `CREATE`, `MKDIR`, `WRITE`, `SETATTR`, `UNLINK`,
`RMDIR`, `RENAME` — and reply with the matching structs. The full set
of decodable requests and encodable replies lives in
`Wick.Protocol.Request` and `Wick.Protocol.Response`; `Wick.Protocol`
documents the wire rules and the supported opcode set.
