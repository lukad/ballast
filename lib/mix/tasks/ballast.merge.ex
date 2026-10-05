defmodule Mix.Tasks.Ballast.Merge do
  @shortdoc "Merges shard reports into the timings snapshot"

  @moduledoc """
  Combines the reports written by `mix ballast.test --shard` into the
  snapshot the next run plans from.

      $ mix ballast.merge
      $ mix ballast.merge reports/*.json --output timings.json

  Without arguments it reads `tmp/ballast/shard-*.json`. The merge is refused
  unless the reports are all shards of one plan and every shard finished
  cleanly.

  ## Options

    * `--output PATH` - the snapshot to write. Defaults to
      `tmp/ballast/timings.json`.
    * `--check` - only verify the reports, without writing a snapshot.
    * `--partial` - skip the completeness checks and lay the reports over the
      existing snapshot. Use that only to bootstrap or repair a snapshot.
  """

  use Mix.Task

  import Ballast.CLI

  alias Ballast.{Report, Timings}

  @switches [output: :string, partial: :boolean, check: :boolean]

  @impl true
  def run(argv) do
    {opts, paths} = parse!(argv, @switches)

    output = opts[:output] || Timings.default_path()
    partial? = Keyword.get(opts, :partial, false)
    check? = Keyword.get(opts, :check, false)
    paths = if paths == [], do: Path.wildcard("tmp/ballast/shard-*.json"), else: paths

    reports = Enum.map(paths, &unwrap!(Report.read(&1)))
    base = if partial?, do: unwrap!(Timings.read(output)), else: %Timings{}

    case Report.merge(reports, partial: partial?, base: base) do
      {:ok, timings} when check? ->
        Mix.shell().info(
          "ballast: #{length(reports)} reports, " <>
            "#{map_size(timings.files)} files, each run exactly once"
        )

      {:ok, timings} ->
        File.mkdir_p!(Path.dirname(output))
        File.write!(output, Timings.encode(timings))

        Mix.shell().info(
          "ballast: merged #{length(reports)} reports, " <>
            "#{map_size(timings.files)} files, into #{output}"
        )

      {:error, errors} ->
        Mix.raise("ballast: cannot merge:\n" <> Enum.map_join(errors, "\n", &("  * " <> &1)))
    end
  end
end
