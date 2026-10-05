defmodule Ballast.PlannerTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Ballast.Generators

  alias Ballast.{Planner, Timings}

  defp files(min \\ 0) do
    gen all(
          names <-
            uniq_list_of(string(:alphanumeric, min_length: 1, max_length: 12),
              min_length: min,
              max_length: 80
            )
        ) do
      Enum.map(names, &"test/#{&1}_test.exs")
    end
  end

  # History for a random subset of `files`, plus entries for files that are gone.
  defp timings(files) do
    gen all(
          known <- list_of(member_of(files ++ ["test/placeholder_test.exs"])),
          stale <- list_of(string(:alphanumeric, min_length: 1), max_length: 5),
          entries <- list_of(entry(), length: length(known) + length(stale)),
          max_cases <- integer(1..32)
        ) do
      paths = known ++ Enum.map(stale, &"test/gone/#{&1}_test.exs")
      %Timings{max_cases: max_cases, files: Map.new(Enum.zip(paths, entries))}
    end
  end

  defp scenario(min_files \\ 0, min_total \\ 1) do
    gen all(files <- files(min_files), timings <- timings(files), total <- integer(min_total..12)) do
      {files, timings, total}
    end
  end

  defp sync_only_scenario do
    gen all(
          files <- files(1),
          durations <- list_of(integer(1..5_000_000), length: length(files)),
          total <- integer(1..12)
        ) do
      {files, %Timings{files: Map.new(Enum.zip(files, Enum.map(durations, &{&1, 0, 0})))}, total}
    end
  end

  # Reference implementation of the cost model.
  defp expected_cost(shard_files, %Timings{files: known, max_cases: max_cases}, default) do
    entries = Enum.map(shard_files, &Map.get(known, &1, {default, 0, 0}))
    sync = entries |> Enum.map(&elem(&1, 0)) |> Enum.sum()
    async = entries |> Enum.map(&elem(&1, 1)) |> Enum.sum()
    longest = entries |> Enum.map(&elem(&1, 2)) |> Enum.max(fn -> 0 end)
    sync + max(longest, ceil(async / max_cases))
  end

  property "every file lands in exactly one shard" do
    check all({files, timings, total} <- scenario()) do
      plan = Planner.plan(files, timings, total)

      assert length(plan) == total
      assert plan |> Enum.flat_map(& &1.files) |> Enum.sort() == Enum.sort(files)
    end
  end

  property "the plan does not depend on input order or duplicates" do
    check all({files, timings, total} <- scenario(), seed <- integer()) do
      :rand.seed(:exsss, seed)
      shuffled = Enum.shuffle(files ++ Enum.take(files, 3))

      assert Planner.plan(shuffled, timings, total) == Planner.plan(files, timings, total)
    end
  end

  property "history for files that no longer exist changes nothing" do
    check all({files, timings, total} <- scenario()) do
      trimmed = %{timings | files: Map.take(timings.files, files)}

      assert Planner.plan(files, timings, total) == Planner.plan(files, trimmed, total)
    end
  end

  property "shards with the same inputs agree on the digest; a moved file changes it" do
    check all({files, timings, total} <- scenario(2, 2)) do
      plan = Planner.plan(files, timings, total)

      assert Planner.digest(plan) ==
               Planner.digest(Planner.plan(Enum.reverse(files), timings, total))

      [first, second | rest] = plan
      {moved, kept} = List.pop_at(first.files ++ second.files, 0)
      tampered = [%{first | files: kept}, %{second | files: [moved]} | rest]

      if Enum.map(tampered, & &1.files) != Enum.map(plan, & &1.files) do
        assert Planner.digest(tampered) != Planner.digest(plan)
      end
    end
  end

  property "without history the plan is exactly what mix test --partitions does" do
    check all(files <- files(), total <- integer(1..12)) do
      # Copied from Mix.Tasks.Test.filter_by_partition/3.
      partitions =
        for partition <- 0..(total - 1) do
          for {file, index} <- Enum.with_index(Enum.sort(files)),
              rem(index, total) == partition,
              do: file
        end

      assert files |> Planner.plan(%Timings{}, total) |> Enum.map(& &1.files) == partitions
      assert files |> Planner.round_robin(%Timings{}, total) |> Enum.map(& &1.files) == partitions
    end
  end

  property "reported cost matches the cost model" do
    check all({files, timings, total} <- scenario()) do
      weights =
        for {_, {s, a, l}} <- Map.take(timings.files, files),
            do: s + max(l, ceil(a / timings.max_cases))

      default =
        case Enum.sort(weights) do
          [] -> 1
          sorted -> max(Enum.at(sorted, div(length(sorted), 2)), 1)
        end

      for shard <- Planner.plan(files, timings, total) do
        assert shard.cost_us == expected_cost(shard.files, timings, default)
      end
    end
  end

  property "sync-only suites: shards differ by at most the largest file" do
    check all({files, timings, total} <- sync_only_scenario()) do
      costs = files |> Planner.plan(timings, total) |> Enum.map(& &1.cost_us)
      largest = timings.files |> Map.values() |> Enum.map(&elem(&1, 0)) |> Enum.max()

      assert Enum.max(costs) - Enum.min(costs) <= largest
    end
  end

  property "sync-only suites: never slower than round-robin by more than 4/3" do
    check all({files, timings, total} <- sync_only_scenario()) do
      slowest = fn plan -> plan |> Enum.map(& &1.cost_us) |> Enum.max() end

      # LPT is within 4/3 of optimal, and round-robin is no better than optimal.
      assert 3 * slowest.(Planner.plan(files, timings, total)) <=
               4 * slowest.(Planner.round_robin(files, timings, total))
    end
  end

  test "async files overlap up to max_cases, sync files add up" do
    timings = %Timings{
      max_cases: 2,
      files: %{
        "s" => {3_000_000, 0, 0},
        "a1" => {0, 4_000_000, 4_000_000},
        "a2" => {0, 1_000_000, 1_000_000},
        "a3" => {0, 1_000_000, 1_000_000}
      }
    }

    assert [%{cost_us: 7_000_000}] = Planner.plan(["s", "a1", "a2", "a3"], timings, 1)
  end

  test "only the longest async module of a file bounds its cost" do
    # Eight 1s parameterizations of one module.
    timings = %Timings{max_cases: 8, files: %{"p" => {0, 8_000_000, 1_000_000}}}

    assert [%{cost_us: 1_000_000}] = Planner.plan(["p"], timings, 1)
  end

  test "one dominant file gets a shard to itself" do
    timings = %Timings{
      files: %{"big" => {90, 0, 0}, "a" => {30, 0, 0}, "b" => {30, 0, 0}, "c" => {30, 0, 0}}
    }

    assert [%{files: ["big"], cost_us: 90}, %{files: ["a", "b", "c"], cost_us: 90}] =
             Planner.plan(["a", "b", "big", "c"], timings, 2)
  end

  test "files without history get the median weight, never zero" do
    timings = %Timings{files: %{"a" => {10, 0, 0}, "b" => {20, 0, 0}, "c" => {1000, 0, 0}}}
    plan = Planner.plan(["a", "b", "c", "new1", "new2", "new3"], timings, 2)

    assert [%{files: ["c"]}, %{files: ["a", "b", "new1", "new2", "new3"], cost_us: 90}] = plan
  end

  test "zero-weight files still spread across shards" do
    timings = %Timings{files: Map.new(1..6, &{"f#{&1}", {0, 0, 0}})}
    plan = Planner.plan(Enum.map(1..6, &"f#{&1}"), timings, 3)

    assert Enum.map(plan, &length(&1.files)) == [2, 2, 2]
  end

  test "more shards than files leaves the last shards empty" do
    assert [%{files: ["a"]}, %{files: ["b"]}, %{files: []}] =
             Planner.plan(["b", "a"], %Timings{}, 3)
  end

  test "golden plan for a fixed 40-file suite" do
    files = for i <- 1..40, do: "test/f#{String.pad_leading("#{i}", 2, "0")}_test.exs"

    timings = %Timings{
      max_cases: 4,
      files:
        Map.new(Enum.with_index(files, 1), fn {file, i} ->
          async = rem(i * 104_729, 700) * 1000 * rem(i, 2)
          {file, {rem(i * 7919, 1000) * 1000, async, async}}
        end)
    }

    plan = Planner.plan(files, timings, 5)

    assert Planner.digest(plan) == "1a18144f6080"
    assert Enum.map(plan, & &1.cost_us) == [4_717_000, 4_661_000, 4_631_000, 4_674_000, 4_648_000]
  end
end
