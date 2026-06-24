defmodule Wick.Protocol.Request do
  @moduledoc """
  Opcode-specific request structs and `decode/2` dispatcher.

  Each opcode's payload layout is taken verbatim from Linux's
  `include/uapi/linux/fuse.h` v7.31. Filenames in request bodies are
  always NUL-terminated and are decoded without the terminator.
  """

  # One module per request kind, all defined here to keep the
  # protocol codec in a single place. Structs are flat and carry only
  # the fields the handler cares about — padding / unused fields are
  # dropped on decode.

  defmodule Init do
    @moduledoc "FUSE_INIT request — `fuse_init_in` (16 bytes)."
    defstruct [:major, :minor, :max_readahead, :flags]

    @type t :: %__MODULE__{
            major: non_neg_integer(),
            minor: non_neg_integer(),
            max_readahead: non_neg_integer(),
            flags: non_neg_integer()
          }
  end

  defmodule Destroy do
    @moduledoc "FUSE_DESTROY request — empty body."
    defstruct []
    @type t :: %__MODULE__{}
  end

  defmodule Lookup do
    @moduledoc """
    FUSE_LOOKUP request — a NUL-terminated name. The parent directory
    is the `nodeid` in the request header.
    """
    defstruct [:name]
    @type t :: %__MODULE__{name: String.t()}
  end

  defmodule Forget do
    @moduledoc "FUSE_FORGET — `fuse_forget_in` (8 bytes)."
    defstruct [:nlookup]
    @type t :: %__MODULE__{nlookup: non_neg_integer()}
  end

  defmodule BatchForget do
    @moduledoc """
    FUSE_BATCH_FORGET — `fuse_batch_forget_in` (8 bytes) followed by
    `count` × `fuse_forget_one` records. Exposed as a list of
    `{nodeid, nlookup}` tuples.
    """
    defstruct [:items]
    @type t :: %__MODULE__{items: [{non_neg_integer(), non_neg_integer()}]}
  end

  defmodule GetAttr do
    @moduledoc "FUSE_GETATTR — `fuse_getattr_in` (16 bytes)."
    defstruct [:getattr_flags, :fh]
    @type t :: %__MODULE__{getattr_flags: non_neg_integer(), fh: non_neg_integer()}
  end

  defmodule SetAttr do
    @moduledoc "FUSE_SETATTR — `fuse_setattr_in` (88 bytes)."
    defstruct [
      :valid,
      :fh,
      :size,
      :lock_owner,
      :atime,
      :mtime,
      :ctime,
      :atimensec,
      :mtimensec,
      :ctimensec,
      :mode,
      :uid,
      :gid
    ]

    @type t :: %__MODULE__{
            valid: non_neg_integer(),
            fh: non_neg_integer(),
            size: non_neg_integer(),
            lock_owner: non_neg_integer(),
            atime: non_neg_integer(),
            mtime: non_neg_integer(),
            ctime: non_neg_integer(),
            atimensec: non_neg_integer(),
            mtimensec: non_neg_integer(),
            ctimensec: non_neg_integer(),
            mode: non_neg_integer(),
            uid: non_neg_integer(),
            gid: non_neg_integer()
          }
  end

  defmodule Mkdir do
    @moduledoc "FUSE_MKDIR — `fuse_mkdir_in` (8 bytes) + name + NUL."
    defstruct [:mode, :umask, :name]

    @type t :: %__MODULE__{
            mode: non_neg_integer(),
            umask: non_neg_integer(),
            name: String.t()
          }
  end

  defmodule Unlink do
    @moduledoc "FUSE_UNLINK — name + NUL. Parent nodeid in header."
    defstruct [:name]
    @type t :: %__MODULE__{name: String.t()}
  end

  defmodule Rmdir do
    @moduledoc "FUSE_RMDIR — name + NUL. Parent nodeid in header."
    defstruct [:name]
    @type t :: %__MODULE__{name: String.t()}
  end

  defmodule Rename do
    @moduledoc """
    FUSE_RENAME (12) — `fuse_rename_in` (8 bytes) with the new parent
    `nodeid`, then oldname+NUL, then newname+NUL. The old parent is in
    the request header.
    """
    defstruct [:newdir, :oldname, :newname]

    @type t :: %__MODULE__{
            newdir: non_neg_integer(),
            oldname: String.t(),
            newname: String.t()
          }
  end

  defmodule Rename2 do
    @moduledoc "FUSE_RENAME2 (45) — like RENAME plus a `flags` field."
    defstruct [:newdir, :flags, :oldname, :newname]

    @type t :: %__MODULE__{
            newdir: non_neg_integer(),
            flags: non_neg_integer(),
            oldname: String.t(),
            newname: String.t()
          }
  end

  defmodule Open do
    @moduledoc "FUSE_OPEN — `fuse_open_in` (8 bytes)."
    defstruct [:flags]
    @type t :: %__MODULE__{flags: non_neg_integer()}
  end

  defmodule Release do
    @moduledoc "FUSE_RELEASE — `fuse_release_in` (24 bytes)."
    defstruct [:fh, :flags, :release_flags, :lock_owner]

    @type t :: %__MODULE__{
            fh: non_neg_integer(),
            flags: non_neg_integer(),
            release_flags: non_neg_integer(),
            lock_owner: non_neg_integer()
          }
  end

  defmodule Read do
    @moduledoc "FUSE_READ — `fuse_read_in` (40 bytes)."
    defstruct [:fh, :offset, :size, :read_flags, :lock_owner, :flags]

    @type t :: %__MODULE__{
            fh: non_neg_integer(),
            offset: non_neg_integer(),
            size: non_neg_integer(),
            read_flags: non_neg_integer(),
            lock_owner: non_neg_integer(),
            flags: non_neg_integer()
          }
  end

  defmodule Readdir do
    @moduledoc """
    FUSE_READDIR — `fuse_read_in` (40 bytes). Same wire layout as
    `Read`, but `offset` is a directory-stream cookie.
    """
    defstruct [:fh, :offset, :size, :read_flags, :lock_owner, :flags]

    @type t :: %__MODULE__{
            fh: non_neg_integer(),
            offset: non_neg_integer(),
            size: non_neg_integer(),
            read_flags: non_neg_integer(),
            lock_owner: non_neg_integer(),
            flags: non_neg_integer()
          }
  end

  defmodule ReaddirPlus do
    @moduledoc """
    FUSE_READDIRPLUS — same wire layout as `Readdir` (`fuse_read_in`,
    40 bytes). The reply layout differs (each entry carries inline
    attributes via `fuse_direntplus`).
    """
    defstruct [:fh, :offset, :size, :read_flags, :lock_owner, :flags]

    @type t :: %__MODULE__{
            fh: non_neg_integer(),
            offset: non_neg_integer(),
            size: non_neg_integer(),
            read_flags: non_neg_integer(),
            lock_owner: non_neg_integer(),
            flags: non_neg_integer()
          }
  end

  defmodule Write do
    @moduledoc """
    FUSE_WRITE — `fuse_write_in` (40 bytes) plus `size` bytes of
    payload.
    """
    defstruct [:fh, :offset, :size, :write_flags, :lock_owner, :flags, :data]

    @type t :: %__MODULE__{
            fh: non_neg_integer(),
            offset: non_neg_integer(),
            size: non_neg_integer(),
            write_flags: non_neg_integer(),
            lock_owner: non_neg_integer(),
            flags: non_neg_integer(),
            data: binary()
          }
  end

  defmodule Statfs do
    @moduledoc "FUSE_STATFS — empty body."
    defstruct []
    @type t :: %__MODULE__{}
  end

  defmodule Flush do
    @moduledoc "FUSE_FLUSH — `fuse_flush_in` (24 bytes)."
    defstruct [:fh, :lock_owner]

    @type t :: %__MODULE__{
            fh: non_neg_integer(),
            lock_owner: non_neg_integer()
          }
  end

  defmodule Fsync do
    @moduledoc "FUSE_FSYNC — `fuse_fsync_in` (16 bytes)."
    defstruct [:fh, :fsync_flags]

    @type t :: %__MODULE__{
            fh: non_neg_integer(),
            fsync_flags: non_neg_integer()
          }
  end

  defmodule FsyncDir do
    @moduledoc """
    FUSE_FSYNCDIR — same wire layout as `Fsync` (`fuse_fsync_in`,
    16 bytes); semantics differ (it flushes the directory's
    metadata rather than the file's data).
    """
    defstruct [:fh, :fsync_flags]

    @type t :: %__MODULE__{
            fh: non_neg_integer(),
            fsync_flags: non_neg_integer()
          }
  end

  defmodule Fallocate do
    @moduledoc """
    FUSE_FALLOCATE — `fuse_fallocate_in` (32 bytes). Wick doesn't
    support sparse pre-allocation, so the session will reply
    `-ENOSYS` regardless of the fields; we still parse the body so
    decode-time validation works.
    """
    defstruct [:fh, :offset, :length, :mode]

    @type t :: %__MODULE__{
            fh: non_neg_integer(),
            offset: non_neg_integer(),
            length: non_neg_integer(),
            mode: non_neg_integer()
          }
  end

  defmodule Create do
    @moduledoc "FUSE_CREATE — `fuse_create_in` (16 bytes) + name + NUL."
    defstruct [:flags, :mode, :umask, :name]

    @type t :: %__MODULE__{
            flags: non_neg_integer(),
            mode: non_neg_integer(),
            umask: non_neg_integer(),
            name: String.t()
          }
  end

  defmodule SetXattr do
    @moduledoc """
    FUSE_SETXATTR — `fuse_setxattr_in` (8 bytes for v7.31) + name + NUL + value.

    `flags` is the POSIX `XATTR_CREATE` / `XATTR_REPLACE` bitmask. The
    extended `setxattr_flags` field added in v7.33 is not parsed —
    callers wanting that behaviour must negotiate `FUSE_SETXATTR_EXT`,
    which we don't yet advertise.
    """
    defstruct [:size, :flags, :name, :value]

    @type t :: %__MODULE__{
            size: non_neg_integer(),
            flags: non_neg_integer(),
            name: binary(),
            value: binary()
          }
  end

  defmodule GetXattr do
    @moduledoc """
    FUSE_GETXATTR — `fuse_getxattr_in` (8 bytes) + name + NUL.

    `size = 0` is the size-probe convention: the kernel asks us how
    big the value is so it can allocate a buffer; `size > 0` is the
    real fetch with a buffer that can hold up to that many bytes.
    """
    defstruct [:size, :name]

    @type t :: %__MODULE__{size: non_neg_integer(), name: binary()}
  end

  defmodule ListXattr do
    @moduledoc """
    FUSE_LISTXATTR — `fuse_getxattr_in` (8 bytes), no name. The
    nodeid in the request header identifies the file. Same size-probe
    convention as `GetXattr`.
    """
    defstruct [:size]

    @type t :: %__MODULE__{size: non_neg_integer()}
  end

  defmodule RemoveXattr do
    @moduledoc """
    FUSE_REMOVEXATTR — name + NUL. Nodeid in header.
    """
    defstruct [:name]

    @type t :: %__MODULE__{name: binary()}
  end

  defmodule FileLock do
    @moduledoc """
    `fuse_file_lock` (24 bytes) — embedded in `GetLk` / `SetLk`
    requests and the matching `GetLkReply`. `start` / `end` are
    byte-range bounds (ignored for FLOCK semantics). `type` is one
    of 0 (`F_RDLCK`) / 1 (`F_WRLCK`) / 2 (`F_UNLCK`). `pid` is the
    requesting process id (kernel fills it for us; we echo it in
    GetLk replies).
    """
    defstruct start: 0, end: 0, type: 0, pid: 0

    @type t :: %__MODULE__{
            start: non_neg_integer(),
            end: non_neg_integer(),
            type: non_neg_integer(),
            pid: non_neg_integer()
          }
  end

  defmodule GetLk do
    @moduledoc """
    FUSE_GETLK — `fuse_lk_in` (48 bytes). Probes for a conflicting
    byte-range lock. `lk_flags & FUSE_LK_FLOCK` (= 1) is meaningless
    for GETLK in POSIX terms — the kernel doesn't issue GETLK for
    flock when `FUSE_FLOCK_LOCKS` is advertised; handlers fall back
    to F_UNLCK if it ever does.
    """
    defstruct [:fh, :owner, :lk, :lk_flags]

    @type t :: %__MODULE__{
            fh: non_neg_integer(),
            owner: non_neg_integer(),
            lk: FileLock.t(),
            lk_flags: non_neg_integer()
          }
  end

  defmodule SetLk do
    @moduledoc """
    FUSE_SETLK / FUSE_SETLKW — `fuse_lk_in` (48 bytes). The
    `lk_flags & FUSE_LK_FLOCK` (= 1) bit distinguishes whole-file
    `flock(2)` semantics from POSIX byte-range `fcntl(F_SETLK)`
    semantics. The same struct decodes both opcodes; the request
    atom (`:setlk` vs `:setlkw`) tells the handler whether to block.
    """
    defstruct [:fh, :owner, :lk, :lk_flags]

    @type t :: %__MODULE__{
            fh: non_neg_integer(),
            owner: non_neg_integer(),
            lk: FileLock.t(),
            lk_flags: non_neg_integer()
          }
  end

  defmodule Interrupt do
    @moduledoc """
    FUSE_INTERRUPT — `fuse_interrupt_in` (8 bytes). Carries the
    `unique` of a previously-issued in-flight request that the
    kernel wants to cancel (e.g. because userspace received a
    signal during a blocking SETLKW).

    INTERRUPT itself has no reply on the wire — the original
    request is what the kernel waits for, typically with `EINTR`.
    Handlers that don't recognise the target unique should silently
    drop the message (the original may have already replied or
    might never have been blockable).
    """
    defstruct [:unique]

    @type t :: %__MODULE__{unique: non_neg_integer()}
  end

  @type t ::
          Init.t()
          | Destroy.t()
          | Lookup.t()
          | Forget.t()
          | BatchForget.t()
          | GetAttr.t()
          | SetAttr.t()
          | Mkdir.t()
          | Unlink.t()
          | Rmdir.t()
          | Rename.t()
          | Rename2.t()
          | Open.t()
          | Release.t()
          | Read.t()
          | Readdir.t()
          | ReaddirPlus.t()
          | Write.t()
          | Statfs.t()
          | Flush.t()
          | Fsync.t()
          | Create.t()
          | SetXattr.t()
          | GetXattr.t()
          | ListXattr.t()
          | RemoveXattr.t()
          | GetLk.t()
          | SetLk.t()
          | Interrupt.t()

  @doc """
  Decode a body for the given opcode. Returns the populated struct or
  `{:error, :malformed_body}` when the bytes don't match the expected
  layout.
  """
  @spec decode(atom(), binary()) :: {:ok, t()} | {:error, :malformed_body}
  # The kernel sends a `fuse_init_in` body sized for ITS protocol
  # version, which may be larger than the v7.31 we decode against
  # (modern kernels send 64 bytes for v7.36+). Accept any size ≥ 16
  # and ignore the trailing bytes — we only act on the four named
  # fields here, and the v7.31 INIT reply we send back signals the
  # negotiated minor version.
  def decode(
        :init,
        <<major::little-32, minor::little-32, mra::little-32, flags::little-32, _rest::binary>>
      ),
      do: {:ok, %Init{major: major, minor: minor, max_readahead: mra, flags: flags}}

  def decode(:destroy, <<>>), do: {:ok, %Destroy{}}

  def decode(:lookup, body) when is_binary(body) do
    case strip_cstring(body) do
      {:ok, name, <<>>} -> {:ok, %Lookup{name: name}}
      _ -> {:error, :malformed_body}
    end
  end

  def decode(:forget, <<nlookup::little-64>>),
    do: {:ok, %Forget{nlookup: nlookup}}

  def decode(:batch_forget, <<count::little-32, _dummy::little-32, rest::binary>>) do
    case decode_forget_list(rest, count, []) do
      {:ok, items} -> {:ok, %BatchForget{items: items}}
      :error -> {:error, :malformed_body}
    end
  end

  def decode(:getattr, <<flags::little-32, _dummy::little-32, fh::little-64>>),
    do: {:ok, %GetAttr{getattr_flags: flags, fh: fh}}

  def decode(:setattr, <<
        valid::little-32,
        _pad0::little-32,
        fh::little-64,
        size::little-64,
        lock_owner::little-64,
        atime::little-64,
        mtime::little-64,
        ctime::little-64,
        atimensec::little-32,
        mtimensec::little-32,
        ctimensec::little-32,
        mode::little-32,
        _unused4::little-32,
        uid::little-32,
        gid::little-32,
        _unused5::little-32
      >>) do
    {:ok,
     %SetAttr{
       valid: valid,
       fh: fh,
       size: size,
       lock_owner: lock_owner,
       atime: atime,
       mtime: mtime,
       ctime: ctime,
       atimensec: atimensec,
       mtimensec: mtimensec,
       ctimensec: ctimensec,
       mode: mode,
       uid: uid,
       gid: gid
     }}
  end

  def decode(:mkdir, <<mode::little-32, umask::little-32, rest::binary>>) do
    case strip_cstring(rest) do
      {:ok, name, <<>>} -> {:ok, %Mkdir{mode: mode, umask: umask, name: name}}
      _ -> {:error, :malformed_body}
    end
  end

  def decode(:unlink, body), do: decode_single_name(body, Unlink)
  def decode(:rmdir, body), do: decode_single_name(body, Rmdir)

  def decode(:rename, <<newdir::little-64, rest::binary>>) do
    case strip_two_cstrings(rest) do
      {:ok, oldname, newname} ->
        {:ok, %Rename{newdir: newdir, oldname: oldname, newname: newname}}

      :error ->
        {:error, :malformed_body}
    end
  end

  def decode(:rename2, <<newdir::little-64, flags::little-32, _pad::little-32, rest::binary>>) do
    case strip_two_cstrings(rest) do
      {:ok, oldname, newname} ->
        {:ok, %Rename2{newdir: newdir, flags: flags, oldname: oldname, newname: newname}}

      :error ->
        {:error, :malformed_body}
    end
  end

  def decode(:open, <<flags::little-32, _unused::little-32>>),
    do: {:ok, %Open{flags: flags}}

  # OPENDIR uses the same `fuse_open_in` layout as OPEN — share the
  # decoder and the result struct.
  def decode(:opendir, body), do: decode(:open, body)

  def decode(:release, <<
        fh::little-64,
        flags::little-32,
        release_flags::little-32,
        lock_owner::little-64
      >>) do
    {:ok, %Release{fh: fh, flags: flags, release_flags: release_flags, lock_owner: lock_owner}}
  end

  # RELEASEDIR uses the same `fuse_release_in` layout as RELEASE.
  def decode(:releasedir, body), do: decode(:release, body)

  def decode(:read, body), do: decode_read_like(body, Read)
  def decode(:readdir, body), do: decode_read_like(body, Readdir)
  def decode(:readdirplus, body), do: decode_read_like(body, ReaddirPlus)

  def decode(:write, <<
        fh::little-64,
        offset::little-64,
        size::little-32,
        write_flags::little-32,
        lock_owner::little-64,
        flags::little-32,
        _pad::little-32,
        payload::binary
      >>)
      when byte_size(payload) == size do
    {:ok,
     %Write{
       fh: fh,
       offset: offset,
       size: size,
       write_flags: write_flags,
       lock_owner: lock_owner,
       flags: flags,
       data: payload
     }}
  end

  def decode(:statfs, <<>>), do: {:ok, %Statfs{}}

  def decode(
        :flush,
        <<fh::little-64, _unused::little-32, _pad::little-32, lock_owner::little-64>>
      ),
      do: {:ok, %Flush{fh: fh, lock_owner: lock_owner}}

  def decode(:fsync, <<fh::little-64, fsync_flags::little-32, _pad::little-32>>),
    do: {:ok, %Fsync{fh: fh, fsync_flags: fsync_flags}}

  def decode(:fsyncdir, <<fh::little-64, fsync_flags::little-32, _pad::little-32>>),
    do: {:ok, %FsyncDir{fh: fh, fsync_flags: fsync_flags}}

  def decode(:fallocate, <<
        fh::little-64,
        offset::little-64,
        length::little-64,
        mode::little-32,
        _pad::little-32
      >>),
      do: {:ok, %Fallocate{fh: fh, offset: offset, length: length, mode: mode}}

  def decode(:create, <<
        flags::little-32,
        mode::little-32,
        umask::little-32,
        _pad::little-32,
        rest::binary
      >>) do
    case strip_cstring(rest) do
      {:ok, name, <<>>} ->
        {:ok, %Create{flags: flags, mode: mode, umask: umask, name: name}}

      _ ->
        {:error, :malformed_body}
    end
  end

  def decode(:setxattr, <<size::little-32, flags::little-32, rest::binary>>) do
    with {:ok, name, value} <- strip_cstring(rest),
         true <- byte_size(value) == size do
      {:ok, %SetXattr{size: size, flags: flags, name: name, value: value}}
    else
      _ -> {:error, :malformed_body}
    end
  end

  def decode(:getxattr, <<size::little-32, _pad::little-32, rest::binary>>) do
    case strip_cstring(rest) do
      {:ok, name, <<>>} -> {:ok, %GetXattr{size: size, name: name}}
      _ -> {:error, :malformed_body}
    end
  end

  def decode(:listxattr, <<size::little-32, _pad::little-32>>),
    do: {:ok, %ListXattr{size: size}}

  def decode(:removexattr, body) when is_binary(body) do
    case strip_cstring(body) do
      {:ok, name, <<>>} -> {:ok, %RemoveXattr{name: name}}
      _ -> {:error, :malformed_body}
    end
  end

  def decode(:getlk, body), do: decode_lk(body, GetLk)
  def decode(:setlk, body), do: decode_lk(body, SetLk)
  def decode(:setlkw, body), do: decode_lk(body, SetLk)

  def decode(:interrupt, <<unique::little-64>>), do: {:ok, %Interrupt{unique: unique}}

  def decode(_, _), do: {:error, :malformed_body}

  defp decode_lk(
         <<
           fh::little-64,
           owner::little-64,
           start::little-64,
           lk_end::little-64,
           type::little-32,
           pid::little-32,
           lk_flags::little-32,
           _padding::little-32
         >>,
         mod
       ) do
    {:ok,
     struct(mod,
       fh: fh,
       owner: owner,
       lk: %FileLock{start: start, end: lk_end, type: type, pid: pid},
       lk_flags: lk_flags
     )}
  end

  defp decode_lk(_, _), do: {:error, :malformed_body}

  # ——— Private helpers ————————————————————————————————————————————

  defp decode_single_name(body, mod) do
    case strip_cstring(body) do
      {:ok, name, <<>>} -> {:ok, struct(mod, name: name)}
      _ -> {:error, :malformed_body}
    end
  end

  defp decode_read_like(
         <<
           fh::little-64,
           offset::little-64,
           size::little-32,
           read_flags::little-32,
           lock_owner::little-64,
           flags::little-32,
           _pad::little-32
         >>,
         mod
       ) do
    {:ok,
     struct(mod,
       fh: fh,
       offset: offset,
       size: size,
       read_flags: read_flags,
       lock_owner: lock_owner,
       flags: flags
     )}
  end

  defp decode_read_like(_, _), do: {:error, :malformed_body}

  defp strip_cstring(binary) do
    case :binary.split(binary, <<0>>) do
      [name, rest] -> {:ok, name, rest}
      _ -> :error
    end
  end

  defp strip_two_cstrings(binary) do
    with {:ok, first, rest} <- strip_cstring(binary),
         {:ok, second, <<>>} <- strip_cstring(rest) do
      {:ok, first, second}
    else
      _ -> :error
    end
  end

  defp decode_forget_list(<<>>, 0, acc), do: {:ok, Enum.reverse(acc)}

  defp decode_forget_list(
         <<nodeid::little-64, nlookup::little-64, rest::binary>>,
         n,
         acc
       )
       when n > 0 do
    decode_forget_list(rest, n - 1, [{nodeid, nlookup} | acc])
  end

  defp decode_forget_list(_, _, _), do: :error
end
