[
  parallel: true,
  skipped: true,
  tools: [
    # Elixir tools
    # `--force` so Rustler always regenerates priv/native/wick.so before the
    # NIF-loading tools (ex_unit, doctor, ex_doc) run. A cache-restored,
    # up-to-date build otherwise skips the Rustler step and leaves the .so
    # absent, since it lives outside the cached _build tree.
    {:compiler, "mix compile --force --warnings-as-errors"},
    {:formatter, "mix format --check-formatted"},
    {:credo, "mix credo --strict"},
    {:dialyzer, "mix dialyzer"},
    {:doctor, "mix doctor"},
    {:ex_doc, "mix docs"},
    {:audit, "mix deps.audit"},
    {:gettext, false},
    {:sobelow, false},

    # Rust tools
    {:cargo_fmt, command: "cargo fmt --check --manifest-path native/wick/Cargo.toml"},
    {:cargo_clippy,
     command:
       "cargo clippy --manifest-path native/wick/Cargo.toml --all-targets -- -D warnings"},
    {:cargo_test, command: "cargo test --manifest-path native/wick/Cargo.toml"}
  ]
]
