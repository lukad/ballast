defmodule Mix.Tasks.Ballast.Merge do
  @shortdoc "Merges shard reports into the timings snapshot"

  @moduledoc """
  Combines the reports written by `mix ballast.test --shard` into the
  snapshot the next run plans from.

      $ mix ballast.merge
      $ mix ballast.merge reports/*.json --output timings.json
      $ mix ballast.merge --check --json

  Without arguments it reads `tmp/ballast/shard-*.json`. The merge is refused
  unless the reports are all shards of one plan and every shard finished
  cleanly.

  ## Options

    * `--output PATH` - the snapshot to write. Defaults to
      `tmp/ballast/timings.json`.
    * `--check` - only verify the reports, without writing a snapshot.
    * `--partial` - skip the completeness checks and lay the reports over the
      existing snapshot. Use that only to bootstrap or repair a snapshot.
    * `--json` - print the result as one JSON object on a single line.

  ## JSON output

  On success:

      {"ok": true, "reports": ["tmp/ballast/shard-1-of-2.json", "tmp/ballast/shard-2-of-2.json"], "file_count": 73, "output": "tmp/ballast/timings.json"}

  `output` is `null` with `--check`. When the merge is refused, the task
  exits with status 1 and prints every reason:

      {"ok": false, "errors": ["missing reports for shards [3] of 3", "shards [2] had failures or were aborted"]}

  Keys come in no particular order.
  """

  use Mix.Task

  import Ballast.CLI

  alias Ballast.{Report, Timings}

  @switches [output: :string, partial: :boolean, check: :boolean, json: :boolean]

  @impl true
  def run(argv) do
    {opts, paths} = parse!(argv, @switches)

    output = opts[:output] || Timings.default_path()
    partial? = Keyword.get(opts, :partial, false)
    check? = Keyword.get(opts, :check, false)
    json? = Keyword.get(opts, :json, false)
    paths = if paths == [], do: Path.wildcard("tmp/ballast/shard-*.json"), else: paths

    with {:ok, reports} <- read_reports(paths),
         {:ok, base} <- read_base(output, partial?),
         {:ok, timings} <- Report.merge(reports, partial: partial?, base: base) do
      if not check? do
        File.mkdir_p!(Path.dirname(output))
        File.write!(output, Timings.encode(timings))
      end

      cond do
        json? ->
          Mix.shell().info(
            JSON.encode!(%{
              ok: true,
              reports: paths,
              file_count: map_size(timings.files),
              output: if(!check?, do: output)
            })
          )

        check? ->
          Mix.shell().info(
            "ballast: #{length(reports)} reports, " <>
              "#{map_size(timings.files)} files, each run exactly once"
          )

        true ->
          Mix.shell().info(
            "ballast: merged #{length(reports)} reports, " <>
              "#{map_size(timings.files)} files, into #{output}"
          )
      end
    else
      {:error, errors} when json? ->
        Mix.shell().info(JSON.encode!(%{ok: false, errors: errors}))
        exit({:shutdown, 1})

      {:error, errors} ->
        Mix.raise("ballast: cannot merge:\n" <> Enum.map_join(errors, "\n", &("  * " <> &1)))
    end
  end

  defp read_reports(paths) do
    {read, unreadable} =
      paths |> Enum.map(&Report.read/1) |> Enum.split_with(&match?({:ok, _}, &1))

    if unreadable == [],
      do: {:ok, Enum.map(read, &elem(&1, 1))},
      else: {:error, Enum.map(unreadable, &elem(&1, 1))}
  end

  defp read_base(output, true = _partial?) do
    with {:error, message} <- Timings.read(output), do: {:error, [message]}
  end

  defp read_base(_output, false), do: {:ok, %Timings{}}
end
