defmodule Ballast do
  @moduledoc """
  Timing-balanced test sharding for ExUnit.

  `mix test --partitions` deals files out round-robin regardless of how long they
  take, so one slow shard holds up CI. Ballast records how long each file takes
  and balances the shards so they finish together.

    * `mix ballast.test` runs one shard, e.g. `--shard 3/8`.
    * `mix ballast.merge` builds the next snapshot from the shard reports.
    * `mix ballast.plan` shows the split without running it, e.g. `--shards 8`.
  """
end
