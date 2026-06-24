defmodule Wick.NativeTest do
  use ExUnit.Case, async: true

  alias Wick.Native

  doctest Native

  describe "pipe_pair-based round-trip" do
    test "select_read delivers ready_input when data arrives, read_frame returns it" do
      assert {:ok, {read_fd, write_fd}} = Native.pipe_pair()
      assert is_reference(read_fd)
      assert is_reference(write_fd)

      assert :ok = Native.select_read(read_fd)
      # Nothing in the pipe yet — no select message.
      refute_received {:select, _, _, _}

      assert :ok = Native.write_frame(write_fd, "hello")

      assert_receive {:select, received_fd, :undefined, :ready_input}, 1_000
      assert received_fd == read_fd

      assert {:ok, "hello"} = Native.read_frame(read_fd)
    end

    test "read_frame returns :eagain when the pipe is empty" do
      assert {:ok, {read_fd, _write_fd}} = Native.pipe_pair()
      assert {:error, :eagain} = Native.read_frame(read_fd)
    end

    test "select_read must be re-armed after each notification" do
      assert {:ok, {read_fd, write_fd}} = Native.pipe_pair()

      assert :ok = Native.select_read(read_fd)
      assert :ok = Native.write_frame(write_fd, "frame-1")
      assert_receive {:select, ^read_fd, :undefined, :ready_input}, 1_000
      assert {:ok, "frame-1"} = Native.read_frame(read_fd)

      # Re-arm for the next frame.
      assert :ok = Native.select_read(read_fd)
      assert :ok = Native.write_frame(write_fd, "frame-2")
      assert_receive {:select, ^read_fd, :undefined, :ready_input}, 1_000
      assert {:ok, "frame-2"} = Native.read_frame(read_fd)
    end

    test "write_frame round-trips a multi-KiB binary frame" do
      assert {:ok, {read_fd, write_fd}} = Native.pipe_pair()
      # Stay well under the default Linux pipe buffer (64 KiB) so pipe(2)
      # behaves atomically — on `/dev/fuse` itself, frames up to the FUSE
      # max_write (128 KiB) are always atomic.
      payload = :crypto.strong_rand_bytes(32 * 1024)

      assert :ok = Native.select_read(read_fd)
      assert :ok = Native.write_frame(write_fd, payload)
      assert_receive {:select, ^read_fd, :undefined, :ready_input}, 1_000

      assert {:ok, ^payload} = Native.read_frame(read_fd)
    end
  end

  describe "socketpair_stream" do
    test "returns two bidirectional handles that exchange frames either direction" do
      assert {:ok, {a, b}} = Native.socketpair_stream()
      assert is_reference(a)
      assert is_reference(b)

      assert :ok = Native.select_read(a)
      assert :ok = Native.write_frame(b, "from-b")
      assert_receive {:select, ^a, :undefined, :ready_input}, 1_000
      assert {:ok, "from-b"} = Native.read_frame(a)

      assert :ok = Native.select_read(b)
      assert :ok = Native.write_frame(a, "from-a")
      assert_receive {:select, ^b, :undefined, :ready_input}, 1_000
      assert {:ok, "from-a"} = Native.read_frame(b)
    end
  end

  describe "open_dev_fuse" do
    test "returns a handle on FUSE-capable hosts or a known error atom otherwise" do
      case Native.open_dev_fuse() do
        {:ok, fd} ->
          assert is_reference(fd)

        {:error, reason} ->
          # Hosts without FUSE support (no /dev/fuse, no permission,
          # container restrictions) return a known errno atom rather than
          # crashing the NIF.
          assert reason in [:enoent, :eperm, :enodev, :enosys]
      end
    end
  end
end
