defmodule Wick do
  @moduledoc """
  Build FUSE userspace filesystems on the BEAM.

  Wick has two layers and deliberately stops there — it does not impose
  a filesystem abstraction. You drive the protocol loop yourself; the
  [Writing a filesystem](writing-a-filesystem.html) guide walks through
  a complete read-only example.

  ## Transport

    * `Wick.Native` — opens `/dev/fuse`, arms `enif_select` readiness
      notifications, and does bounded `read_frame/1` / `write_frame/2`
      of protocol frames.
    * `Wick.Fusermount` — mounts and unmounts via the setuid
      `fusermount3` helper.

  ## Codec

    * `Wick.Protocol` — a pure-Elixir codec for the Linux FUSE kernel
      protocol (FUSE_KERNEL_VERSION 7.31). `decode_request/1` turns a
      kernel frame into an opcode, a `Wick.Protocol.InHeader`, and a
      request struct; `encode_response/3` builds the reply frame.

  ## The request/response loop

  A FUSE server is an event loop over a single mounted fd:

    1. `Wick.Fusermount.mount/2` returns a handle.
    2. `Wick.Native.select_read/1` arms one read-readiness
       notification; the owning process then receives
       `{:select, handle, :undefined, :ready_input}` when a request is
       waiting.
    3. `Wick.Native.read_frame/1` reads one request frame.
    4. `Wick.Protocol.decode_request/1` decodes it.
    5. You build a reply and write it with
       `Wick.Protocol.encode_response/3` and
       `Wick.Native.write_frame/2` (or `Wick.Protocol.encode_error/2`
       for an errno).
    6. Re-arm with `select_read/1` and repeat — the notification is
       one-shot.

  ## The INIT handshake

  The kernel's **first** request after a mount is `:init`, and nothing
  else works until you answer it with a `Wick.Protocol.Response.Init`
  carrying a compatible version (clamp the minor to 31) and your
  negotiated `max_write`. See the guide for the full handshake.

  > #### Linux only {: .info}
  >
  > The transport binds the Linux FUSE ABI, so `Wick.Native` and
  > `Wick.Fusermount` only run on Linux. `Wick.Protocol` is pure
  > Elixir and runs anywhere.
  """
end
