defmodule Ballast.Planner do
  @moduledoc """
  Assigns test files to shards

  Every shard calls `plan/3` independently, so the same inputs must give the
  same plan regardless of order, and every file must land in exactly one
  shard.

  ## Cost model

  ExUnit runs sync modules one after another and async modules up to
  `max_cases` at a time. The async modules of one `:group` run one at a time,
  and only after every ungrouped async module has started. So a shard's
  predicted wall time is not a plain sum:

      cost = sync + max(longest ungrouped async module,
                        ceil((ungrouped + grouped) / max_cases),
                        ceil(ungrouped / max_cases) + longest group)

  A group's files may be split across shards.

  ## Algorithm

  Longest-processing-time-first greedy: sort files by weight descending (path
  as tie-break), put each one into the shard whose cost ends up lowest. With
  no history every file weighs the same and the result is what
  `mix test --partitions` produces.
  """

  alias Ballast.Timings

  @type shard :: %{files: [String.t()], cost_us: non_neg_integer()}

  @empty %{sync: 0, async: 0, longest: 0, grouped: 0, groups: %{}}

  @spec plan([String.t()], Timings.t(), pos_integer()) :: [shard()]
  def plan(files, %Timings{max_cases: max_cases} = timings, total)
      when is_list(files) and is_integer(total) and total > 0 do
    bins =
      for index <- 0..(total - 1) do
        Map.merge(@empty, %{index: index, files: []})
      end

    files
    |> Enum.uniq()
    |> entries(timings)
    |> Enum.sort_by(fn {file, entry} -> {-weight(entry, max_cases), file} end)
    |> Enum.reduce(bins, &place(&1, &2, max_cases))
    |> Enum.map(&%{files: Enum.sort(&1.files), cost_us: cost(&1, max_cases)})
  end

  @doc """
  What `mix test --partitions` does: sorted files, dealt out round-robin.
  Used for comparing plan quality in tests/reports. Files without history
  get the same default weight as in `plan/3`.
  """
  @spec round_robin([String.t()], Timings.t(), pos_integer()) :: [shard()]
  def round_robin(files, %Timings{max_cases: max_cases} = timings, total)
      when is_list(files) and is_integer(total) and total > 0 do
    indexed = files |> Enum.uniq() |> Enum.sort() |> entries(timings) |> Enum.with_index()

    for index <- 0..(total - 1) do
      mine = for {entry, i} <- indexed, rem(i, total) == index, do: entry

      bin = Enum.reduce(mine, @empty, fn {_file, entry}, bin -> add(bin, entry) end)

      %{files: Enum.map(mine, &elem(&1, 0)), cost_us: cost(bin, max_cases)}
    end
  end

  @doc """
  A short fingerprint of the assignment. Every shard prints it and writes it
  to its report. If two shards of one run disagree, they planned from
  different inputs.
  """
  @spec digest([shard()]) :: String.t()
  def digest(plan) do
    canonical = Enum.map_intersperse(plan, "\n\n", &Enum.intersperse(&1.files, "\n"))

    :crypto.hash(:sha256, canonical)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 12)
  end

  defp entries(files, %Timings{max_cases: max_cases} = timings) do
    known = Map.take(timings.files, files)
    default = {default_weight(known, max_cases), 0, 0, %{}}
    Enum.map(files, &{&1, Map.get(known, &1, default)})
  end

  defp place({file, entry}, bins, max_cases) do
    best =
      Enum.min_by(bins, fn bin ->
        {cost(add(bin, entry), max_cases), length(bin.files), bin.index}
      end)

    List.replace_at(bins, best.index, %{add(best, entry) | files: [file | best.files]})
  end

  defp add(bin, {sync, async, longest, groups}) do
    %{
      bin
      | sync: bin.sync + sync,
        async: bin.async + async,
        longest: max(bin.longest, longest),
        grouped: bin.grouped + Enum.sum(Map.values(groups)),
        groups: Map.merge(bin.groups, groups, fn _, a, b -> a + b end)
    }
  end

  defp cost(bin, max_cases) do
    bin.sync +
      Enum.max([
        bin.longest,
        ceil_div(bin.async + bin.grouped, max_cases),
        group_chain(bin, max_cases)
      ])
  end

  # ExUnit.Server.take_modules/1 hands out groups after every ungrouped async
  # module has started.
  defp group_chain(%{groups: groups}, _max_cases) when map_size(groups) == 0, do: 0

  defp group_chain(bin, max_cases) do
    ceil_div(bin.async, max_cases) + Enum.max(Map.values(bin.groups))
  end

  defp weight(entry, max_cases), do: cost(add(@empty, entry), max_cases)

  # A file with no history gets the median weight of the files that have one.
  defp default_weight(known, _max_cases) when map_size(known) == 0, do: 1

  defp default_weight(known, max_cases) do
    weights = known |> Enum.map(fn {_, entry} -> weight(entry, max_cases) end) |> Enum.sort()
    max(Enum.at(weights, div(length(weights), 2)), 1)
  end

  defp ceil_div(a, b), do: div(a + b - 1, b)
end
