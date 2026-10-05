# Measures how close Ballast.Planner gets to an ideal split.
#
#     mix run bench/planner_quality.exs                              # synthetic suites
#     mix run bench/planner_quality.exs --suites 5000 --seed 7
#     mix run bench/planner_quality.exs test/ballast_timings.json    # a real snapshot
#
# Every figure is "slowest shard / lower bound". The bound is not always
# reachable: compare rows, or this branch against main, not absolutes.
# Runs are seeded.

defmodule Bench do
  import Ballast.CLI, only: [seconds: 1]

  alias Ballast.{Planner, Timings}

  @doc """
  No split of `files` into `total` shards can have a slowest shard below this:
  the most expensive single file, or an even share of all the work.
  """
  def lower_bound(%Timings{files: known, max_cases: max_cases}, files, total) do
    entries = Enum.map(files, &Map.fetch!(known, &1))
    sync = entries |> Enum.map(&elem(&1, 0)) |> Enum.sum()
    async = entries |> Enum.map(&elem(&1, 1)) |> Enum.sum()

    biggest =
      entries
      |> Enum.map(fn {s, a, longest} -> s + max(longest, ceil_div(a, max_cases)) end)
      |> Enum.max()

    max(biggest, ceil_div(sync + ceil_div(async, max_cases), total))
  end

  def slowest(plan), do: plan |> Enum.map(& &1.cost_us) |> Enum.max()

  @doc "One random suite: `{timings, files, total}`."
  def random_suite do
    files =
      Map.new(1..Enum.random(20..300), fn i ->
        {"test/f#{i}_test.exs", random_entry()}
      end)

    timings = %Timings{max_cases: Enum.random([4, 8, 16]), files: files}
    {timings, Map.keys(files), Enum.random(2..12)}
  end

  # Made-up mix of file shapes.
  defp random_entry do
    case :rand.uniform(10) do
      # 50%: a sync file
      n when n <= 5 ->
        {duration(), 0, 0}

      # 30%: one async module
      n when n <= 8 ->
        d = duration()
        {0, d, d}

      # 10%: several async modules in one file
      9 ->
        modules = for _ <- 1..Enum.random(2..5), do: duration()
        {0, Enum.sum(modules), Enum.max(modules)}

      # 10%: one parameterized async module
      10 ->
        d = duration()
        {0, d * Enum.random(2..8), d}
    end
  end

  # Log-normal: most files take a second or two, a few take a minute.
  defp duration, do: round(:math.exp(:rand.normal() * 1.2 + 1.0) * 1_000_000) + 1

  def synthetic(suites, seed) do
    :rand.seed(:exsss, seed)

    rows =
      for _ <- 1..suites do
        {timings, files, total} = random_suite()
        bound = lower_bound(timings, files, total)

        %{
          planner: slowest(Planner.plan(files, timings, total)) / bound,
          round_robin: slowest(Planner.round_robin(files, timings, total)) / bound
        }
      end

    IO.puts("""
    #{suites} synthetic suites, seed #{seed}

    How much longer the slowest shard runs than the fastest any split could be.
    """)

    table([
      ["", "average", "median", "p95", "worst"]
      | for {label, key} <- [{"Planner.plan", :planner}, {"round-robin", :round_robin}] do
          sorted = rows |> Enum.map(& &1[key]) |> Enum.sort()

          [
            label,
            above(Enum.sum(sorted) / suites),
            above(percentile(sorted, 0.5)),
            above(percentile(sorted, 0.95)),
            above(List.last(sorted))
          ]
        end
    ])

    wins = Enum.count(rows, &(&1.planner < &1.round_robin))
    losses = Enum.count(rows, &(&1.planner > &1.round_robin))

    IO.puts(
      "\nSuite by suite: Planner.plan faster in #{wins}, round-robin faster in #{losses}, " <>
        "tie in #{suites - wins - losses}."
    )
  end

  def snapshot(path) do
    timings =
      case Timings.read(path) do
        {:ok, %Timings{files: files} = timings} when map_size(files) > 0 -> timings
        {:ok, _empty} -> Mix.raise("#{path} is missing or has no timings")
        other -> Mix.raise("cannot read #{path}: #{inspect(other)}")
      end

    files = Map.keys(timings.files)

    IO.puts("""
    #{path}: #{length(files)} files, max_cases #{timings.max_cases}

    Predicted time of the slowest shard. "floor" is the fastest any split could be.
    """)

    table([
      ["shards", "floor", "Planner.plan", "vs floor", "round-robin", "vs floor"]
      | for total <- [2, 3, 4, 6, 8, 12, 16, 24] do
          bound = lower_bound(timings, files, total)
          planned = slowest(Planner.plan(files, timings, total))
          dealt = slowest(Planner.round_robin(files, timings, total))

          [
            String.pad_leading("#{total}", 6),
            seconds(bound),
            seconds(planned),
            above(planned / bound),
            seconds(dealt),
            above(dealt / bound)
          ]
        end
    ])
  end

  defp table(rows) do
    widths =
      rows
      |> Enum.zip_with(& &1)
      |> Enum.map(fn column -> column |> Enum.map(&String.length/1) |> Enum.max() end)

    for [first | rest] <- rows do
      [first_width | rest_widths] = widths

      [
        String.pad_trailing(first, first_width)
        | Enum.zip_with(rest, rest_widths, &String.pad_leading/2)
      ]
      |> Enum.join("  ")
      |> IO.puts()
    end
  end

  defp above(ratio), do: "+" <> :erlang.float_to_binary((ratio - 1) * 100, decimals: 1) <> "%"
  defp percentile(sorted, q), do: Enum.at(sorted, round(q * (length(sorted) - 1)))
  defp ceil_div(a, b), do: div(a + b - 1, b)
end

{opts, args} =
  OptionParser.parse!(System.argv(), strict: [suites: :integer, seed: :integer])

case args do
  [] -> Bench.synthetic(opts[:suites] || 2000, opts[:seed] || 1)
  [path] -> Bench.snapshot(path)
  _ -> Mix.raise("usage: mix run bench/planner_quality.exs [--suites N] [--seed N] [SNAPSHOT]")
end
