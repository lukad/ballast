defmodule Mix.Tasks.Ballast.Plan do
  @shortdoc "Shows how Ballast would split the suite"

  @moduledoc """
  Prints the plan `mix ballast.test --shard INDEX/TOTAL` would follow, without
  running any tests.

      $ mix ballast.plan --shards 3
      $ mix ballast.plan --shards 3 test/my_app_web
      $ mix ballast.plan --shards 3 --files 2

  ## Options

    * `--shards TOTAL` - how many shards to plan for. Required.
    * `--files INDEX` - print only the files of shard INDEX, one per line,
      and nothing else.
    * `--timings PATH` - the snapshot to plan from. Defaults to
      `test/ballast_timings.json`.
  """

  use Mix.Task

  import Ballast.CLI

  alias Ballast.{Files, Planner, Timings}

  @switches [shards: :integer, files: :integer, timings: :string]

  @impl true
  def run(argv) do
    {opts, paths} = parse!(argv, @switches)
    total = opts[:shards]

    if not (is_integer(total) and total >= 1) do
      Mix.raise("ballast: --shards TOTAL is required and must be at least 1")
    end

    only = opts[:files]

    if only != nil and only not in 1..total//1 do
      Mix.raise("ballast: --files expects a shard between 1 and #{total}, got: #{only}")
    end

    timings = unwrap!(Timings.read(opts[:timings] || Timings.default_path()))

    universe = Files.discover(Mix.Project.config(), paths)
    plan = Planner.plan(universe, timings, total)
    shell = Mix.shell()

    if only do
      plan |> Enum.at(only - 1) |> Map.fetch!(:files) |> Enum.each(&shell.info/1)
    else
      print_plan(shell, plan, universe, timings, total)
    end
  end

  defp print_plan(shell, plan, universe, timings, total) do
    shell.info(
      "ballast: #{length(universe)} files over #{total} shards, " <>
        "#{if map_size(timings.files) == 0, do: "no timings yet, ", else: ""}" <>
        "plan #{Planner.digest(plan)}"
    )

    plan
    |> Enum.with_index(1)
    |> Enum.each(fn {shard, index} ->
      shell.info(
        "\nshard #{index}/#{total}: #{length(shard.files)} files, predicted #{seconds(shard.cost_us)}"
      )

      Enum.each(shard.files, &shell.info("  " <> &1))
    end)
  end
end
