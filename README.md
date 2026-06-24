# Wick

A standalone Elixir library for building FUSE userspace filesystems on
the BEAM — without libfuse bindings or a native event loop. The only
native code is a minimal syscall NIF; everything above the file
descriptor (frame parsing, protocol encoding, your filesystem logic)
is ordinary supervised Elixir.

Two layers:

- **Transport** (`Wick.Native`, `Wick.Fusermount`) — opens `/dev/fuse`,
  mounts via the `fusermount3` userspace helper, `enif_select`-based
  readiness notifications, and a bounded read/write API for protocol
  frames. No `CAP_SYS_ADMIN` needed.
- **Codec** (`Wick.Protocol`) — a pure-Elixir codec for the Linux FUSE
  kernel protocol (FUSE_KERNEL_VERSION 7.31, as exposed by libfuse
  3.10+ / Linux 5.4+). Operates on binaries only — no I/O, so it is
  testable without a kernel in sight.

## Installation

Add `wick` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [{:wick, "~> 0.1.0"}]
end
```

Wick compiles a small Rust NIF via [Rustler](https://hexdocs.pm/rustler),
so a Rust toolchain must be available at build time.

## Writing a filesystem

A FUSE server is an event loop: mount, wait for a readiness
notification, read a request frame, decode it, write a reply, re-arm,
repeat. The kernel's first request is always `INIT`, and nothing else
works until you answer it.

The [Writing a filesystem](documentation/guides/writing-a-filesystem.md)
guide builds a complete read-only filesystem from scratch and is the
best place to start. The primitive below shows the raw transport and
codec call sequence those servers are built from.

## Mount and serve

```elixir
{:ok, handle} =
  Wick.Fusermount.mount(
    "/tmp/my-mount",
    ["fsname=demo", "subtype=demo", "default_permissions"]
  )

:ok = Wick.Native.select_read(handle)

receive do
  {:select, ^handle, :undefined, :ready_input} ->
    {:ok, request_bytes} = Wick.Native.read_frame(handle)
    {:ok, op, header, request} = Wick.Protocol.decode_request(request_bytes)
    # ... build a reply struct for `op` ...
    response_bytes = Wick.Protocol.encode_response(header.unique, reply, 0)
    :ok = Wick.Native.write_frame(handle, response_bytes)
end

:ok = Wick.Fusermount.unmount("/tmp/my-mount")
```

`Wick.Fusermount.mount/2` calls into a NIF that uses `posix_spawn(3)` to
run `fusermount3` with one end of a `socketpair(2)` inherited as fd 3,
then receives the resulting `/dev/fuse` fd via `SCM_RIGHTS`.
`Wick.Fusermount.unmount/1` invokes `fusermount3 -u` via an Erlang
`Port` so the BEAM's child-process management reaps the helper without
colliding with `SIGCHLD = SIG_IGN`.

See `Wick.Native`, `Wick.Fusermount`, and `Wick.Protocol` for full
documentation.

## Tests without /dev/fuse

CI hosts that lack FUSE support can still exercise the transport:

```elixir
{:ok, {read_fd, write_fd}} = Wick.Native.pipe_pair()
```

returns a non-blocking pipe pair wrapped in the same resource type, so
the `select_read` / `read_frame` / `write_frame` path can be driven
end-to-end. Tests that exercise `Wick.Fusermount.mount/2` are tagged
`:fuse` and skipped on hosts where `/dev/fuse` is not available.

## GitHub Mirror

Eventually, [Forgejo](https://www.forgejo.org) will support fully federated operation, but for now there's a [mirror of this repository on GitHub](https://www.github.com/jimsynz/wick) - feel free to open issues and PRs there.

## Licence

Apache-2.0 — see [LICENSE](LICENSE) for details.
