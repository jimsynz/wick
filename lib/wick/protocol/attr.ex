defmodule Wick.Protocol.Attr do
  @moduledoc """
  `fuse_attr` — the 88-byte embedded POSIX-attribute struct used inside
  `fuse_entry_out`, `fuse_attr_out`, and a few notification payloads.

  Field order matches `include/uapi/linux/fuse.h` v7.31. `padding` is
  written as zero.
  """

  @size 88

  defstruct ino: 0,
            size: 0,
            blocks: 0,
            atime: 0,
            mtime: 0,
            ctime: 0,
            atimensec: 0,
            mtimensec: 0,
            ctimensec: 0,
            mode: 0,
            nlink: 0,
            uid: 0,
            gid: 0,
            rdev: 0,
            blksize: 0

  @type t :: %__MODULE__{
          ino: non_neg_integer(),
          size: non_neg_integer(),
          blocks: non_neg_integer(),
          atime: non_neg_integer(),
          mtime: non_neg_integer(),
          ctime: non_neg_integer(),
          atimensec: non_neg_integer(),
          mtimensec: non_neg_integer(),
          ctimensec: non_neg_integer(),
          mode: non_neg_integer(),
          nlink: non_neg_integer(),
          uid: non_neg_integer(),
          gid: non_neg_integer(),
          rdev: non_neg_integer(),
          blksize: non_neg_integer()
        }

  @doc "Wire size in bytes (always 88)."
  @spec size() :: 88
  def size, do: @size

  @doc "Encode `fuse_attr` to 88 little-endian bytes."
  @spec encode(t()) :: binary()
  def encode(%__MODULE__{} = a) do
    <<
      a.ino::little-64,
      a.size::little-64,
      a.blocks::little-64,
      a.atime::little-64,
      a.mtime::little-64,
      a.ctime::little-64,
      a.atimensec::little-32,
      a.mtimensec::little-32,
      a.ctimensec::little-32,
      a.mode::little-32,
      a.nlink::little-32,
      a.uid::little-32,
      a.gid::little-32,
      a.rdev::little-32,
      a.blksize::little-32,
      0::little-32
    >>
  end

  @doc """
  Decode an `fuse_attr` from the leading 88 bytes of a binary. Returns
  the struct and the remaining bytes.
  """
  @spec decode(binary()) :: {:ok, t(), binary()} | {:error, :malformed_body}
  def decode(<<
        ino::little-64,
        size::little-64,
        blocks::little-64,
        atime::little-64,
        mtime::little-64,
        ctime::little-64,
        atimensec::little-32,
        mtimensec::little-32,
        ctimensec::little-32,
        mode::little-32,
        nlink::little-32,
        uid::little-32,
        gid::little-32,
        rdev::little-32,
        blksize::little-32,
        _padding::little-32,
        rest::binary
      >>) do
    {:ok,
     %__MODULE__{
       ino: ino,
       size: size,
       blocks: blocks,
       atime: atime,
       mtime: mtime,
       ctime: ctime,
       atimensec: atimensec,
       mtimensec: mtimensec,
       ctimensec: ctimensec,
       mode: mode,
       nlink: nlink,
       uid: uid,
       gid: gid,
       rdev: rdev,
       blksize: blksize
     }, rest}
  end

  def decode(_), do: {:error, :malformed_body}
end
