defmodule Ballast.FormatterTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Ballast.{Formatter, Report}

  @moduletag :tmp_dir

  # The formatter asks real modules whether they are async.
  defmodule Sync do
    use ExUnit.Case, register: false
  end

  defmodule Async do
    use ExUnit.Case, async: true, register: false
  end

  setup %{tmp_dir: dir} do
    %{path: Path.join(dir, "report.json")}
  end

  # ExUnit starts formatters with GenServer.start_link(module, config).
  defp start_formatter(config) do
    start_supervised!(%{
      id: make_ref(),
      start: {GenServer, :start_link, [Formatter, config]},
      restart: :temporary
    })
  end

  defp start(path, files, opts \\ []) do
    recording = %{path: path, index: 2, total: 5, digest: "abc123", files: files}
    start_formatter([max_cases: 8, ballast: recording] ++ opts)
  end

  # Like ExUnit, `tests` only holds tests that ran or were invalidated by a
  # failed setup_all, never skipped or excluded ones.
  defp module(name, file, opts \\ []) do
    tests =
      for state <- Keyword.get(opts, :tests, [nil]) do
        %ExUnit.Test{name: :t, module: name, state: state}
      end

    %ExUnit.TestModule{
      name: name,
      file: Path.expand(file),
      tests: tests,
      state: Keyword.get(opts, :state),
      parameters: Keyword.get(opts, :parameters, %{})
    }
  end

  defp run(pid, module, sleep \\ 0) do
    GenServer.cast(pid, {:module_started, module})
    # Flush: take the start timestamp before sleeping.
    :sys.get_state(pid)
    Process.sleep(sleep)
    GenServer.cast(pid, {:module_finished, module})
  end

  defp suite_finished(pid) do
    GenServer.cast(pid, {:suite_finished, %{run: 1, async: nil, load: nil}})
    :sys.get_state(pid)
  end

  defp finish(pid, path) do
    suite_finished(pid)
    {:ok, report} = Report.read(path)
    report
  end

  test "is inert unless configured with :ballast", %{path: path} do
    for config <- [[], [ballast: nil], [ballast: false]] do
      pid = start_formatter([max_cases: 8] ++ config)
      run(pid, module(Sync, "test/a_test.exs"))

      assert suite_finished(pid) == :off
    end

    refute File.exists?(path)
  end

  test "a malformed :ballast config is reported and records nothing", %{path: path} do
    stderr =
      capture_io(:stderr, fn ->
        pid = start_formatter(max_cases: 8, ballast: %{path: path})
        assert suite_finished(pid) == :off
      end)

    assert stderr =~ ":ballast must be a recording map"
    refute File.exists?(path)
  end

  test "writes shard, digest and max_cases from the run", %{path: path} do
    pid = start(path, [])
    report = finish(pid, path)

    assert %Report{index: 2, total: 5, digest: "abc123", clean?: true} = report
    assert report.timings.max_cases == 8
  end

  test "sync and async time go to separate slots", %{path: path} do
    pid = start(path, ["test/sync_test.exs", "test/async_test.exs"])
    run(pid, module(Sync, "test/sync_test.exs"), 30)
    run(pid, module(Async, "test/async_test.exs"), 30)

    assert %{"test/sync_test.exs" => {sync, 0, 0}, "test/async_test.exs" => {0, async, async}} =
             finish(pid, path).timings.files

    assert sync >= 30_000 and async >= 30_000
  end

  test "a file's modules add up, and its longest async module is kept", %{path: path} do
    pid = start(path, ["test/multi_test.exs"])
    run(pid, module(Sync, "test/multi_test.exs"), 20)
    run(pid, module(Sync, "test/multi_test.exs"), 20)
    run(pid, module(Async, "test/multi_test.exs"), 10)
    run(pid, module(Async, "test/multi_test.exs"), 30)

    assert %{"test/multi_test.exs" => {sync, async, longest}} = finish(pid, path).timings.files
    assert sync >= 40_000
    assert longest >= 30_000 and async - longest >= 10_000
  end

  test "overlapping runs of a parameterized module are each counted", %{path: path} do
    pid = start(path, ["test/param_test.exs"])
    one = module(Async, "test/param_test.exs", parameters: %{x: 1})
    two = module(Async, "test/param_test.exs", parameters: %{x: 2})

    GenServer.cast(pid, {:module_started, one})
    GenServer.cast(pid, {:module_started, two})
    :sys.get_state(pid)
    Process.sleep(25)
    GenServer.cast(pid, {:module_finished, one})
    GenServer.cast(pid, {:module_finished, two})

    assert %{"test/param_test.exs" => {0, async, longest}} = finish(pid, path).timings.files
    assert longest >= 25_000 and async - longest >= 25_000
  end

  test "runs with duplicate parameters are paired in order", %{path: path} do
    pid = start(path, ["test/param_test.exs"])
    # ExUnit does not deduplicate `parameterize: [%{x: 1}, %{x: 1}]`.
    dup = module(Async, "test/param_test.exs", parameters: %{x: 1})

    GenServer.cast(pid, {:module_started, dup})
    GenServer.cast(pid, {:module_started, dup})
    :sys.get_state(pid)
    Process.sleep(25)
    GenServer.cast(pid, {:module_finished, dup})
    GenServer.cast(pid, {:module_finished, dup})

    assert %Report{clean?: true, timings: %{files: files}} = finish(pid, path)
    assert %{"test/param_test.exs" => {0, async, _}} = files
    assert async >= 50_000
  end

  test "every file of the shard is reported, even if none of its tests ran", %{path: path} do
    pid = start(path, ["test/excluded_test.exs", "test/no_module_test.exs"])
    # ExUnit sends a module with all tests excluded as `tests: []`.
    run(pid, module(Sync, "test/excluded_test.exs", tests: []))

    assert %{"test/excluded_test.exs" => {_, 0, 0}, "test/no_module_test.exs" => {0, 0, 0}} =
             finish(pid, path).timings.files
  end

  test "modules from files outside the shard are left out", %{path: path} do
    pid = start(path, ["test/a_test.exs"])
    # Modules defined in test_helper.exs run on every shard.
    run(pid, module(Sync, "test/test_helper.exs"))

    assert %Report{clean?: true, timings: %{files: files}} = finish(pid, path)
    assert files == %{"test/a_test.exs" => {0, 0, 0}}
  end

  test "an old report is deleted when the suite starts", %{path: path} do
    File.write!(path, "old")
    pid = start(path, ["test/a_test.exs"])
    refute File.exists?(path)

    # ExUnit stops formatters without :suite_finished on SIGQUIT.
    GenServer.cast(pid, {:sigquit, []})
    GenServer.stop(pid)
    refute File.exists?(path)
  end

  test "dry runs and narrowed runs record nothing", %{path: path} do
    for opts <- [
          [dry_run: true],
          # --failed
          [only_test_ids: MapSet.new([{Sync, :t}])],
          # --only, --name-pattern and file:line
          [exclude: [:test], include: [location: {"test/a_test.exs", 3}]]
        ] do
      File.write!(path, "old")

      stderr =
        capture_io(:stderr, fn ->
          pid = start(path, ["test/a_test.exs"], opts)
          run(pid, module(Sync, "test/a_test.exs"))
          assert suite_finished(pid) == :off
        end)

      assert stderr =~ "not recording"
      refute File.exists?(path)
    end
  end

  test "a report that cannot be written prints a warning", %{tmp_dir: dir} do
    stderr =
      capture_io(:stderr, fn ->
        # The path is taken by a directory.
        pid = start(dir, [])
        suite_finished(pid)
        assert Process.alive?(pid)
      end)

    assert stderr =~ "could not write"
  end

  describe "marks the report dirty on" do
    @failed {:failed, [{:error, %RuntimeError{}, []}]}

    test "a failed test", %{path: path} do
      pid = start(path, [])
      run(pid, module(Sync, "test/f_test.exs", tests: [nil, @failed]))

      assert %Report{clean?: false} = finish(pid, path)
    end

    test "an invalid test", %{path: path} do
      pid = start(path, [])
      run(pid, module(Sync, "test/i_test.exs", tests: [{:invalid, nil}]))

      assert %Report{clean?: false} = finish(pid, path)
    end

    test "a failed setup_all", %{path: path} do
      pid = start(path, [])
      run(pid, module(Sync, "test/s_test.exs", tests: [], state: @failed))

      assert %Report{clean?: false} = finish(pid, path)
    end

    test "reaching max failures", %{path: path} do
      pid = start(path, [])
      GenServer.cast(pid, :max_failures_reached)

      assert %Report{clean?: false} = finish(pid, path)
    end

    test "a module that never finished", %{path: path} do
      pid = start(path, [])
      GenServer.cast(pid, {:module_started, module(Sync, "test/a_test.exs")})

      assert %Report{clean?: false} = finish(pid, path)
    end

    test "a module that finished without starting", %{path: path} do
      pid = start(path, [])
      GenServer.cast(pid, {:module_finished, module(Sync, "test/a_test.exs")})

      assert %Report{clean?: false} = finish(pid, path)
    end
  end

  test "skipped and excluded tests do not make a run dirty", %{path: path} do
    pid = start(path, ["test/skip_test.exs"])
    module = module(Sync, "test/skip_test.exs")

    # ExUnit reports skipped and excluded tests only as test events.
    GenServer.cast(pid, {:module_started, module})

    for state <- [{:skipped, "why"}, {:excluded, "why"}] do
      test = %ExUnit.Test{name: :t, module: Sync, state: state}
      GenServer.cast(pid, {:test_started, test})
      GenServer.cast(pid, {:test_finished, test})
    end

    GenServer.cast(pid, {:module_finished, module})

    assert %Report{clean?: true} = finish(pid, path)
  end

  test "ignores events it does not know", %{path: path} do
    pid = start(path, [])
    GenServer.cast(pid, {:test_started, %ExUnit.Test{}})
    GenServer.cast(pid, {:unknown_event, nil})

    assert finish(pid, path).timings.files == %{}
  end
end
