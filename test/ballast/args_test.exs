defmodule Ballast.ArgsTest do
  use ExUnit.Case, async: true

  alias Ballast.Args

  defp parse!(argv) do
    assert {:ok, args} = Args.parse(argv)
    args
  end

  test "defaults" do
    assert parse!([]) == %Args{}
  end

  test "own options are taken out, the rest goes to mix test unchanged" do
    args =
      parse!(
        ~w(--shard 3/8 --trace --timings t.json --seed 0 --exclude slow --exclude db:true --report r.json)
      )

    assert args.shard == {3, 8}
    assert args.timings == "t.json"
    assert args.report == "r.json"
    assert args.passthrough == ~w(--trace --seed 0 --exclude slow --exclude db:true)
    assert args.paths == []
  end

  test "positional paths are told apart from switch values" do
    args =
      parse!(
        ~w(--shard 1/2 --max-cases 4 test/web --export-coverage shard1 test/core/a_test.exs --trace)
      )

    assert args.paths == ~w(test/web test/core/a_test.exs)
    assert args.passthrough == ~w(--max-cases 4 --export-coverage shard1 --trace)
  end

  test "unknown and negated switches and aliases pass through" do
    assert parse!(~w(--no-color --no-deps-check)).passthrough == ~w(--no-color --no-deps-check)
    assert parse!(~w(-n foo.*bar)).passthrough == ~w(--name-pattern foo.*bar)

    assert parse!(~w(--some-future-flag --other-flag value)).passthrough ==
             ~w(--some-future-flag --other-flag value)
  end

  test "a sharded --cover exports coverdata named after the shard, unless told otherwise" do
    assert parse!(~w(--shard 3/8 --cover)).passthrough == ~w(--cover --export-coverage ballast-3)

    assert parse!(~w(--shard 3/8 --cover --export-coverage mine)).passthrough ==
             ~w(--cover --export-coverage mine)

    assert parse!(~w(--cover)).passthrough == ~w(--cover)
    assert parse!(~w(--shard 3/8 --no-cover)).passthrough == ~w(--no-cover)
  end

  test "runs that execute only part of a shard are not recorded" do
    assert parse!(~w(--shard 1/2)).record?
    assert parse!(~w(--shard 1/2 --exclude slow --max-failures 1 --cover)).record?

    for flags <- [
          ~w(--no-record),
          ~w(--failed),
          ~w(--stale),
          ~w(--only wip),
          ~w(-n foo),
          ~w(--dry-run),
          ~w(--repeat-until-failure 10)
        ] do
      refute parse!(["--shard", "1/2" | flags]).record?, "#{inspect(flags)} should not record"
    end
  end

  test "bad --shard values" do
    for value <- ~w(0/4 5/4 4 a/b 1/0 -1/4 1/2/3 1.5/2) do
      assert {:error, message} = Args.parse(["--shard", value])
      assert message =~ "INDEX/TOTAL"
    end
  end

  test "invalid switch values" do
    assert {:error, message} = Args.parse(~w(--trace=yes))
    assert message =~ "--trace"
  end

  test "--partitions is refused, with or without --shard" do
    for argv <- [~w(--shard 1/2 --partitions 2), ~w(--partitions 2)] do
      assert {:error, message} = Args.parse(argv)
      assert message =~ "--partitions is not supported"
    end
  end

  test "FILE:LINE cannot be sharded but still works unsharded" do
    assert {:error, message} = Args.parse(~w(--shard 1/2 test/a_test.exs:12))
    assert message =~ "FILE:LINE"

    assert parse!(~w(test/a_test.exs:12)).paths == ~w(test/a_test.exs:12)
  end
end
