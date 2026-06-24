defmodule Wick.Protocol.Response do
  @moduledoc """
  Opcode-specific response structs and `encode/1` dispatcher.

  Each struct below carries the payload that follows `fuse_out_header`
  for a given opcode's success reply. Use via
  `Wick.Protocol.encode_response/3`, which prepends the shared
  16-byte out-header.

  Ops that have no reply body (UNLINK, RMDIR, RENAME, RELEASE, FLUSH,
  FSYNC, DESTROY, SETXATTR, …) and FORGET / BATCH_FORGET (no reply
  ever) use `%Empty{}`.
  """

  alias Wick.Protocol.Attr

  defmodule Empty do
    @moduledoc "Marker for replies that carry only the 16-byte out-header."
    defstruct []
    @type t :: %__MODULE__{}
  end

  defmodule Init do
    @moduledoc "FUSE_INIT reply — `fuse_init_out` (64 bytes)."
    defstruct [
      :major,
      :minor,
      :max_readahead,
      :flags,
      :max_background,
      :congestion_threshold,
      :max_write,
      :time_gran,
      :max_pages,
      :map_alignment
    ]

    @type t :: %__MODULE__{
            major: non_neg_integer(),
            minor: non_neg_integer(),
            max_readahead: non_neg_integer(),
            flags: non_neg_integer(),
            max_background: non_neg_integer(),
            congestion_threshold: non_neg_integer(),
            max_write: non_neg_integer(),
            time_gran: non_neg_integer(),
            max_pages: non_neg_integer(),
            map_alignment: non_neg_integer()
          }
  end

  defmodule Entry do
    @moduledoc """
    `fuse_entry_out` (128 bytes) — reply to LOOKUP / MKDIR / CREATE
    (CREATE also appends an `Open` reply).
    """
    defstruct nodeid: 0,
              generation: 0,
              entry_valid: 0,
              attr_valid: 0,
              entry_valid_nsec: 0,
              attr_valid_nsec: 0,
              attr: %Attr{}

    @type t :: %__MODULE__{
            nodeid: non_neg_integer(),
            generation: non_neg_integer(),
            entry_valid: non_neg_integer(),
            attr_valid: non_neg_integer(),
            entry_valid_nsec: non_neg_integer(),
            attr_valid_nsec: non_neg_integer(),
            attr: Attr.t()
          }
  end

  defmodule AttrReply do
    @moduledoc "`fuse_attr_out` (104 bytes) — reply to GETATTR / SETATTR."
    defstruct attr_valid: 0, attr_valid_nsec: 0, attr: %Attr{}

    @type t :: %__MODULE__{
            attr_valid: non_neg_integer(),
            attr_valid_nsec: non_neg_integer(),
            attr: Attr.t()
          }
  end

  defmodule Open do
    @moduledoc "`fuse_open_out` (16 bytes) — reply to OPEN / OPENDIR."
    defstruct fh: 0, open_flags: 0
    @type t :: %__MODULE__{fh: non_neg_integer(), open_flags: non_neg_integer()}
  end

  defmodule CreateReply do
    @moduledoc """
    FUSE_CREATE reply — `fuse_entry_out` (128) + `fuse_open_out` (16)
    back-to-back. Modelled as a struct with two embedded replies to
    make pattern matching at the handler side easier.
    """
    defstruct entry: %Entry{}, open: %Open{}

    @type t :: %__MODULE__{entry: Entry.t(), open: Open.t()}
  end

  defmodule Write do
    @moduledoc "`fuse_write_out` (8 bytes) — reply to WRITE."
    defstruct [:size]
    @type t :: %__MODULE__{size: non_neg_integer()}
  end

  defmodule Read do
    @moduledoc """
    FUSE_READ reply — a raw binary, length ≤ requested `size`. Used
    verbatim as the response body (no wrapper struct on the wire).
    """
    defstruct data: <<>>
    @type t :: %__MODULE__{data: binary()}
  end

  defmodule Statfs do
    @moduledoc "`fuse_statfs_out` / `fuse_kstatfs` (80 bytes) — reply to STATFS."
    defstruct blocks: 0,
              bfree: 0,
              bavail: 0,
              files: 0,
              ffree: 0,
              bsize: 0,
              namelen: 0,
              frsize: 0

    @type t :: %__MODULE__{
            blocks: non_neg_integer(),
            bfree: non_neg_integer(),
            bavail: non_neg_integer(),
            files: non_neg_integer(),
            ffree: non_neg_integer(),
            bsize: non_neg_integer(),
            namelen: non_neg_integer(),
            frsize: non_neg_integer()
          }
  end

  defmodule Dirent do
    @moduledoc """
    A single directory entry for READDIR. On the wire this is a
    24-byte header (`ino`, `off`, `namelen`, `type`) followed by the
    name bytes (no NUL) and 0–7 zero bytes of padding so each record
    ends on an 8-byte boundary.
    """
    defstruct ino: 0, off: 0, type: 0, name: ""

    @type t :: %__MODULE__{
            ino: non_neg_integer(),
            off: non_neg_integer(),
            type: non_neg_integer(),
            name: String.t()
          }
  end

  defmodule Readdir do
    @moduledoc "READDIR reply — an ordered list of `Dirent` records."
    defstruct entries: []
    @type t :: %__MODULE__{entries: [Dirent.t()]}
  end

  defmodule DirentPlus do
    @moduledoc """
    A single READDIRPLUS entry — `fuse_direntplus` on the wire. The
    record is a 128-byte `fuse_entry_out` followed by the same 24-byte
    dirent header as `Dirent`, the name bytes (no NUL), and 0–7 zero
    bytes of padding so each record ends on an 8-byte boundary.

    Inline attributes let the kernel populate its dentry + inode cache
    without a follow-up `LOOKUP` round-trip — the major perf win that
    motivates READDIRPLUS over READDIR.
    """
    defstruct entry: %Entry{}, dirent: %Dirent{}

    @type t :: %__MODULE__{entry: Entry.t(), dirent: Dirent.t()}
  end

  defmodule ReaddirPlus do
    @moduledoc "READDIRPLUS reply — an ordered list of `DirentPlus` records."
    defstruct entries: []
    @type t :: %__MODULE__{entries: [DirentPlus.t()]}
  end

  defmodule XattrSize do
    @moduledoc """
    Reply to a size-probe `GETXATTR` / `LISTXATTR` (the request's
    `size` field was 0). The kernel uses the returned `size` to
    allocate a buffer and re-issue the request. Encoded as
    `fuse_getxattr_out` (8 bytes).
    """
    defstruct size: 0
    @type t :: %__MODULE__{size: non_neg_integer()}
  end

  defmodule XattrData do
    @moduledoc """
    Reply to a real-fetch `GETXATTR` (request `size` > 0): the value
    bytes; or to `LISTXATTR`: the NUL-separated, NUL-terminated list
    of attribute names. The kernel rejects this reply with `ERANGE`
    if the data exceeds the buffer it allocated based on its prior
    probe — handlers are responsible for ensuring `byte_size(data)`
    fits within the request's `size` budget.
    """
    defstruct data: <<>>
    @type t :: %__MODULE__{data: binary()}
  end

  defmodule GetLkReply do
    @moduledoc """
    `fuse_lk_out` (24 bytes) — reply to GETLK. Carries a
    `fuse_file_lock` describing either the conflicting lock that
    would have been blocked, or `F_UNLCK` (type=2) when the range
    is free. SETLK / SETLKW success replies use `Empty` instead
    (header-only).
    """
    defstruct start: 0, end: 0, type: 2, pid: 0

    @type t :: %__MODULE__{
            start: non_neg_integer(),
            end: non_neg_integer(),
            type: non_neg_integer(),
            pid: non_neg_integer()
          }
  end

  @type t ::
          Empty.t()
          | Init.t()
          | Entry.t()
          | AttrReply.t()
          | Open.t()
          | CreateReply.t()
          | Write.t()
          | Read.t()
          | Statfs.t()
          | Readdir.t()
          | ReaddirPlus.t()
          | XattrSize.t()
          | XattrData.t()
          | GetLkReply.t()

  @doc "Encode the response body (excluding `fuse_out_header`)."
  @spec encode(t()) :: iodata()
  def encode(%Empty{}), do: []

  def encode(%Init{} = r) do
    <<
      r.major::little-32,
      r.minor::little-32,
      r.max_readahead::little-32,
      r.flags::little-32,
      r.max_background::little-16,
      r.congestion_threshold::little-16,
      r.max_write::little-32,
      r.time_gran::little-32,
      r.max_pages::little-16,
      r.map_alignment::little-16,
      # unused[8] — 32 bytes of zero padding
      0::little-64,
      0::little-64,
      0::little-64,
      0::little-64
    >>
  end

  def encode(%Entry{} = r), do: encode_entry(r)

  def encode(%AttrReply{attr_valid: av, attr_valid_nsec: ans, attr: attr}) do
    <<av::little-64, ans::little-32, 0::little-32, Attr.encode(attr)::binary>>
  end

  def encode(%Open{fh: fh, open_flags: flags}),
    do: <<fh::little-64, flags::little-32, 0::little-32>>

  def encode(%CreateReply{entry: entry, open: open}) do
    [encode_entry(entry), encode(open)]
  end

  def encode(%Write{size: size}),
    do: <<size::little-32, 0::little-32>>

  def encode(%Read{data: data}), do: data

  def encode(%Statfs{} = s) do
    <<
      s.blocks::little-64,
      s.bfree::little-64,
      s.bavail::little-64,
      s.files::little-64,
      s.ffree::little-64,
      s.bsize::little-32,
      s.namelen::little-32,
      s.frsize::little-32,
      0::little-32,
      # spare[6] — 24 bytes
      0::little-64,
      0::little-64,
      0::little-64
    >>
  end

  def encode(%Readdir{entries: entries}),
    do: Enum.map(entries, &encode_dirent/1)

  def encode(%ReaddirPlus{entries: entries}),
    do: Enum.map(entries, &encode_direntplus/1)

  def encode(%XattrSize{size: size}),
    do: <<size::little-32, 0::little-32>>

  def encode(%XattrData{data: data}) when is_binary(data), do: data

  def encode(%GetLkReply{} = lk) do
    <<lk.start::little-64, lk.end::little-64, lk.type::little-32, lk.pid::little-32>>
  end

  # ——— Private helpers ————————————————————————————————————————————

  defp encode_entry(%Entry{} = e) do
    <<
      e.nodeid::little-64,
      e.generation::little-64,
      e.entry_valid::little-64,
      e.attr_valid::little-64,
      e.entry_valid_nsec::little-32,
      e.attr_valid_nsec::little-32,
      Attr.encode(e.attr)::binary
    >>
  end

  defp encode_dirent(%Dirent{} = d) do
    name_bytes = d.name
    namelen = byte_size(name_bytes)
    pad = rem(8 - rem(24 + namelen, 8), 8)

    <<
      d.ino::little-64,
      d.off::little-64,
      namelen::little-32,
      d.type::little-32,
      name_bytes::binary,
      0::size(pad * 8)
    >>
  end

  defp encode_direntplus(%DirentPlus{entry: entry, dirent: dirent}) do
    name_bytes = dirent.name
    namelen = byte_size(name_bytes)
    pad = rem(8 - rem(24 + namelen, 8), 8)

    [
      encode_entry(entry),
      <<
        dirent.ino::little-64,
        dirent.off::little-64,
        namelen::little-32,
        dirent.type::little-32,
        name_bytes::binary,
        0::size(pad * 8)
      >>
    ]
  end

  @doc """
  Decode a stream of `fuse_dirent` records. Primarily a test helper
  that round-trips against `encode/1` for `Readdir` responses.
  """
  @spec decode_dirents(binary()) :: {:ok, [Dirent.t()]} | {:error, :malformed_body}
  def decode_dirents(binary) when is_binary(binary), do: do_decode_dirents(binary, [])

  defp do_decode_dirents(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp do_decode_dirents(
         <<ino::little-64, off::little-64, namelen::little-32, type::little-32, rest::binary>>,
         acc
       ) do
    pad = rem(8 - rem(24 + namelen, 8), 8)

    case rest do
      <<name::binary-size(^namelen), _pad::size(^pad * 8), tail::binary>> ->
        do_decode_dirents(tail, [%Dirent{ino: ino, off: off, type: type, name: name} | acc])

      _ ->
        {:error, :malformed_body}
    end
  end

  defp do_decode_dirents(_, _), do: {:error, :malformed_body}

  @doc """
  Decode a stream of `fuse_direntplus` records. Test helper that
  round-trips against `encode/1` for `ReaddirPlus` responses.
  """
  @spec decode_direntpluses(binary()) :: {:ok, [DirentPlus.t()]} | {:error, :malformed_body}
  def decode_direntpluses(binary) when is_binary(binary), do: do_decode_direntpluses(binary, [])

  defp do_decode_direntpluses(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp do_decode_direntpluses(
         <<entry_bytes::binary-size(128), rest::binary>>,
         acc
       ) do
    with {:ok, entry} <- decode_entry(entry_bytes),
         {:ok, dirent, tail} <- decode_one_dirent(rest) do
      do_decode_direntpluses(tail, [%DirentPlus{entry: entry, dirent: dirent} | acc])
    end
  end

  defp do_decode_direntpluses(_, _), do: {:error, :malformed_body}

  defp decode_entry(<<
         nodeid::little-64,
         generation::little-64,
         entry_valid::little-64,
         attr_valid::little-64,
         entry_valid_nsec::little-32,
         attr_valid_nsec::little-32,
         attr_bytes::binary-size(88)
       >>) do
    with {:ok, attr, <<>>} <- Attr.decode(attr_bytes) do
      {:ok,
       %Entry{
         nodeid: nodeid,
         generation: generation,
         entry_valid: entry_valid,
         attr_valid: attr_valid,
         entry_valid_nsec: entry_valid_nsec,
         attr_valid_nsec: attr_valid_nsec,
         attr: attr
       }}
    end
  end

  defp decode_entry(_), do: {:error, :malformed_body}

  defp decode_one_dirent(
         <<ino::little-64, off::little-64, namelen::little-32, type::little-32, rest::binary>>
       ) do
    pad = rem(8 - rem(24 + namelen, 8), 8)

    case rest do
      <<name::binary-size(^namelen), _pad::size(^pad * 8), tail::binary>> ->
        {:ok, %Dirent{ino: ino, off: off, type: type, name: name}, tail}

      _ ->
        {:error, :malformed_body}
    end
  end

  defp decode_one_dirent(_), do: {:error, :malformed_body}
end
