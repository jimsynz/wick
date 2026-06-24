defmodule Wick.MixProject do
  use Mix.Project

  @moduledoc """
  A standalone Elixir library for building FUSE userspace filesystems on the BEAM.
  """
  @version "0.1.0"
  @source_url "https://harton.dev/james/wick"

  def project do
    [
      aliases: aliases(),
      app: :wick,
      consolidate_protocols: Mix.env() != :dev,
      deps: deps(),
      description: @moduledoc,
      dialyzer: [plt_add_apps: [:mix]],
      docs: docs(),
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      package: package(),
      source_url: @source_url,
      start_permanent: Mix.env() == :prod,
      version: @version
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp package do
    [
      maintainers: ["James Harton <james@harton.dev>"],
      licenses: ["Apache-2.0"],
      links: %{
        "Source" => @source_url,
        "Changelog" => "#{@source_url}/src/branch/main/CHANGELOG.md"
      },
      files: [
        "lib",
        "native/wick/src",
        "native/wick/Cargo.toml",
        "Cargo.toml",
        "Cargo.lock",
        "mix.exs",
        "README.md",
        "LICENSE",
        "CHANGELOG.md",
        ".formatter.exs"
      ]
    ]
  end

  defp aliases, do: []

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md", "LICENSE"],
      source_ref: "v#{@version}",
      source_url: @source_url
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:rustler, "~> 0.38"},

      # dev/test
      {:stream_data, "~> 1.1", only: [:dev, :test]},
      {:credo, "~> 1.6", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:doctor, "~> 0.22", only: [:dev, :test], runtime: false},
      {:ex_check, "~> 0.16", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40", only: [:dev, :test], runtime: false},
      {:git_ops, "~> 2.4", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.0", only: [:dev, :test], runtime: false}
    ]
  end
end
