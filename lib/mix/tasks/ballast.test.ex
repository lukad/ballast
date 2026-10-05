defmodule Mix.Tasks.Ballast.Test do
  @shortdoc "Runs tests with Ballast"

  @moduledoc """
  Runs `mix test` on one shard of the suite.

      $ mix ballast.test --shard 3/8
      $ mix ballast.test --shard 3/8 --cover --warnings-as-errors
      $ mix ballast.test --shard 3/8 test/my_app_web

  Everything Ballast does not recognise is handed to `mix test` as is.

  ## Options

    * `--shard INDEX/TOTAL` - which shard to run, 1-based. Without it the
      whole suite runs (and is still recorded).
    * `--timings PATH` - the snapshot to plan from. Defaults to
      `test/ballast_timings.json`. A missing file means "no history", which
      plans like `mix test --partitions`.
    * `--report PATH` - where to write this shard's measurements. Defaults to
      `tmp/ballast/shard-INDEX-of-TOTAL.json`.
    * `--no-record` - do not write a report.

  ## Coverage

  With `--shard`, `--cover` exports `cover/ballast-INDEX.coverdata` and prints
  no summary, because one shard only sees part of the code. Collect the
  `cover/` directories of all shards and run `mix test.coverage` for the
  combined report and the threshold check.

  ## Setup

      # mix.exs
      def cli do
        [preferred_envs: ["ballast.test": :test, "ballast.merge": :test, "ballast.plan": :test]]
      end

      defp deps, do: [{:ballast, "~> 0.1", only: :test, runtime: false}]

      # test/test_helper.exs
      ExUnit.start(formatters: [ExUnit.CLIFormatter, Ballast.Formatter])
  """

  use Mix.Task

  import Ballast.CLI

  alias Ballast.{Args, Files, Planner, Report, Timings}

  @impl true
  def run(argv) do
    args = unwrap!(Args.parse(argv))

    if Mix.Project.umbrella?() do
      Mix.raise("ballast.test does not support umbrella project roots yet")
    end

    {index, total} = args.shard || {1, 1}
    timings = unwrap!(Timings.read(args.timings))
    universe = Files.discover(Mix.Project.config(), args.paths)
    plan = Planner.plan(universe, timings, total)
    shard = Enum.at(plan, index - 1)

    recording = %{
      path: args.report || "tmp/ballast/shard-#{index}-of-#{total}.json",
      index: index,
      total: total,
      digest: Planner.digest(plan),
      files: shard.files
    }

    Mix.shell().info(
      "ballast: shard #{index}/#{total}, " <>
        "#{length(shard.files)} of #{length(universe)} files, " <>
        "#{prediction(timings, shard)}, plan #{recording.digest}"
    )

    if args.record?, do: start_recording(recording)
    run_shard(args, recording, timings)
  end

  defp prediction(%Timings{files: files}, _shard) when map_size(files) == 0,
    do: "no timings yet, splitting round-robin"

  defp prediction(_timings, shard), do: "predicted #{seconds(shard.cost_us)}"

  defp start_recording(recording) do
    File.rm(recording.path)
    Application.ensure_loaded(:ex_unit)
    ExUnit.configure(ballast: recording)
  end

  defp run_shard(%Args{shard: nil} = args, recording, _timings),
    do: run_tests(args.passthrough ++ args.paths, args, recording.path)

  defp run_shard(args, %{files: []} = recording, timings) do
    Mix.shell().info("ballast: nothing to run on this shard")

    if args.record? do
      Report.write!(recording.path, %Report{
        index: recording.index,
        total: recording.total,
        digest: recording.digest,
        timings: %Timings{max_cases: timings.max_cases}
      })
    end
  end

  defp run_shard(args, recording, _timings),
    do: run_tests(args.passthrough ++ recording.files, args, recording.path)

  defp run_tests(argv, args, report) do
    Mix.Task.run("test", argv)

    if args.record? and Ballast.Formatter not in List.wrap(ExUnit.configuration()[:formatters]) do
      Mix.shell().error("""
      ballast: no timings were recorded (#{report} was not written), because
      Ballast.Formatter is not among ExUnit's formatters. Add it in test/test_helper.exs:

          ExUnit.start(formatters: [ExUnit.CLIFormatter, Ballast.Formatter])

      A --formatter flag replaces that list. Pass both:

          mix ballast.test --formatter ExUnit.CLIFormatter --formatter Ballast.Formatter
      """)
    end
  end
end
