defmodule Ballast.Formatter do
  @moduledoc """
  ExUnit formatter that records how long each test file took.

  Add it next to your other formatters in `test/test_helper.exs`:

      ExUnit.start(formatters: [ExUnit.CLIFormatter, Ballast.Formatter])

  It does nothing unless switched on with `ExUnit.configure(ballast: recording)`
  before the suite starts.

  It measures the wall time between `:module_started` and `:module_finished`,
  which includes `setup_all`. Only the shard's own files are recorded; modules
  defined elsewhere, such as in `test/test_helper.exs`, are left out.

  A report already at the recording's path is deleted when the suite starts.
  An aborted run, or one that cannot write its report, leaves no report
  behind, and merging the run's reports fails. Dry runs and runs narrowed
  with `--failed`, `--only`, `--name-pattern` or `file:line` record nothing.
  Problems are printed to stderr; they never fail the test run.
  """

  use GenServer

  alias Ballast.{Files, Report, Timings}

  @impl true
  def init(opts) do
    case opts[:ballast] do
      off when off in [nil, false] ->
        {:ok, :off}

      %{path: _, index: _, total: _, digest: _, files: files} = recording when is_list(files) ->
        start_recording(recording, opts)

      other ->
        warn("not recording, :ballast must be a recording map, got: #{inspect(other)}")
        {:ok, :off}
    end
  end

  defp start_recording(%{path: path} = recording, opts) do
    case File.rm(path) do
      {:error, reason} when reason != :enoent ->
        warn("could not delete the old report #{path}: #{:file.format_error(reason)}")

      _ ->
        :ok
    end

    if partial_run?(opts) do
      warn("not recording, this run does not run the whole shard")
      {:ok, :off}
    else
      # Timestamps are taken when an event is handled. Handle events ahead of
      # the test processes to keep them close to when they were sent.
      Process.flag(:priority, :high)

      {:ok,
       %{
         recording: recording,
         max_cases: opts[:max_cases],
         # Tests may change the working directory.
         cwd: File.cwd!(),
         # Duplicate parameters give two runs of a module the same key; a list
         # pairs them with their starts in order.
         running: [],
         # Files that never report a module still show up in the report.
         files: Map.new(recording.files, &{&1, {0, 0, 0}}),
         clean?: true
       }}
    end
  end

  defp partial_run?(opts) do
    opts[:dry_run] == true or opts[:only_test_ids] != nil or :test in List.wrap(opts[:exclude])
  end

  @impl true
  def handle_cast(_event, :off), do: {:noreply, :off}

  def handle_cast({:module_started, module}, state) do
    {:noreply, %{state | running: state.running ++ [{key(module), now()}]}}
  end

  def handle_cast({:module_finished, module}, state) do
    finished = now()

    case List.keytake(state.running, key(module), 0) do
      {{_, started}, running} ->
        {:noreply, record_module(%{state | running: running}, module, finished - started)}

      # Never seen starting: its time is unknown.
      nil ->
        {:noreply, %{state | clean?: false}}
    end
  end

  def handle_cast(:max_failures_reached, state), do: {:noreply, %{state | clean?: false}}

  def handle_cast({:suite_finished, _times}, state) do
    # A module that never finished is missing from its file's time.
    write_report(state, state.clean? and state.running == [])
    {:noreply, state}
  end

  def handle_cast(_event, state), do: {:noreply, state}

  defp record_module(state, module, elapsed) do
    file = Files.normalize(module.file, state.cwd)
    async? = module.name.__ex_unit__(:config).async?
    files = Map.replace_lazy(state.files, file, &add(&1, elapsed, async?))

    %{state | files: files, clean?: state.clean? and passed?(module)}
  end

  defp add({s, a, l}, elapsed, true), do: {s, a + elapsed, max(l, elapsed)}
  defp add({s, a, l}, elapsed, false), do: {s + elapsed, a, l}

  defp write_report(state, clean?) do
    %{path: path, index: index, total: total, digest: digest} = state.recording

    Report.write!(path, %Report{
      index: index,
      total: total,
      digest: digest,
      clean?: clean?,
      timings: %Timings{max_cases: state.max_cases, files: state.files}
    })
  rescue
    error in File.Error -> warn(Exception.message(error))
  end

  # Parameterized modules share a name and can overlap when async.
  defp key(module), do: {module.name, module.parameters}

  defp passed?(%{state: {:failed, _}}), do: false

  defp passed?(%{tests: tests}) do
    not Enum.any?(tests, &match?(%{state: {kind, _}} when kind in [:failed, :invalid], &1))
  end

  defp now, do: System.monotonic_time(:microsecond)

  defp warn(message), do: IO.puts(:stderr, "ballast: " <> message)
end
