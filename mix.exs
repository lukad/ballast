defmodule Ballast.MixProject do
  use Mix.Project

  def project do
    [
      app: :ballast,
      version: "0.1.0",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      package: package(),
      source_url: "https://github.com/lukad/ballast",
      name: "Ballast",
      description: "Timing-balanced test sharding for ExUnit.",
      docs: docs()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  def cli do
    [
      preferred_envs: [
        precommit: :test,
        "ballast.test": :test,
        "ballast.merge": :test,
        "ballast.plan": :test
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:quokka, "~> 2.13", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.0", only: [:dev, :test]}
    ]
  end

  defp aliases do
    [
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        "credo",
        "test"
      ]
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md",
        {"LICENSE-APACHE", title: "Apache License 2.0"},
        {"LICENSE-MIT", title: "MIT License"}
      ]
    ]
  end

  defp package do
    [
      licenses: ["MIT", "Apache-2.0"],
      links: %{
        "GitHub" => "https://github.com/lukad/ballast",
        "Documentation" => "https://hexdocs.pm/ballast"
      }
    ]
  end
end
