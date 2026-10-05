defmodule Ballast.Report do
  @moduledoc """
  The timings measured by one shard of a CI run.

  A report is a timings file that also records which shard wrote it, the plan
  digest that shard computed, and whether its suite finished without failures.
  `merge/2` uses those to refuse inconsistent runs.

      {
        "version": 1,
        "shard": 2,
        "total": 3,
        "plan_digest": "9f86d081",
        "clean": true,
        "max_cases": 8,
        "files": {
          "test/a_test.exs": {"sync_us": 1200000, "async_us": 0, "longest_async_us": 0}
        }
      }
  """

  alias Ballast.Timings

  @version 1

  defstruct index: 1, total: 1, digest: nil, clean?: true, timings: %Timings{}

  @type t :: %__MODULE__{
          index: pos_integer(),
          total: pos_integer(),
          digest: String.t() | nil,
          clean?: boolean(),
          timings: Timings.t()
        }

  @spec write!(Path.t(), t()) :: :ok
  def write!(path, %__MODULE__{} = report) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, encode(report))
  end

  @spec read(Path.t()) :: {:ok, t()} | {:error, String.t()}
  def read(path) do
    with {:ok, binary} <- File.read(path),
         {:ok, %{"version" => @version} = map} <- JSON.decode(binary),
         %{"shard" => index, "total" => total, "plan_digest" => digest, "clean" => clean?}
         when is_integer(index) and is_integer(total) and is_boolean(clean?) <- map,
         {:ok, timings} <- Timings.from_map(map) do
      {:ok,
       %__MODULE__{index: index, total: total, digest: digest, clean?: clean?, timings: timings}}
    else
      {:error, reason} when is_atom(reason) ->
        {:error, "#{path}: #{:file.format_error(reason)}"}

      _ ->
        {:error, "#{path}: not a ballast report"}
    end
  end

  @spec encode(t()) :: iodata()
  def encode(%__MODULE__{} = report) do
    [
      "{\n  \"version\": #{@version},\n",
      "  \"shard\": #{report.index},\n  \"total\": #{report.total},\n",
      "  \"plan_digest\": #{JSON.encode!(report.digest)},\n",
      "  \"clean\": #{report.clean?},\n",
      "  \"max_cases\": #{report.timings.max_cases},\n",
      "  \"files\": ",
      Timings.encode_files(report.timings.files, "  "),
      "\n}\n"
    ]
  end

  @doc """
  Combines the reports of one run into the next snapshot.

  Fails unless the reports are exactly shards `1..total` of one plan (same
  total, same digest), every shard finished cleanly, and no file was run by two
  shards.

  With `partial: true` the coverage checks are skipped and the reports are
  laid over `:base`. Use that only to bootstrap or repair a snapshot.
  """
  @spec merge([t()], keyword()) :: {:ok, Timings.t()} | {:error, [String.t()]}
  def merge(reports, opts \\ [])

  def merge([], _opts), do: {:error, ["no reports given"]}

  def merge(reports, opts) do
    partial? = Keyword.get(opts, :partial, false)
    base = Keyword.get(opts, :base, %Timings{})

    errors = duplicate_files(reports) ++ if(partial?, do: [], else: coverage_errors(reports))

    if errors == [] do
      measured = Enum.reduce(reports, %{}, &Map.merge(&2, &1.timings.files))

      {:ok,
       %Timings{
         # runners may differ, so plan for the least parallel one
         max_cases: reports |> Enum.map(& &1.timings.max_cases) |> Enum.min(),
         files: if(partial?, do: Map.merge(base.files, measured), else: measured)
       }}
    else
      {:error, errors}
    end
  end

  defp coverage_errors(reports) do
    totals = reports |> Enum.map(& &1.total) |> Enum.uniq()
    digests = reports |> Enum.map(& &1.digest) |> Enum.uniq()
    indexes = reports |> Enum.map(& &1.index) |> Enum.sort()
    dirty = for %{clean?: false, index: index} <- reports, do: index

    List.flatten([
      if(length(totals) > 1,
        do: "reports disagree on the shard count: #{inspect(totals)}",
        else: []
      ),
      if(length(digests) > 1,
        do: "shards planned from different inputs (plan digests #{inspect(digests)})",
        else: []
      ),
      case totals do
        [total] ->
          missing = Enum.to_list(1..total) -- indexes
          repeated = Enum.uniq(indexes -- Enum.uniq(indexes))

          [
            if(missing == [],
              do: [],
              else: "missing reports for shards #{inspect(missing)} of #{total}"
            ),
            if(repeated == [],
              do: [],
              else: "more than one report for shards #{inspect(repeated)}"
            )
          ]

        _ ->
          []
      end,
      if(dirty == [],
        do: [],
        else: "shards #{inspect(Enum.sort(dirty))} had failures or were aborted"
      )
    ])
  end

  defp duplicate_files(reports) do
    reports
    |> Enum.flat_map(fn r -> for {file, _} <- r.timings.files, do: {file, r.index} end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.filter(fn {_, indexes} -> length(indexes) > 1 end)
    |> Enum.sort()
    |> Enum.map(fn {file, indexes} ->
      "#{file} was run by shards #{inspect(Enum.sort(indexes))}"
    end)
  end
end
