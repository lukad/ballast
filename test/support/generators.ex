defmodule Ballast.Generators do
  @moduledoc false

  use ExUnitProperties

  @doc "A `t:Ballast.Timings.entry/0`."
  def entry do
    gen all(
          sync <- integer(0..5_000_000),
          async <- integer(0..5_000_000),
          longest <- integer(0..async),
          # Not map_of/3: with only three keys it regularly gives up on duplicates
          groups <-
            map(
              list_of({member_of([":db", ":search", "{:shard, 1}"]), integer(0..5_000_000)},
                max_length: 2
              ),
              &Map.new/1
            )
        ) do
      {sync, async, longest, groups}
    end
  end
end
