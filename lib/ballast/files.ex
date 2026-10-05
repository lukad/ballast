defmodule Ballast.Files do
  @moduledoc """
  Finds the test files `mix test` would load, without loading anything.
  """

  @doc """
  Returns project-relative paths, sorted and unique.

  `paths` narrows the search to the given files or directories, the same way
  positional arguments to `mix test` do. A file named directly is always
  included, whatever the pattern says.
  """
  @spec discover(keyword(), [Path.t()]) :: [String.t()]
  def discover(config \\ Mix.Project.config(), paths \\ []) do
    roots = if paths == [], do: test_paths(config), else: paths
    pattern = config[:test_pattern] || "*.{ex,exs}"

    {globbed, direct} =
      Enum.reduce(roots, {[], []}, fn root, {globbed, direct} ->
        cond do
          File.dir?(root) -> {Path.wildcard("#{root}/**/#{pattern}") ++ globbed, direct}
          File.regular?(root) -> {globbed, [root | direct]}
          true -> {globbed, direct}
        end
      end)

    (Enum.filter(globbed, &load?(&1, config)) ++ direct)
    |> Enum.map(&normalize/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc "Project-relative path with forward slashes."
  @spec normalize(Path.t()) :: String.t()
  def normalize(path) do
    path |> Path.relative_to_cwd() |> String.replace("\\", "/")
  end

  defp test_paths(config) do
    config[:test_paths] || if(File.dir?("test"), do: ["test"], else: [])
  end

  defp load?(file, config) do
    filters = config[:test_load_filters] || [&String.ends_with?(&1, "_test.exs")]
    Enum.any?(filters, &matches?(&1, file))
  end

  defp matches?(%Regex{} = regex, file), do: Regex.match?(regex, file)
  defp matches?(binary, file) when is_binary(binary), do: file == binary
  defp matches?(fun, file) when is_function(fun, 1), do: fun.(file)
end
