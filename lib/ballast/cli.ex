defmodule Ballast.CLI do
  @moduledoc false

  def parse!(argv, switches) do
    case OptionParser.parse(argv, strict: switches) do
      {opts, paths, []} -> {opts, paths}
      {_, _, [{switch, _} | _]} -> Mix.raise("ballast: invalid option #{switch}")
    end
  end

  def unwrap!({:ok, value}), do: value
  def unwrap!({:error, message}), do: Mix.raise("ballast: " <> message)

  def seconds(us), do: :erlang.float_to_binary(us / 1_000_000, decimals: 1) <> "s"
end
