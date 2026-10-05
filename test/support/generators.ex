defmodule Ballast.Generators do
  @moduledoc false

  use ExUnitProperties

  @doc "A `t:Ballast.Timings.entry/0`."
  def entry do
    gen all(
          sync <- integer(0..5_000_000),
          async <- integer(0..5_000_000),
          longest <- integer(0..async)
        ) do
      {sync, async, longest}
    end
  end
end
