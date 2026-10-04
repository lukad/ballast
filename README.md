# Ballast

Ballast splits your ExUnit suite across parallel CI runners using recorded test timings, so every shard finishes at about the same time.

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `ballast` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:ballast, "~> 0.1.0", only: [:dev, :test], runtime: :false}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/ballast>.

## License

Licensed under either of:

- [Apache License, Version 2.0](./LICENSE-APACHE)
- [MIT license](./LICENSE-MIT)

at your option.

Unless you explicitly state otherwise, any contribution intentionally submitted
for inclusion in this project shall be dual licensed as above, without any
additional terms or conditions.
