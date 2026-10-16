defmodule Mix.Tasks.Ballast.Plan do
  @shortdoc "Shows how Ballast would split the suite"

  @moduledoc """
  Prints the plan `mix ballast.test --shard INDEX/TOTAL` would follow, without
  running any tests.

      $ mix ballast.plan --shards 3
      $ mix ballast.plan --shards 3 test/my_app_web
      $ mix ballast.plan --shards 3 --files 2
      $ mix ballast.plan --shards 3 --json

  ## Options

    * `--shards TOTAL` - how many shards to plan for. Required.
    * `--files INDEX` - print only the files of shard INDEX, one per line,
      and nothing else.
    * `--timings PATH` - the snapshot to plan from. Defaults to
      `tmp/ballast/timings.json`.
    * `--json` - print the plan as one JSON object instead of a table.
      Cannot be combined with `--files`.

  ## JSON output

      {
        "total": 2,
        "plan_digest": "69e9b4be5416",
        "max_cases": 8,
        "file_count": 3,
        "without_history": ["test/new_test.exs"],
        "slowest_us": 1400000,
        "round_robin_slowest_us": 2100000,
        "shards": [
          {"shard": 1, "files": ["test/a_test.exs"], "predicted_us": 1400000, "round_robin_us": 2100000},
          {"shard": 2, "files": ["test/b_test.exs", "test/new_test.exs"], "predicted_us": 1300000, "round_robin_us": 600000}
        ]
      }

  It is printed on a single line, with keys in no particular order. Durations
  are in microseconds. `round_robin_us` is what the shard would cost with
  `mix test --partitions`, which assigns different files.
  """

  use Mix.Task

  import Ballast.CLI

  alias Ballast.{Files, Planner, Timings}

  @switches [shards: :integer, files: :integer, timings: :string, json: :boolean]

  @impl true
  def run(argv) do
    {opts, paths} = parse!(argv, @switches)

    if Mix.Project.umbrella?() do
      Mix.raise("ballast.plan does not support umbrella project roots yet")
    end

    {total, only, json?} = check_options!(opts)
    timings = unwrap!(Timings.read(opts[:timings] || Timings.default_path()))

    universe = Files.discover(Mix.Project.config(), paths)
    plan = Planner.plan(universe, timings, total)
    shell = Mix.shell()

    cond do
      only -> plan |> Enum.at(only - 1) |> Map.fetch!(:files) |> Enum.each(&shell.info/1)
      json? -> print_json(shell, plan, universe, timings, total)
      true -> print_plan(shell, plan, universe, timings, total)
    end
  end

  defp check_options!(opts) do
    total = opts[:shards]

    if not (is_integer(total) and total >= 1) do
      Mix.raise("ballast: --shards TOTAL is required and must be at least 1")
    end

    only = opts[:files]

    if only != nil and only not in 1..total//1 do
      Mix.raise("ballast: --files expects a shard between 1 and #{total}, got: #{only}")
    end

    json? = Keyword.get(opts, :json, false)

    if json? and only != nil do
      Mix.raise("ballast: --json cannot be combined with --files")
    end

    {total, only, json?}
  end

  defp print_json(shell, plan, universe, timings, total) do
    dealt = Planner.round_robin(universe, timings, total)

    shards =
      for {{shard, rr}, index} <- plan |> Enum.zip(dealt) |> Enum.with_index(1) do
        %{
          shard: index,
          files: shard.files,
          predicted_us: shard.cost_us,
          round_robin_us: rr.cost_us
        }
      end

    shell.info(
      JSON.encode!(%{
        total: total,
        plan_digest: Planner.digest(plan),
        max_cases: timings.max_cases,
        file_count: length(universe),
        without_history: universe |> Enum.reject(&Map.has_key?(timings.files, &1)) |> Enum.sort(),
        slowest_us: slowest_us(plan),
        round_robin_slowest_us: slowest_us(dealt),
        shards: shards
      })
    )
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

  defp slowest(shards), do: shards |> slowest_us() |> seconds()

  defp slowest_us(shards), do: shards |> Enum.map(& &1.cost_us) |> Enum.max()
end
