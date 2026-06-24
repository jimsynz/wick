defmodule Wick.Protocol do
  @moduledoc """
  Pure-Elixir codec for the Linux FUSE kernel protocol, targeting
  FUSE_KERNEL_VERSION 7.31 (the version exposed by libfuse 3.10+ and
  the Linux 5.4+ kernel).

  The codec operates on binaries only — no I/O, no dependency on the
  `/dev/fuse` NIF. A typical read path looks like:

      {:ok, request_bytes} = Wick.Native.read_frame(fd)

      case Wick.Protocol.decode_request(request_bytes) do
        {:ok, :lookup, header, %Wick.Protocol.LookupRequest{name: name}} ->
          reply = %Wick.Protocol.EntryReply{nodeid: ..., attr: ...}
          bytes = Wick.Protocol.encode_response(header.unique, reply, 0)
          :ok = Wick.Native.write_frame(fd, bytes)
        # ...
      end

  ## Wire rules

    * All multi-byte integers are little-endian. (The kernel UAPI is
      documented as native-endian, but every Linux platform Wick
      targets is little-endian.)
    * Every struct is padded to an 8-byte boundary. All `padding` /
      `unused*` / `dummy` fields are wire-significant — encode them as
      zero; ignore them on decode.
    * `fuse_in_header.len` / `fuse_out_header.len` is the *total*
      message length, header inclusive.
    * Error replies carry `fuse_out_header` only (no body). `error` is
      `0` for success or a negative POSIX errno.
    * Filenames in request bodies are NUL-terminated.

  ## Supported opcodes

  See `opcode_to_atom/1` and `atom_to_opcode/1` for the supported
  opcode set (the ~20 opcodes required for the read-path + write-path +
  metadata operations — INIT, LOOKUP, GETATTR, SETATTR, READDIR, READ,
  WRITE, OPEN, RELEASE, CREATE, MKDIR, UNLINK, RMDIR, RENAME, STATFS,
  FLUSH, FSYNC, FORGET, BATCH_FORGET, DESTROY).

  Extended opcodes for xattrs (SETXATTR / GETXATTR / LISTXATTR /
  REMOVEXATTR) are supported as of #671. The lock opcodes
  (GETLK / SETLK / SETLKW) are decoded as of #672 — handlers route
  them by `lk_flags & FUSE_LK_FLOCK` to either FLOCK whole-file
  logic (#672, #677) or byte-range fcntl (#674, #681). INTERRUPT
  (cancellation of a queued SETLKW) is supported as of #675. The
  remaining extended opcodes (IOCTL, POLL) are out of scope.
  """

  alias Wick.Protocol.{InHeader, Request, Response}

  @typedoc "Wire opcode atom — see `opcode_to_atom/1`."
  @type opcode ::
          :lookup
          | :forget
          | :getattr
          | :setattr
          | :mkdir
          | :unlink
          | :rmdir
          | :rename
          | :open
          | :read
          | :write
          | :statfs
          | :release
          | :fsync
          | :setxattr
          | :getxattr
          | :listxattr
          | :removexattr
          | :getlk
          | :setlk
          | :setlkw
          | :interrupt
          | :flush
          | :init
          | :opendir
          | :readdir
          | :releasedir
          | :create
          | :destroy
          | :batch_forget
          | :readdirplus
          | :rename2

  @typedoc "Decoded request tagged with its opcode atom."
  @type request :: Request.t()

  @typedoc "Response struct to be encoded into an outgoing frame."
  @type response :: Response.t()

  # ——— Opcode map ———————————————————————————————————————————————
  #
  # Source of truth: include/uapi/linux/fuse.h lines 420–468 (Linux v5.4).
  # Only opcodes in scope for #276 are mapped. Unrecognised opcodes
  # surface as `{:error, {:unknown_opcode, n}}` from `decode_request/1`
  # so the handler can reply with `-ENOSYS` without crashing.

  @opcodes %{
    1 => :lookup,
    2 => :forget,
    3 => :getattr,
    4 => :setattr,
    9 => :mkdir,
    10 => :unlink,
    11 => :rmdir,
    12 => :rename,
    14 => :open,
    15 => :read,
    16 => :write,
    17 => :statfs,
    18 => :release,
    20 => :fsync,
    21 => :setxattr,
    22 => :getxattr,
    23 => :listxattr,
    24 => :removexattr,
    25 => :flush,
    26 => :init,
    27 => :opendir,
    28 => :readdir,
    29 => :releasedir,
    30 => :fsyncdir,
    31 => :getlk,
    32 => :setlk,
    33 => :setlkw,
    35 => :create,
    36 => :interrupt,
    38 => :destroy,
    42 => :batch_forget,
    43 => :fallocate,
    44 => :readdirplus,
    45 => :rename2
  }

  @reverse_opcodes Map.new(@opcodes, fn {n, a} -> {a, n} end)

  @doc """
  Translate a numeric opcode into its atom. Returns `:unknown` for
  opcodes outside this codec's scope (xattrs, locks, ioctl, etc.).
  """
  @spec opcode_to_atom(non_neg_integer()) :: opcode() | :unknown
  def opcode_to_atom(n), do: Map.get(@opcodes, n, :unknown)

  @doc """
  Translate an opcode atom back into its numeric code.
  """
  @spec atom_to_opcode(opcode()) :: non_neg_integer()
  def atom_to_opcode(atom) when is_atom(atom), do: Map.fetch!(@reverse_opcodes, atom)

  # ——— Public codec entry points ——————————————————————————————————

  @doc """
  Decode a complete request frame (header + body) read from
  `/dev/fuse`.

  The kernel guarantees one complete request per `read(2)` so the
  caller should pass exactly one frame in. Returns:

    * `{:ok, opcode, header, request}` — `opcode` is the atom,
      `header` is a `Wick.Protocol.InHeader`, `request` is the
      opcode-specific struct from `Wick.Protocol.Request`.
    * `{:error, reason}` where `reason` is one of:
      * `:short_header` — fewer than 40 bytes delivered.
      * `{:length_mismatch, declared, actual}` — `in_header.len`
        disagrees with the delivered frame size.
      * `{:unknown_opcode, n}` — opcode not supported by this codec.
      * `:malformed_body` — body doesn't match the opcode's layout.
  """
  @spec decode_request(binary()) ::
          {:ok, opcode(), InHeader.t(), request()}
          | {:error, term()}
  def decode_request(frame) when is_binary(frame) do
    with {:ok, header, body} <- InHeader.split(frame),
         opcode when opcode != :unknown <- opcode_to_atom(header.opcode),
         {:ok, request} <- Request.decode(opcode, body) do
      {:ok, opcode, header, request}
    else
      :unknown ->
        {:error, {:unknown_opcode, unknown_opcode_from_frame(frame)}}

      {:error, _} = err ->
        err
    end
  end

  defp unknown_opcode_from_frame(<<_len::little-32, opcode::little-32, _rest::binary>>),
    do: opcode

  defp unknown_opcode_from_frame(_), do: 0

  @doc """
  Encode a response frame. `unique` is the `fuse_in_header.unique`
  value from the matching request. `error` is 0 on success or a
  negative POSIX errno.

  When `error != 0` the response body is omitted — the kernel expects
  a header-only frame for error replies. In that case `reply` can be
  `nil` and is ignored.
  """
  @spec encode_response(non_neg_integer(), response() | nil, integer()) :: iodata()
  def encode_response(unique, nil, error) when is_integer(error) and error != 0 do
    encode_error_only(unique, error)
  end

  def encode_response(unique, reply, 0) when not is_nil(reply) do
    body = Response.encode(reply) |> :erlang.iolist_to_binary()
    total = 16 + byte_size(body)
    <<total::little-32, 0::little-signed-32, unique::little-64, body::binary>>
  end

  def encode_response(unique, _reply, error) when is_integer(error) and error != 0 do
    # Non-zero error overrides body.
    encode_error_only(unique, error)
  end

  @doc """
  Shorthand for an error-only response. Equivalent to
  `encode_response(unique, nil, errno)`.
  """
  @spec encode_error(non_neg_integer(), integer()) :: binary()
  def encode_error(unique, errno) when is_integer(errno) and errno != 0,
    do: encode_error_only(unique, errno)

  defp encode_error_only(unique, error) do
    <<16::little-32, error::little-signed-32, unique::little-64>>
  end
end
