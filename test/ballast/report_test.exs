defmodule Ballast.ReportTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Ballast.{Planner, Report, Timings}

  defp report(index, total, files, opts \\ []) do
    %Report{
      index: index,
      total: total,
      digest: Keyword.get(opts, :digest, "abc"),
      clean?: Keyword.get(opts, :clean?, true),
      timings: %Timings{
        max_cases: Keyword.get(opts, :max_cases, 4),
        files: Map.new(files, &{&1, {10, 0, 0}})
      }
    }
  end

  @tag :tmp_dir
  test "write!/read round-trips and creates the directory", %{tmp_dir: dir} do
    path = Path.join([dir, "nested", "shard-2-of-3.json"])
    report = report(2, 3, ["test/a_test.exs"], clean?: false)

    Report.write!(path, report)
    assert Report.read(path) == {:ok, report}
  end

  @tag :tmp_dir
  test "a missing file reports the file error", %{tmp_dir: dir} do
    path = Path.join(dir, "nope.json")
    assert Report.read(path) == {:error, "#{path}: no such file or directory"}
  end

  @tag :tmp_dir
  test "a snapshot is not a report", %{tmp_dir: dir} do
    path = Path.join(dir, "timings.json")
    File.write!(path, Timings.encode(%Timings{}))

    assert {:error, _} = Report.read(path)
  end

  property "the reports of a full run merge back into the whole suite" do
    check all(
            names <- uniq_list_of(string(:alphanumeric, min_length: 1), max_length: 40),
            total <- integer(1..8)
          ) do
      plan = Planner.plan(names, %Timings{}, total)
      digest = Planner.digest(plan)

      reports =
        for {shard, index} <- Enum.with_index(plan, 1),
            do: report(index, total, shard.files, digest: digest)

      assert {:ok, timings} = Report.merge(Enum.shuffle(reports))
      assert timings.files |> Map.keys() |> Enum.sort() == Enum.sort(names)
    end
  end

  describe "merge/2 refuses" do
    test "no reports" do
      assert {:error, ["no reports given"]} = Report.merge([])
    end

    test "a missing shard" do
      assert {:error, [message]} = Report.merge([report(1, 3, ["a"]), report(3, 3, ["c"])])
      assert message =~ "missing reports for shards [2] of 3"
    end

    test "the same shard twice" do
      assert {:error, errors} =
               Report.merge([report(1, 2, ["a"]), report(1, 2, ["b"]), report(2, 2, ["c"])])

      assert Enum.any?(errors, &(&1 =~ "more than one report for shards [1]"))
    end

    test "shards that planned from different inputs" do
      assert {:error, [message]} =
               Report.merge([report(1, 2, ["a"]), report(2, 2, ["b"], digest: "xyz")])

      assert message =~ "planned from different inputs"
    end

    test "shards from runs with different shard counts" do
      assert {:error, errors} = Report.merge([report(1, 2, ["a"]), report(2, 3, ["b"])])
      assert Enum.any?(errors, &(&1 =~ "disagree on the shard count"))
    end

    test "a file that ran on two shards, even with partial: true" do
      reports = [report(1, 2, ["a", "dup"]), report(2, 2, ["b", "dup"])]

      assert {:error, ["dup was run by shards [1, 2]"]} = Report.merge(reports)
      assert {:error, ["dup was run by shards [1, 2]"]} = Report.merge(reports, partial: true)
    end

    test "a shard with failures" do
      assert {:error, [message]} =
               Report.merge([report(1, 2, ["a"]), report(2, 2, ["b"], clean?: false)])

      assert message =~ "shards [2] had failures"
    end
  end

  test "full merge drops files missing from the reports" do
    base = %Timings{max_cases: 8, files: %{"old" => {99, 0, 0}, "a" => {1, 0, 0}}}
    reports = [report(1, 2, ["a"]), report(2, 2, ["b"])]

    assert {:ok, %Timings{files: full}} = Report.merge(reports, base: base)
    assert Map.keys(full) == ["a", "b"]
  end

  test "partial merge keeps base files" do
    base = %Timings{max_cases: 8, files: %{"old" => {99, 0, 0}, "a" => {1, 0, 0}}}

    assert {:ok, %Timings{files: partial}} =
             Report.merge([report(2, 2, ["b"])], partial: true, base: base)

    assert partial == %{"old" => {99, 0, 0}, "a" => {1, 0, 0}, "b" => {10, 0, 0}}
  end

  test "merged max_cases is the minimum" do
    reports = [report(1, 2, ["a"], max_cases: 16), report(2, 2, ["b"], max_cases: 4)]
    assert {:ok, %Timings{max_cases: 4}} = Report.merge(reports)
  end
end
