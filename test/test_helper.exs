fuse_available? = File.exists?("/dev/fuse") and System.find_executable("fusermount3") != nil
nif_available? = match?({:unix, :linux}, :os.type())

exclude =
  [fuse: not fuse_available?, nif: not nif_available?]
  |> Enum.filter(fn {_tag, excluded?} -> excluded? end)
  |> Keyword.keys()

ExUnit.configure(exclude: exclude)
ExUnit.start(capture_log: true)
