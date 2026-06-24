defmodule Wick.Protocol.InHeader do
  @moduledoc """
  `fuse_in_header` — the 40-byte prefix on every request the kernel
  sends to userspace.

  Layout (little-endian):

      +-------+--------+----------------------------------+
      | off   | size   | field                            |
      +-------+--------+----------------------------------+
      |  0    | u32    | len (total frame length)         |
      |  4    | u32    | opcode                           |
      |  8    | u64    | unique (matches in reply)        |
      | 16    | u64    | nodeid (target inode)            |
      | 24    | u32    | uid                              |
      | 28    | u32    | gid                              |
      | 32    | u32    | pid                              |
      | 36    | u32    | padding (zero)                   |
      +-------+--------+----------------------------------+
  """

  @header_size 40

  defstruct [:len, :opcode, :unique, :nodeid, :uid, :gid, :pid]

  @typedoc "Decoded request header."
  @type t :: %__MODULE__{
          len: non_neg_integer(),
          opcode: non_neg_integer(),
          unique: non_neg_integer(),
          nodeid: non_neg_integer(),
          uid: non_neg_integer(),
          gid: non_neg_integer(),
          pid: non_neg_integer()
        }

  @doc "Size of the on-wire header in bytes (always 40)."
  @spec size() :: 40
  def size, do: @header_size

  @doc """
  Split a complete request frame into its header and body. Validates
  that `header.len` matches the frame size.
  """
  @spec split(binary()) :: {:ok, t(), binary()} | {:error, term()}
  def split(<<
        len::little-32,
        opcode::little-32,
        unique::little-64,
        nodeid::little-64,
        uid::little-32,
        gid::little-32,
        pid::little-32,
        _padding::little-32,
        body::binary
      >>) do
    actual = @header_size + byte_size(body)

    if len == actual do
      header = %__MODULE__{
        len: len,
        opcode: opcode,
        unique: unique,
        nodeid: nodeid,
        uid: uid,
        gid: gid,
        pid: pid
      }

      {:ok, header, body}
    else
      {:error, {:length_mismatch, len, actual}}
    end
  end

  def split(_short), do: {:error, :short_header}

  @doc """
  Encode a header struct back to bytes. `padding` is always written as
  zero. Primarily a test helper — production code never emits a
  request header (the kernel does that).
  """
  @spec encode(t()) :: binary()
  def encode(%__MODULE__{} = h) do
    <<
      h.len::little-32,
      h.opcode::little-32,
      h.unique::little-64,
      h.nodeid::little-64,
      h.uid::little-32,
      h.gid::little-32,
      h.pid::little-32,
      0::little-32
    >>
  end
end
