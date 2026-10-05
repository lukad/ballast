defmodule Ballast.Args do
  @moduledoc """
  Splits `mix ballast.test` arguments into Ballast's own options, positional
  test paths, and everything that goes to `mix test` untouched.

  Telling a positional path from a switch value means knowing which
  `mix test` switches take a value, so that table is copied here. A switch
  missing from the table is still passed through.
  """

  defstruct shard: nil,
            timings: Ballast.Timings.default_path(),
            report: nil,
            record?: true,
            paths: [],
            passthrough: []

  @type t :: %__MODULE__{
          shard: {pos_integer(), pos_integer()} | nil,
          timings: Path.t(),
          report: Path.t() | nil,
          record?: boolean(),
          paths: [String.t()],
          passthrough: [String.t()]
        }

  @own [shard: :string, timings: :string, report: :string, record: :boolean]

  @value [:string]
  @repeat [:string, :keep]

  # Mirrors @switches in Mix.Tasks.Test (Elixir 1.20).
  @mix_test [
    all_warnings: :boolean,
    breakpoints: :boolean,
    force: :boolean,
    color: :boolean,
    cover: :boolean,
    export_coverage: @value,
    trace: :boolean,
    max_cases: @value,
    max_failures: @value,
    max_requires: @value,
    include: @repeat,
    exclude: @repeat,
    seed: @value,
    name_pattern: @repeat,
    only: @repeat,
    compile: :boolean,
    start: :boolean,
    timeout: @value,
    raise: :boolean,
    deps_check: :boolean,
    archives_check: :boolean,
    elixir_version_check: :boolean,
    failed: :boolean,
    stale: :boolean,
    listen_on_stdin: :boolean,
    formatter: @repeat,
    slowest: @value,
    slowest_modules: @value,
    partitions: @value,
    preload_modules: :boolean,
    warnings_as_errors: :boolean,
    profile_require: @value,
    exit_status: @value,
    repeat_until_failure: @value,
    dry_run: :boolean
  ]

  @aliases [b: :breakpoints, n: :name_pattern]

  @partial [:failed, :stale, :only, :name_pattern, :repeat_until_failure, :dry_run]

  @spec parse([String.t()]) :: {:ok, t()} | {:error, String.t()}
  def parse(argv) do
    {opts, paths, invalid} =
      OptionParser.parse(argv,
        switches: @own ++ @mix_test,
        aliases: @aliases,
        allow_nonexistent_atoms: true
      )

    {own, rest} = Keyword.split(opts, Keyword.keys(@own))

    with :ok <- check_invalid(invalid),
         :ok <- check_partitions(rest),
         {:ok, shard} <- parse_shard(own[:shard]),
         :ok <- check_paths(paths, shard) do
      {:ok,
       %__MODULE__{
         shard: shard,
         timings: own[:timings] || Ballast.Timings.default_path(),
         report: own[:report],
         record?:
           Keyword.get(own, :record, true) and
             not Enum.any?(@partial, &Keyword.has_key?(rest, &1)),
         paths: paths,
         passthrough: OptionParser.to_argv(export_coverage(rest, shard), switches: @mix_test)
       }}
    end
  end

  defp export_coverage(rest, {index, _total}) do
    if rest[:cover] == true and not Keyword.has_key?(rest, :export_coverage),
      do: rest ++ [export_coverage: "ballast-#{index}"],
      else: rest
  end

  defp export_coverage(rest, nil), do: rest

  defp check_invalid([]), do: :ok
  defp check_invalid([{switch, _} | _]), do: {:error, "invalid value for #{switch}"}

  defp check_partitions(rest) do
    if Keyword.has_key?(rest, :partitions),
      do: {:error, "--partitions is not supported, use --shard INDEX/TOTAL to split the suite"},
      else: :ok
  end

  defp parse_shard(nil), do: {:ok, nil}

  defp parse_shard(string) do
    with [index, total] <- String.split(string, "/"),
         {index, ""} <- Integer.parse(index),
         {total, ""} <- Integer.parse(total),
         true <- total >= 1 and index in 1..total//1 do
      {:ok, {index, total}}
    else
      _ ->
        {:error, "--shard expects INDEX/TOTAL with 1 <= INDEX <= TOTAL, got: #{inspect(string)}"}
    end
  end

  defp check_paths(_paths, nil), do: :ok

  defp check_paths(paths, _shard) do
    case Enum.find(paths, &(&1 =~ ~r/:\d+$/)) do
      nil -> :ok
      path -> {:error, "#{path}: FILE:LINE cannot be combined with --shard"}
    end
  end
end
