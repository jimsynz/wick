defmodule Wick.ProtocolTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Wick.Protocol
  alias Wick.Protocol.{Attr, InHeader, Request, Response}

  doctest Protocol

  describe "InHeader" do
    test "split/1 splits a 40-byte header + body and validates len" do
      body = <<1, 2, 3>>

      header = %InHeader{
        len: 40 + byte_size(body),
        opcode: 26,
        unique: 0xDEAD_BEEF,
        nodeid: 1,
        uid: 1000,
        gid: 1000,
        pid: 4321
      }

      frame = InHeader.encode(header) <> body
      assert {:ok, ^header, ^body} = InHeader.split(frame)
    end

    test "split/1 rejects a frame whose len disagrees with its actual size" do
      header = %InHeader{
        len: 999,
        opcode: 26,
        unique: 1,
        nodeid: 1,
        uid: 0,
        gid: 0,
        pid: 0
      }

      frame = InHeader.encode(header) <> <<1, 2>>
      assert {:error, {:length_mismatch, 999, 42}} = InHeader.split(frame)
    end

    test "split/1 rejects frames shorter than the header" do
      assert {:error, :short_header} = InHeader.split(<<1, 2, 3>>)
    end
  end

  describe "decode_request/1 dispatch" do
    test "returns :unknown_opcode for opcodes outside the codec's scope" do
      # Opcode 39 (FUSE_IOCTL) is not currently supported.
      header = build_header(opcode: 39, len: 40 + 8)
      body = <<0::little-64>>
      assert {:error, {:unknown_opcode, 39}} = Protocol.decode_request(header <> body)
    end

    test "returns {:ok, opcode, header, request} on a valid INIT frame" do
      init_body = <<7::little-32, 31::little-32, 32_768::little-32, 0::little-32>>
      header = build_header(opcode: 26, len: 40 + byte_size(init_body), unique: 42)
      frame = header <> init_body

      assert {:ok, :init, %InHeader{unique: 42}, %Request.Init{major: 7, minor: 31}} =
               Protocol.decode_request(frame)
    end

    test "surfaces :malformed_body when an opcode's layout is wrong" do
      # OPEN expects exactly 8 bytes; give it 4.
      short = <<0::little-32>>
      header = build_header(opcode: 14, len: 40 + 4)
      assert {:error, :malformed_body} = Protocol.decode_request(header <> short)
    end
  end

  describe "encode_response/3" do
    test "emits a header-only error frame when error != 0" do
      bytes = Protocol.encode_response(99, nil, -2)
      assert <<16::little-32, -2::little-signed-32, 99::little-64>> == bytes
    end

    test "prepends a 16-byte out-header with the correct total length" do
      reply = %Response.Write{size: 1024}
      bytes = :erlang.iolist_to_binary(Protocol.encode_response(7, reply, 0))

      assert <<total::little-32, 0::little-signed-32, 7::little-64, _body::binary>> = bytes
      assert total == byte_size(bytes)
      assert total == 16 + 8
    end

    test "encode_error/2 matches encode_response/3 with nil body" do
      assert Protocol.encode_error(1, -5) == Protocol.encode_response(1, nil, -5)
    end
  end

  describe "property: decode after encode round-trips each opcode" do
    property "init" do
      check all(req <- request(:init)) do
        assert_round_trip(:init, req)
      end
    end

    property "destroy" do
      assert_round_trip(:destroy, %Request.Destroy{})
    end

    property "lookup" do
      check all(req <- request(:lookup)) do
        assert_round_trip(:lookup, req)
      end
    end

    property "forget" do
      check all(req <- request(:forget)) do
        assert_round_trip(:forget, req)
      end
    end

    property "batch_forget" do
      check all(req <- request(:batch_forget)) do
        assert_round_trip(:batch_forget, req)
      end
    end

    property "getattr" do
      check all(req <- request(:getattr)) do
        assert_round_trip(:getattr, req)
      end
    end

    property "setattr" do
      check all(req <- request(:setattr)) do
        assert_round_trip(:setattr, req)
      end
    end

    property "mkdir" do
      check all(req <- request(:mkdir)) do
        assert_round_trip(:mkdir, req)
      end
    end

    property "unlink" do
      check all(req <- request(:unlink)) do
        assert_round_trip(:unlink, req)
      end
    end

    property "rmdir" do
      check all(req <- request(:rmdir)) do
        assert_round_trip(:rmdir, req)
      end
    end

    property "rename" do
      check all(req <- request(:rename)) do
        assert_round_trip(:rename, req)
      end
    end

    property "rename2" do
      check all(req <- request(:rename2)) do
        assert_round_trip(:rename2, req)
      end
    end

    property "open" do
      check all(req <- request(:open)) do
        assert_round_trip(:open, req)
      end
    end

    property "release" do
      check all(req <- request(:release)) do
        assert_round_trip(:release, req)
      end
    end

    property "read" do
      check all(req <- request(:read)) do
        assert_round_trip(:read, req)
      end
    end

    property "readdir" do
      check all(req <- request(:readdir)) do
        assert_round_trip(:readdir, req)
      end
    end

    property "readdirplus" do
      check all(req <- request(:readdirplus)) do
        assert_round_trip(:readdirplus, req)
      end
    end

    property "write" do
      check all(req <- request(:write)) do
        assert_round_trip(:write, req)
      end
    end

    property "statfs" do
      assert_round_trip(:statfs, %Request.Statfs{})
    end

    property "flush" do
      check all(req <- request(:flush)) do
        assert_round_trip(:flush, req)
      end
    end

    property "fsync" do
      check all(req <- request(:fsync)) do
        assert_round_trip(:fsync, req)
      end
    end

    property "create" do
      check all(req <- request(:create)) do
        assert_round_trip(:create, req)
      end
    end
  end

  describe "property: response encoders produce the documented byte sizes" do
    property "Init encodes to exactly 64 bytes" do
      check all(reply <- response(:init)) do
        assert byte_size(:erlang.iolist_to_binary(Response.encode(reply))) == 64
      end
    end

    property "Entry encodes to exactly 128 bytes" do
      check all(reply <- response(:entry)) do
        assert byte_size(:erlang.iolist_to_binary(Response.encode(reply))) == 128
      end
    end

    property "AttrReply encodes to exactly 104 bytes" do
      check all(reply <- response(:attr)) do
        assert byte_size(:erlang.iolist_to_binary(Response.encode(reply))) == 104
      end
    end

    property "Open encodes to exactly 16 bytes" do
      check all(reply <- response(:open)) do
        assert byte_size(:erlang.iolist_to_binary(Response.encode(reply))) == 16
      end
    end

    property "CreateReply encodes to exactly 144 bytes (entry + open)" do
      check all(reply <- response(:create)) do
        assert byte_size(:erlang.iolist_to_binary(Response.encode(reply))) == 144
      end
    end

    property "Write encodes to exactly 8 bytes" do
      check all(reply <- response(:write)) do
        assert byte_size(:erlang.iolist_to_binary(Response.encode(reply))) == 8
      end
    end

    property "Statfs encodes to exactly 80 bytes" do
      check all(reply <- response(:statfs)) do
        assert byte_size(:erlang.iolist_to_binary(Response.encode(reply))) == 80
      end
    end
  end

  describe "Readdir dirent packing" do
    property "each record is padded to an 8-byte boundary and round-trips" do
      check all(entries <- list_of(dirent(), max_length: 8)) do
        reply = %Response.Readdir{entries: entries}
        encoded = :erlang.iolist_to_binary(Response.encode(reply))

        # Total length must be a multiple of 8.
        assert rem(byte_size(encoded), 8) == 0

        assert {:ok, decoded} = Response.decode_dirents(encoded)
        assert decoded == entries
      end
    end
  end

  describe "ReaddirPlus direntplus packing" do
    property "each record is fuse_entry_out + fuse_dirent and round-trips" do
      check all(entries <- list_of(direntplus(), max_length: 6)) do
        reply = %Response.ReaddirPlus{entries: entries}
        encoded = :erlang.iolist_to_binary(Response.encode(reply))

        assert rem(byte_size(encoded), 8) == 0

        assert {:ok, decoded} = Response.decode_direntpluses(encoded)
        assert decoded == entries
      end
    end
  end

  # ——— Fixtures ————————————————————————————————————————————————

  describe "byte-for-byte fixtures (from Linux fuse.h v7.31)" do
    test "in_header decodes a hand-crafted frame with known values" do
      bin = <<
        # len = 40
        40::little-32,
        # opcode = FUSE_DESTROY (38)
        38::little-32,
        # unique
        0xAA_BB_CC_DD_EE_FF_00_11::little-64,
        # nodeid
        0::little-64,
        # uid, gid, pid
        1000::little-32,
        1001::little-32,
        4321::little-32,
        0::little-32
      >>

      assert {:ok, %InHeader{opcode: 38, unique: 0xAA_BB_CC_DD_EE_FF_00_11}, <<>>} =
               InHeader.split(bin)
    end

    test "lookup request body with name 'foo' decodes to the name without NUL" do
      body = <<"foo", 0>>
      assert {:ok, %Request.Lookup{name: "foo"}} = Request.decode(:lookup, body)
    end

    test "mkdir body encodes mode, umask, and NUL-terminated name" do
      body = <<0o755::little-32, 0o022::little-32, "newdir", 0>>

      assert {:ok, %Request.Mkdir{mode: 0o755, umask: 0o022, name: "newdir"}} =
               Request.decode(:mkdir, body)
    end

    test "rename body concatenates oldname and newname with NULs" do
      body = <<42::little-64, "a", 0, "b", 0>>

      assert {:ok, %Request.Rename{newdir: 42, oldname: "a", newname: "b"}} =
               Request.decode(:rename, body)
    end

    test "batch_forget with two entries is decoded in order" do
      body = <<
        2::little-32,
        0::little-32,
        10::little-64,
        1::little-64,
        20::little-64,
        2::little-64
      >>

      assert {:ok, %Request.BatchForget{items: [{10, 1}, {20, 2}]}} =
               Request.decode(:batch_forget, body)
    end

    test "setxattr decodes the size+flags header, NUL-terminated name, and value" do
      value = "bar"
      body = <<byte_size(value)::little-32, 1::little-32, "user.foo", 0, value::binary>>

      assert {:ok, %Request.SetXattr{size: 3, flags: 1, name: "user.foo", value: "bar"}} =
               Request.decode(:setxattr, body)
    end

    test "setxattr rejects a body whose declared size mismatches the trailing value" do
      body = <<5::little-32, 0::little-32, "user.x", 0, "bar"::binary>>
      assert {:error, :malformed_body} = Request.decode(:setxattr, body)
    end

    test "getxattr decodes the size header and NUL-terminated name" do
      body = <<128::little-32, 0::little-32, "user.foo", 0>>

      assert {:ok, %Request.GetXattr{size: 128, name: "user.foo"}} =
               Request.decode(:getxattr, body)
    end

    test "listxattr decodes the size header (no name)" do
      body = <<256::little-32, 0::little-32>>
      assert {:ok, %Request.ListXattr{size: 256}} = Request.decode(:listxattr, body)
    end

    test "removexattr decodes the NUL-terminated name only" do
      body = <<"user.foo", 0>>
      assert {:ok, %Request.RemoveXattr{name: "user.foo"}} = Request.decode(:removexattr, body)
    end

    test "xattr opcode numbers match Linux fuse.h v7.31" do
      assert Wick.Protocol.atom_to_opcode(:setxattr) == 21
      assert Wick.Protocol.atom_to_opcode(:getxattr) == 22
      assert Wick.Protocol.atom_to_opcode(:listxattr) == 23
      assert Wick.Protocol.atom_to_opcode(:removexattr) == 24
    end

    test "lock opcode numbers match Linux fuse.h v7.31" do
      assert Wick.Protocol.atom_to_opcode(:getlk) == 31
      assert Wick.Protocol.atom_to_opcode(:setlk) == 32
      assert Wick.Protocol.atom_to_opcode(:setlkw) == 33
    end

    test "setlk decodes fuse_lk_in (48 bytes) with FLOCK lk_flags" do
      body = <<
        # fh
        7::little-64,
        # owner
        0xDEAD_BEEF::little-64,
        # lk.start
        0::little-64,
        # lk.end
        0::little-64,
        # lk.type — F_WRLCK
        1::little-32,
        # lk.pid
        4321::little-32,
        # lk_flags — FUSE_LK_FLOCK
        1::little-32,
        # padding
        0::little-32
      >>

      assert {:ok,
              %Request.SetLk{
                fh: 7,
                owner: 0xDEAD_BEEF,
                lk: %Request.FileLock{start: 0, end: 0, type: 1, pid: 4321},
                lk_flags: 1
              }} = Request.decode(:setlk, body)
    end

    test "setlkw shares the SetLk struct shape" do
      body = <<
        7::little-64,
        0::little-64,
        0::little-64,
        0::little-64,
        0::little-32,
        1::little-32,
        1::little-32,
        0::little-32
      >>

      assert {:ok, %Request.SetLk{lk_flags: 1, lk: %Request.FileLock{type: 0}}} =
               Request.decode(:setlkw, body)
    end

    test "getlk decodes the same wire layout into GetLk" do
      body = <<
        9::little-64,
        0::little-64,
        100::little-64,
        200::little-64,
        1::little-32,
        9999::little-32,
        0::little-32,
        0::little-32
      >>

      assert {:ok,
              %Request.GetLk{
                fh: 9,
                lk: %Request.FileLock{start: 100, end: 200, type: 1, pid: 9999},
                lk_flags: 0
              }} = Request.decode(:getlk, body)
    end

    test "lock decoder rejects bodies that aren't 48 bytes" do
      assert {:error, :malformed_body} = Request.decode(:setlk, <<>>)
      assert {:error, :malformed_body} = Request.decode(:setlk, <<0::little-64>>)
    end

    test "interrupt opcode number matches Linux fuse.h v7.31" do
      assert Wick.Protocol.atom_to_opcode(:interrupt) == 36
    end

    test "interrupt decodes the 8-byte target unique" do
      body = <<0xCAFE_F00D_DEAD_BEEF::little-64>>

      assert {:ok, %Request.Interrupt{unique: 0xCAFE_F00D_DEAD_BEEF}} =
               Request.decode(:interrupt, body)
    end

    test "interrupt rejects malformed bodies" do
      assert {:error, :malformed_body} = Request.decode(:interrupt, <<>>)
      assert {:error, :malformed_body} = Request.decode(:interrupt, <<0::little-32>>)
    end
  end

  describe "GetLkReply encoder (#672)" do
    test "encodes fuse_lk_out as 24 bytes (start + end + type + pid)" do
      reply = %Response.GetLkReply{start: 100, end: 200, type: 2, pid: 4321}

      assert <<100::little-64, 200::little-64, 2::little-32, 4321::little-32>> ==
               :erlang.iolist_to_binary(Response.encode(reply))
    end
  end

  describe "xattr response encoders (#671)" do
    test "XattrSize encodes as fuse_getxattr_out (8 bytes: size + padding)" do
      assert <<42::little-32, 0::little-32>> ==
               Response.encode(%Response.XattrSize{size: 42})
    end

    test "XattrData encodes as raw bytes" do
      assert "user.a\0user.b\0" ==
               :erlang.iolist_to_binary(
                 Response.encode(%Response.XattrData{data: "user.a\0user.b\0"})
               )
    end

    test "Empty body encodes a zero-byte payload (used by SETXATTR / REMOVEXATTR)" do
      assert [] == Response.encode(%Response.Empty{})
    end
  end

  # ——— Helpers ——————————————————————————————————————————————————

  defp build_header(opts) do
    header = %InHeader{
      len: Keyword.fetch!(opts, :len),
      opcode: Keyword.fetch!(opts, :opcode),
      unique: Keyword.get(opts, :unique, 1),
      nodeid: Keyword.get(opts, :nodeid, 1),
      uid: 0,
      gid: 0,
      pid: 0
    }

    InHeader.encode(header)
  end

  defp assert_round_trip(opcode, %_{} = req) do
    body = encode_request(opcode, req)
    header = build_header(opcode: Protocol.atom_to_opcode(opcode), len: 40 + byte_size(body))
    frame = header <> body

    assert {:ok, ^opcode, _header, ^req} = Protocol.decode_request(frame)
  end

  # Encoders for request structs — test-only helpers that mirror the
  # kernel's on-wire encoding. The production codec only decodes
  # requests; we need the reverse here to drive round-trip checks.

  defp encode_request(:init, %Request.Init{} = r) do
    <<r.major::little-32, r.minor::little-32, r.max_readahead::little-32, r.flags::little-32>>
  end

  defp encode_request(:destroy, %Request.Destroy{}), do: <<>>

  defp encode_request(:lookup, %Request.Lookup{name: n}), do: <<n::binary, 0>>

  defp encode_request(:forget, %Request.Forget{nlookup: n}), do: <<n::little-64>>

  defp encode_request(:batch_forget, %Request.BatchForget{items: items}) do
    count = length(items)
    entries = for {node, look} <- items, into: <<>>, do: <<node::little-64, look::little-64>>
    <<count::little-32, 0::little-32, entries::binary>>
  end

  defp encode_request(:getattr, %Request.GetAttr{getattr_flags: f, fh: fh}) do
    <<f::little-32, 0::little-32, fh::little-64>>
  end

  defp encode_request(:setattr, %Request.SetAttr{} = r) do
    <<
      r.valid::little-32,
      0::little-32,
      r.fh::little-64,
      r.size::little-64,
      r.lock_owner::little-64,
      r.atime::little-64,
      r.mtime::little-64,
      r.ctime::little-64,
      r.atimensec::little-32,
      r.mtimensec::little-32,
      r.ctimensec::little-32,
      r.mode::little-32,
      0::little-32,
      r.uid::little-32,
      r.gid::little-32,
      0::little-32
    >>
  end

  defp encode_request(:mkdir, %Request.Mkdir{mode: m, umask: u, name: n}) do
    <<m::little-32, u::little-32, n::binary, 0>>
  end

  defp encode_request(:unlink, %Request.Unlink{name: n}), do: <<n::binary, 0>>
  defp encode_request(:rmdir, %Request.Rmdir{name: n}), do: <<n::binary, 0>>

  defp encode_request(:rename, %Request.Rename{} = r) do
    <<r.newdir::little-64, r.oldname::binary, 0, r.newname::binary, 0>>
  end

  defp encode_request(:rename2, %Request.Rename2{} = r) do
    <<r.newdir::little-64, r.flags::little-32, 0::little-32, r.oldname::binary, 0,
      r.newname::binary, 0>>
  end

  defp encode_request(:open, %Request.Open{flags: f}), do: <<f::little-32, 0::little-32>>

  defp encode_request(:release, %Request.Release{} = r) do
    <<r.fh::little-64, r.flags::little-32, r.release_flags::little-32, r.lock_owner::little-64>>
  end

  defp encode_request(:read, %Request.Read{} = r), do: encode_read_like(r)
  defp encode_request(:readdir, %Request.Readdir{} = r), do: encode_read_like(r)
  defp encode_request(:readdirplus, %Request.ReaddirPlus{} = r), do: encode_read_like(r)

  defp encode_request(:write, %Request.Write{} = r) do
    <<
      r.fh::little-64,
      r.offset::little-64,
      r.size::little-32,
      r.write_flags::little-32,
      r.lock_owner::little-64,
      r.flags::little-32,
      0::little-32,
      r.data::binary
    >>
  end

  defp encode_request(:statfs, %Request.Statfs{}), do: <<>>

  defp encode_request(:flush, %Request.Flush{fh: fh, lock_owner: lo}) do
    <<fh::little-64, 0::little-32, 0::little-32, lo::little-64>>
  end

  defp encode_request(:fsync, %Request.Fsync{fh: fh, fsync_flags: f}) do
    <<fh::little-64, f::little-32, 0::little-32>>
  end

  defp encode_request(:create, %Request.Create{} = r) do
    <<r.flags::little-32, r.mode::little-32, r.umask::little-32, 0::little-32, r.name::binary, 0>>
  end

  defp encode_read_like(r) do
    <<
      r.fh::little-64,
      r.offset::little-64,
      r.size::little-32,
      r.read_flags::little-32,
      r.lock_owner::little-64,
      r.flags::little-32,
      0::little-32
    >>
  end

  # ——— Generators ————————————————————————————————————————————————

  defp u32, do: integer(0..0xFFFF_FFFF)
  defp u64, do: integer(0..0xFFFF_FFFF_FFFF_FFFF)
  defp u16, do: integer(0..0xFFFF)

  defp name_gen do
    gen all(
          bytes <- binary(min_length: 1, max_length: 16),
          not String.contains?(bytes, <<0>>)
        ) do
      bytes
    end
  end

  defp attr_gen do
    gen all(
          ino <- u64(),
          size <- u64(),
          blocks <- u64(),
          atime <- u64(),
          mtime <- u64(),
          ctime <- u64(),
          atimensec <- u32(),
          mtimensec <- u32(),
          ctimensec <- u32(),
          mode <- u32(),
          nlink <- u32(),
          uid <- u32(),
          gid <- u32(),
          rdev <- u32(),
          blksize <- u32()
        ) do
      %Attr{
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
      }
    end
  end

  defp dirent do
    gen all(
          ino <- u64(),
          off <- u64(),
          type <- integer(0..255),
          name <- name_gen()
        ) do
      %Response.Dirent{ino: ino, off: off, type: type, name: name}
    end
  end

  defp direntplus do
    gen all(entry <- response(:entry), de <- dirent()) do
      %Response.DirentPlus{entry: entry, dirent: de}
    end
  end

  defp request(:init), do: gen_init()
  defp request(:lookup), do: gen_map(&%Request.Lookup{name: &1}, name_gen())
  defp request(:forget), do: gen_map(&%Request.Forget{nlookup: &1}, u64())
  defp request(:batch_forget), do: gen_batch_forget()
  defp request(:getattr), do: gen_getattr()
  defp request(:setattr), do: gen_setattr()
  defp request(:mkdir), do: gen_mkdir()
  defp request(:unlink), do: gen_map(&%Request.Unlink{name: &1}, name_gen())
  defp request(:rmdir), do: gen_map(&%Request.Rmdir{name: &1}, name_gen())
  defp request(:rename), do: gen_rename()
  defp request(:rename2), do: gen_rename2()
  defp request(:open), do: gen_map(&%Request.Open{flags: &1}, u32())
  defp request(:release), do: gen_release()
  defp request(:read), do: gen_read_like(Request.Read)
  defp request(:readdir), do: gen_read_like(Request.Readdir)
  defp request(:readdirplus), do: gen_read_like(Request.ReaddirPlus)
  defp request(:write), do: gen_write()
  defp request(:flush), do: gen_flush()
  defp request(:fsync), do: gen_fsync()
  defp request(:create), do: gen_create()

  defp gen_init do
    gen all(major <- u32(), minor <- u32(), mra <- u32(), flags <- u32()) do
      %Request.Init{major: major, minor: minor, max_readahead: mra, flags: flags}
    end
  end

  defp gen_batch_forget do
    gen all(items <- list_of({u64(), u64()}, max_length: 4)) do
      %Request.BatchForget{items: items}
    end
  end

  defp gen_getattr do
    gen all(flags <- u32(), fh <- u64()) do
      %Request.GetAttr{getattr_flags: flags, fh: fh}
    end
  end

  defp gen_setattr do
    gen all(
          valid <- u32(),
          fh <- u64(),
          size <- u64(),
          lock_owner <- u64(),
          atime <- u64(),
          mtime <- u64(),
          ctime <- u64(),
          atimensec <- u32(),
          mtimensec <- u32(),
          ctimensec <- u32(),
          mode <- u32(),
          uid <- u32(),
          gid <- u32()
        ) do
      %Request.SetAttr{
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
      }
    end
  end

  defp gen_mkdir do
    gen all(mode <- u32(), umask <- u32(), name <- name_gen()) do
      %Request.Mkdir{mode: mode, umask: umask, name: name}
    end
  end

  defp gen_rename do
    gen all(newdir <- u64(), oldname <- name_gen(), newname <- name_gen()) do
      %Request.Rename{newdir: newdir, oldname: oldname, newname: newname}
    end
  end

  defp gen_rename2 do
    gen all(newdir <- u64(), flags <- u32(), oldname <- name_gen(), newname <- name_gen()) do
      %Request.Rename2{newdir: newdir, flags: flags, oldname: oldname, newname: newname}
    end
  end

  defp gen_release do
    gen all(fh <- u64(), flags <- u32(), release_flags <- u32(), lock_owner <- u64()) do
      %Request.Release{
        fh: fh,
        flags: flags,
        release_flags: release_flags,
        lock_owner: lock_owner
      }
    end
  end

  defp gen_read_like(mod) do
    gen all(
          fh <- u64(),
          offset <- u64(),
          size <- u32(),
          read_flags <- u32(),
          lock_owner <- u64(),
          flags <- u32()
        ) do
      struct(mod,
        fh: fh,
        offset: offset,
        size: size,
        read_flags: read_flags,
        lock_owner: lock_owner,
        flags: flags
      )
    end
  end

  defp gen_write do
    gen all(
          fh <- u64(),
          offset <- u64(),
          write_flags <- u32(),
          lock_owner <- u64(),
          flags <- u32(),
          data <- binary(max_length: 64)
        ) do
      %Request.Write{
        fh: fh,
        offset: offset,
        size: byte_size(data),
        write_flags: write_flags,
        lock_owner: lock_owner,
        flags: flags,
        data: data
      }
    end
  end

  defp gen_flush do
    gen all(fh <- u64(), lock_owner <- u64()) do
      %Request.Flush{fh: fh, lock_owner: lock_owner}
    end
  end

  defp gen_fsync do
    gen all(fh <- u64(), fsync_flags <- u32()) do
      %Request.Fsync{fh: fh, fsync_flags: fsync_flags}
    end
  end

  defp gen_create do
    gen all(flags <- u32(), mode <- u32(), umask <- u32(), name <- name_gen()) do
      %Request.Create{flags: flags, mode: mode, umask: umask, name: name}
    end
  end

  defp gen_map(fun, gen) do
    gen(all(v <- gen, do: fun.(v)))
  end

  # Response generators (for size-invariant properties)
  defp response(:init) do
    gen all(
          major <- u32(),
          minor <- u32(),
          mra <- u32(),
          flags <- u32(),
          mbg <- u16(),
          cthr <- u16(),
          mw <- u32(),
          tg <- u32(),
          mp <- u16(),
          ma <- u16()
        ) do
      %Response.Init{
        major: major,
        minor: minor,
        max_readahead: mra,
        flags: flags,
        max_background: mbg,
        congestion_threshold: cthr,
        max_write: mw,
        time_gran: tg,
        max_pages: mp,
        map_alignment: ma
      }
    end
  end

  defp response(:entry) do
    gen all(
          nodeid <- u64(),
          generation <- u64(),
          ev <- u64(),
          av <- u64(),
          evn <- u32(),
          avn <- u32(),
          attr <- attr_gen()
        ) do
      %Response.Entry{
        nodeid: nodeid,
        generation: generation,
        entry_valid: ev,
        attr_valid: av,
        entry_valid_nsec: evn,
        attr_valid_nsec: avn,
        attr: attr
      }
    end
  end

  defp response(:attr) do
    gen all(av <- u64(), ans <- u32(), attr <- attr_gen()) do
      %Response.AttrReply{attr_valid: av, attr_valid_nsec: ans, attr: attr}
    end
  end

  defp response(:open) do
    gen all(fh <- u64(), flags <- u32()) do
      %Response.Open{fh: fh, open_flags: flags}
    end
  end

  defp response(:create) do
    gen all(entry <- response(:entry), open <- response(:open)) do
      %Response.CreateReply{entry: entry, open: open}
    end
  end

  defp response(:write) do
    gen all(size <- u32()) do
      %Response.Write{size: size}
    end
  end

  defp response(:statfs) do
    gen all(
          blocks <- u64(),
          bfree <- u64(),
          bavail <- u64(),
          files <- u64(),
          ffree <- u64(),
          bsize <- u32(),
          namelen <- u32(),
          frsize <- u32()
        ) do
      %Response.Statfs{
        blocks: blocks,
        bfree: bfree,
        bavail: bavail,
        files: files,
        ffree: ffree,
        bsize: bsize,
        namelen: namelen,
        frsize: frsize
      }
    end
  end
end
