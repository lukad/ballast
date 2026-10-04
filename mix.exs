defmodule Ballast.MixProject do
  use Mix.Project

  def project do
    [
      app: :ballast,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      package: package(),
      source_url: "https://github.com/lukad/ballast",
      name: "Ballast",
      description: """
      Splits your ExUnit suite across parallel CI runners using recorded test timings, so every shard finishes at about the same time.
      """
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:quokka, "~> 2.13", only: [:dev, :test], runtime: false}
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
