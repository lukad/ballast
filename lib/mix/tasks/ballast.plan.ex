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
    dealt = Planner.round_robin(universe, timings, total)
    without_history = Enum.count(universe, &(not Map.has_key?(timings.files, &1)))

    shell.info(
      "#{length(universe)} files, #{without_history} without history, " <>
        "max_cases #{timings.max_cases}, plan #{Planner.digest(plan)}\n"
    )

    rows =
      for {{shard, rr}, index} <- plan |> Enum.zip(dealt) |> Enum.with_index(1) do
        [
          Integer.to_string(index),
          Integer.to_string(length(shard.files)),
          seconds(shard.cost_us),
          seconds(rr.cost_us)
        ]
      end

    shell.info(table(["shard", "files", "ballast", "round-robin"], rows))

    shell.info("\nslowest shard: #{slowest(plan)} (round-robin: #{slowest(dealt)})")
  end

  defp table(header, rows) do
    widths =
      [header | rows]
      |> Enum.zip_with(fn column -> column |> Enum.map(&String.length/1) |> Enum.max() end)

    Enum.map_join([header | rows], "\n", fn row ->
      row
      |> Enum.zip_with(widths, &String.pad_leading/2)
      |> Enum.join("  ")
    end)
  end

  defp slowest(shards), do: shards |> Enum.map(& &1.cost_us) |> Enum.max() |> seconds()
end
