defmodule Wick.FusermountTest do
  use ExUnit.Case, async: false

  alias Wick.Fusermount
  alias Wick.Native

  doctest Fusermount

  describe "unmount/2 input validation" do
    test "returns :enoent if fusermount3 is not on PATH" do
      orig = System.get_env("PATH")
      System.put_env("PATH", "/nonexistent")

      try do
        assert {:error, :enoent} = Fusermount.unmount("/tmp/never-mounted")
      after
        case orig do
          nil -> System.delete_env("PATH")
          value -> System.put_env("PATH", value)
        end
      end
    end

    test "raises ArgumentError on a non-positive timeout" do
      assert_raise ArgumentError, fn ->
        Fusermount.unmount("/tmp/whatever", timeout: 0)
      end
    end
  end

  describe "unmount/2 against fusermount3" do
    @describetag :fuse

    # Tagged `:fuse` because it actually invokes the helper — CI hosts
    # without `fusermount3` on PATH would surface `:enoent` rather than
    # the expected non-zero exit status.
    test "returns {:fusermount, status} for a path that is not mounted" do
      tmp = mktempdir!()

      try do
        assert {:error, {:fusermount, status}} = Fusermount.unmount(tmp)
        assert is_integer(status) and status > 0
      after
        File.rmdir(tmp)
      end
    end
  end

  describe "mount/2 + unmount/2 round trip" do
    @describetag :fuse

    test "mounts, returns a usable handle, and unmounts (lazy)" do
      mount_point = mktempdir!()

      try do
        assert {:ok, handle} =
                 Fusermount.mount(mount_point, [
                   "fsname=wick_test",
                   "subtype=wick_test"
                 ])

        assert is_reference(handle)
        assert mounted?(mount_point), "expected #{mount_point} to be mounted"

        # The handle must be usable with the rest of the transport API. We
        # don't drive the FUSE INIT handshake here — that lives in a later
        # sub-issue — but `select_read/1` should accept the handle and the
        # kernel should already have an INIT request queued for us.
        assert :ok = Native.select_read(handle)
        assert_receive {:select, ^handle, :undefined, :ready_input}, 5_000

        # The test process still holds the FUSE fd, so a regular `umount(2)`
        # would fail with EBUSY. Use lazy unmount: the kernel detaches the
        # mount immediately and finalises once the fd is closed.
        assert :ok = Fusermount.unmount(mount_point, lazy: true)
        refute mounted?(mount_point)
      after
        if mounted?(mount_point), do: Fusermount.unmount(mount_point, lazy: true)
        File.rmdir(mount_point)
      end
    end

    test "returns :fusermount_no_fd when the mount point does not exist" do
      missing =
        Path.join(System.tmp_dir!(), "wick_no_such_dir_#{:rand.uniform(1_000_000)}")

      refute File.exists?(missing)

      assert {:error, :fusermount_no_fd} = Fusermount.mount(missing)
    end
  end

  defp mktempdir! do
    base = System.tmp_dir!()
    name = "wick_mount_#{System.unique_integer([:positive])}"
    path = Path.join(base, name)
    File.mkdir_p!(path)
    path
  end

  defp mounted?(path) do
    case File.read("/proc/mounts") do
      {:ok, contents} -> any_mount_at?(contents, path)
      _ -> false
    end
  end

  defp any_mount_at?(contents, path) do
    contents
    |> String.split("\n", trim: true)
    |> Enum.any?(&mount_line_matches?(&1, path))
  end

  defp mount_line_matches?(line, path) do
    case String.split(line, " ") do
      [_dev, ^path | _] -> true
      _ -> false
    end
  end
end
