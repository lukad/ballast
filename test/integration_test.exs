defmodule Ballast.IntegrationTest do
  # Runs real `mix` commands against a generated project.
  use ExUnit.Case, async: false

  alias Ballast.{Fixture, Planner, Report, Timings}

  @moduletag :integration
  @moduletag timeout: 300_000

  @shards 3

  setup_all do
    dir =
      Fixture.create!(
        Path.join(System.tmp_dir!(), "ballast_fixture_#{System.unique_integer([:positive])}")
      )

    on_exit(fn -> File.rm_rf!(dir) end)

    # Compile up front, outside any timed run.
    {output, status, _} = Fixture.mix(dir, ["ballast.test", "--no-record", "--exclude", "test"])
    assert status == 0, output

    %{dir: dir}
  end

  setup %{dir: dir} do
    # Also removes the snapshot, tmp/ballast/timings.json.
    File.rm_rf!(Path.join(dir, "tmp"))

    Fixture.write_helper!(
      dir,
      "ExUnit.start(formatters: [ExUnit.CLIFormatter, Ballast.Formatter])"
    )

    :ok
  end

  # All shards at once, like CI runners.
  defp run_all_shards(dir, env \\ []) do
    1..@shards
    |> Task.async_stream(
      &Fixture.mix(dir, ["ballast.test", "--shard", "#{&1}/#{@shards}"], env),
      timeout: :infinity
    )
    |> Enum.map(fn {:ok, {output, status, ran}} ->
      assert status == 0, output
      ran
    end)
  end

  defp reports(dir, total \\ @shards) do
    for index <- 1..total do
      {:ok, report} = Report.read(Path.join(dir, "tmp/ballast/shard-#{index}-of-#{total}.json"))
      report
    end
  end

  defp write_snapshot!(dir, contents) do
    File.mkdir_p!(Path.join(dir, "tmp/ballast"))
    File.write!(Path.join(dir, "tmp/ballast/timings.json"), contents)
  end

  # Wall time of a set of files according to what a run measured.
  defp measured_cost(files, measured) do
    timings = %Timings{max_cases: measured.max_cases, files: Map.take(measured.files, files)}
    [%{cost_us: cost}] = Planner.round_robin(files, timings, 1)
    cost
  end

  test "file discovery agrees with what mix test loads", %{dir: dir} do
    {output, 0, ran} = Fixture.mix(dir, ["ballast.test"])
    {planned, 0, _} = Fixture.mix(dir, ["ballast.plan", "--shards", "1", "--files", "1"])

    assert ran == Enum.sort(Fixture.files()), output
    assert String.split(planned, "\n", trim: true) == ran
  end

  test "ballast.plan compares the plan with round-robin", %{dir: dir} do
    files =
      for file <- Fixture.files(),
          file != "test/sample/web/t12_test.exs",
          into: %{},
          do: {file, {600_000, 0, 0}}

    write_snapshot!(dir, Timings.encode(%Timings{max_cases: 4, files: files}))

    {output, 0, _} = Fixture.mix(dir, ["ballast.plan", "--shards", "3"])

    assert output =~ ~r/^12 files, 1 without history, max_cases 4, plan [0-9a-f]{12}\n/
    assert output =~ "shard  files  ballast  round-robin\n"
    assert output =~ ~r/^\s+1\s+\d+\s+\d+\.\ds\s+\d+\.\ds$/m
    assert output =~ ~r/\nslowest shard: \d+\.\ds \(round-robin: \d+\.\ds\)\n/
  end

  test "cold start: splits like --partitions and runs every file exactly once", %{dir: dir} do
    ran = run_all_shards(dir)
    sorted = Enum.sort(Fixture.files())

    assert ran |> List.flatten() |> Enum.sort() == sorted

    for {shard, index} <- Enum.with_index(ran) do
      assert shard ==
               for({file, i} <- Enum.with_index(sorted), rem(i, @shards) == index, do: file)
    end

    {output, status, _} = Fixture.mix(dir, ["ballast.merge", "--check"])
    assert status == 0, output
    assert output =~ "3 reports, 12 files, each run exactly once"
    refute File.exists?(Path.join(dir, "tmp/ballast/timings.json"))
  end

  test "warm run: the slowest shard gets much faster", %{dir: dir} do
    cold = run_all_shards(dir, [{"SLEEP", "1"}])
    {_, 0, _} = Fixture.mix(dir, ["ballast.merge"])
    {:ok, measured} = Timings.read(Path.join(dir, "tmp/ballast/timings.json"))

    assert measured.files |> Map.keys() |> Enum.sort() == Enum.sort(Fixture.files())
    assert {sync, 0, 0} = measured.files["test/sample/t01_test.exs"]
    assert sync >= 600_000
    assert {0, async, _longest} = measured.files["test/sample/t08_test.exs"]
    assert async >= 400_000

    warm = run_all_shards(dir, [{"SLEEP", "1"}])
    assert warm |> List.flatten() |> Enum.sort() == Enum.sort(Fixture.files())

    # Judge both splits by the same measurements.
    slowest = fn shards -> shards |> Enum.map(&measured_cost(&1, measured)) |> Enum.max() end
    assert slowest.(warm) < 0.75 * slowest.(cold)

    assert [_] = dir |> reports() |> Enum.map(& &1.digest) |> Enum.uniq()
    {output, status, _} = Fixture.mix(dir, ["ballast.merge", "--check"])
    assert status == 0, output
  end

  test "a failing shard exits non-zero; --failed reruns only its failures", %{dir: dir} do
    # The cold plan puts t05, the 5th sorted file, on shard 2 of 3.
    {output, status, ran} =
      Fixture.mix(dir, ["ballast.test", "--shard", "2/3"], [{"FAIL_FILE", "t05"}])

    assert status == 2, output
    assert "test/sample/t05_test.exs" in ran and length(ran) == 4

    report = Path.join(dir, "tmp/ballast/shard-2-of-3.json")
    assert {:ok, %Report{clean?: false}} = Report.read(report)

    {output, status, ran} = Fixture.mix(dir, ["ballast.test", "--shard", "2/3", "--failed"])
    assert status == 0, output
    assert ran == ["test/sample/t05_test.exs"]

    # The one-file retry must not replace the shard's report.
    assert {:ok, %Report{clean?: false, timings: %{files: files}}} = Report.read(report)
    assert map_size(files) == 4
  end

  test "merge refuses a run with a dirty or missing shard", %{dir: dir} do
    {_, 0, _} = Fixture.mix(dir, ["ballast.test", "--shard", "1/3"])
    {_, 2, _} = Fixture.mix(dir, ["ballast.test", "--shard", "2/3"], [{"FAIL_FILE", "t05"}])

    {output, status, _} = Fixture.mix(dir, ["ballast.merge"])
    assert status == 1
    assert output =~ "missing reports for shards [3] of 3"
    assert output =~ "shards [2] had failures"
    refute File.exists?(Path.join(dir, "tmp/ballast/timings.json"))
  end

  test "an empty shard runs no tests", %{dir: dir} do
    {output, status, ran} = Fixture.mix(dir, ["ballast.test", "--shard", "13/13"])

    assert status == 0, output
    assert ran == []
    assert output =~ "nothing to run on this shard"

    assert {:ok, %Report{index: 13, total: 13, clean?: true}} =
             Report.read(Path.join(dir, "tmp/ballast/shard-13-of-13.json"))
  end

  test "positional paths narrow what gets sharded", %{dir: dir} do
    ran =
      for index <- 1..2 do
        {output, status, ran} =
          Fixture.mix(dir, [
            "ballast.test",
            "--shard",
            "#{index}/2",
            "test/sample/web",
            "test/sample/t11_test.exs"
          ])

        assert status == 0, output
        ran
      end

    assert ran == [["test/sample/t11_test.exs"], ["test/sample/web/t12_test.exs"]]
  end

  test "mix test options pass through", %{dir: dir} do
    {output, status, ran} =
      Fixture.mix(dir, ["ballast.test", "--shard", "1/3", "--trace", "--seed", "0"])

    assert status == 0, output
    assert length(ran) == 4
    assert output =~ "seed: 0"
    assert output =~ "Sample.T01Test [test/sample/t01_test.exs]"
  end

  test "--cover on a shard exports coverdata; mix test.coverage combines the shards", %{dir: dir} do
    for index <- 1..@shards do
      {output, status, _} =
        Fixture.mix(dir, ["ballast.test", "--shard", "#{index}/#{@shards}", "--cover"])

      assert status == 0, output
      refute output =~ "threshold not met"
      assert File.exists?(Path.join(dir, "cover/ballast-#{index}.coverdata"))
    end

    {output, status, _} = Fixture.mix(dir, ["test.coverage"], [{"MIX_ENV", "test"}])
    assert status == 0, output
    assert output =~ ~r/100\.00% \| Sample\s/
  end

  describe "setup mistakes are reported" do
    test "formatter missing from test_helper.exs", %{dir: dir} do
      Fixture.write_helper!(dir, "ExUnit.start()")
      {output, status, ran} = Fixture.mix(dir, ["ballast.test", "--shard", "1/3"])

      assert status == 0 and length(ran) == 4
      assert output =~ "Ballast.Formatter is not among ExUnit's formatters"
      refute File.exists?(Path.join(dir, "tmp/ballast/shard-1-of-3.json"))
    end

    test "a --formatter flag without Ballast.Formatter", %{dir: dir} do
      {output, 0, _} =
        Fixture.mix(dir, ["ballast.test", "--shard", "1/3", "--formatter", "ExUnit.CLIFormatter"])

      assert output =~ "Ballast.Formatter is not among ExUnit's formatters"

      {output, 0, _} =
        Fixture.mix(
          dir,
          ~w(ballast.test --shard 1/3 --formatter ExUnit.CLIFormatter --formatter Ballast.Formatter)
        )

      refute output =~ "is not among"
      assert File.exists?(Path.join(dir, "tmp/ballast/shard-1-of-3.json"))
    end

    test "plain mix test is unaffected by the formatter", %{dir: dir} do
      {output, status, ran} = Fixture.mix(dir, ["test"])

      assert status == 0, output
      assert length(ran) == 12
      refute File.exists?(Path.join(dir, "tmp"))
    end

    test "bad arguments", %{dir: dir} do
      assert {output, 1, []} = Fixture.mix(dir, ["ballast.test", "--shard", "4/3"])
      assert output =~ "--shard expects INDEX/TOTAL"

      assert {output, 1, []} =
               Fixture.mix(dir, ["ballast.test", "--shard", "1/3", "--partitions", "3"])

      assert output =~ "--partitions is not supported"
    end

    test "a damaged snapshot stops the run", %{dir: dir} do
      write_snapshot!(dir, "{")
      assert {output, 1, []} = Fixture.mix(dir, ["ballast.test", "--shard", "1/3"])
      assert output =~ "tmp/ballast/timings.json: invalid JSON"
    end
  end
end
