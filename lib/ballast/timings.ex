defmodule Ballast.Timings do
  @moduledoc """
  The timing snapshot: how long each test file took on a previous run.

  Every shard of a CI run must plan from the *same* snapshot, so the on-disk
  format is deterministic (sorted keys, one file per line) and all durations
  are integers in microseconds. No floats anywhere in the planning path.

      {
        "version": 1,
        "max_cases": 8,
        "files": {
          "test/a_test.exs": {"sync_us": 1200000, "async_us": 0, "longest_async_us": 0},
          "test/b_test.exs": {"sync_us": 0, "async_us": 830000, "longest_async_us": 410000}
        }
      }
  """

  defstruct max_cases: 1, files: %{}

  @version 1

  @typedoc """
  `{sync_us, async_us, longest_async_us}`: wall time of the sync modules and of
  the async modules in one file, and of the longest of those async modules.
  """
  @type entry :: {non_neg_integer(), non_neg_integer(), non_neg_integer()}

  @type t :: %__MODULE__{
          max_cases: pos_integer(),
          files: %{optional(String.t()) => entry()}
        }

  @doc "Reads a snapshot. A missing file is treated as an empty snapshot."
  @spec read(Path.t()) :: {:ok, t()} | {:error, String.t()}
  def read(path) do
    case File.read(path) do
      {:ok, binary} ->
        with {:error, reason} <- decode(binary), do: {:error, "#{path}: #{reason}"}

      {:error, :enoent} ->
        {:ok, %__MODULE__{}}

      {:error, reason} ->
        {:error, "#{path}: #{:file.format_error(reason)}"}
    end
  end

  @spec decode(binary()) :: {:ok, t()} | {:error, String.t()}
  def decode(binary) do
    case JSON.decode(binary) do
      {:ok, %{"version" => @version} = map} -> from_map(map)
      {:ok, %{"version" => other}} -> {:error, "unsupported version #{inspect(other)}"}
      {:ok, _} -> {:error, "not a ballast timings file"}
      {:error, reason} -> {:error, "invalid JSON: #{inspect(reason)}"}
    end
  end

  @doc false
  def from_map(%{"max_cases" => max_cases, "files" => files})
      when is_integer(max_cases) and max_cases > 0 and is_map(files) do
    Enum.reduce_while(files, {:ok, %__MODULE__{max_cases: max_cases}}, fn
      {path, %{"sync_us" => s, "async_us" => a, "longest_async_us" => l}}, {:ok, acc}
      when is_binary(path) and is_integer(s) and s >= 0 and is_integer(a) and is_integer(l) and
             0 <= l and l <= a ->
        {:cont, {:ok, %{acc | files: Map.put(acc.files, path, {s, a, l})}}}

      {path, _}, _ ->
        {:halt, {:error, "bad entry for #{inspect(path)}"}}
    end)
  end

  def from_map(_), do: {:error, "missing or invalid max_cases/files"}

  @doc "Encodes a snapshot."
  @spec encode(t()) :: iodata()
  def encode(%__MODULE__{} = timings) do
    [
      "{\n  \"version\": #{@version},\n  \"max_cases\": #{timings.max_cases},\n",
      "  \"files\": ",
      encode_files(timings.files, "  "),
      "\n}\n"
    ]
  end

  @doc false
  def encode_files(files, _indent) when map_size(files) == 0, do: "{}"

  def encode_files(files, indent) do
    lines =
      files
      |> Enum.sort()
      |> Enum.map_intersperse(",\n", fn {path, {sync, async, longest}} ->
        [
          indent,
          "  ",
          JSON.encode!(path),
          ": {\"sync_us\": #{sync}, \"async_us\": #{async}, \"longest_async_us\": #{longest}}"
        ]
      end)

    ["{\n", lines, "\n", indent, "}"]
  end
end
