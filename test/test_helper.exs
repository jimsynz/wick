if !File.exists?("/dev/fuse") or System.find_executable("fusermount3") == nil do
  ExUnit.configure(exclude: [:fuse])
end

ExUnit.start(capture_log: true)
