defmodule Ballast.TimingsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Ballast.Generators

  alias Ballast.Timings

  defp timings do
    gen all(
          files <-
            map_of(
              string(:printable, min_length: 1, max_length: 30),
              entry(),
              max_length: 60
            ),
          max_cases <- integer(1..64)
        ) do
      %Timings{max_cases: max_cases, files: files}
    end
  end

  property "encode/decode round-trips, including odd file names" do
    check all(timings <- timings()) do
      assert timings |> Timings.encode() |> IO.iodata_to_binary() |> Timings.decode() ==
               {:ok, timings}
    end
  end

  test "files are written one per line in sorted order, so diffs stay small" do
    # Maps are only iterated in order up to 32 keys
    files = Map.new(1..100, &{"test/f#{&1}_test.exs", {&1, 0, 0, %{}}})
    encoded = %Timings{files: files} |> Timings.encode() |> IO.iodata_to_binary()

    paths = Regex.scan(~r/^    "([^"]+)":/m, encoded, capture: :all_but_first) |> List.flatten()

    assert length(paths) == 100
    assert paths == Enum.sort(paths)
  end

  test "groups are only written for files that have them" do
    files = %{"a" => {1, 0, 0, %{}}, "b" => {0, 0, 0, %{":search" => 2, ":db" => 3}}}
    encoded = %Timings{files: files} |> Timings.encode() |> IO.iodata_to_binary()

    assert encoded =~ ~s("a": {"sync_us": 1, "async_us": 0, "longest_async_us": 0},\n)

    assert encoded =~
             ~s("b": {"sync_us": 0, "async_us": 0, "longest_async_us": 0, "groups": {":db": 3, ":search": 2}}\n)
  end

  test "version 1 snapshots still load, without groups" do
    v1 =
      ~s({"version": 1, "max_cases": 4, "files": {"a": {"sync_us": 1, "async_us": 2, "longest_async_us": 2}}})

    assert Timings.decode(v1) == {:ok, %Timings{max_cases: 4, files: %{"a" => {1, 2, 2, %{}}}}}
  end

  test "group keys are not truncated" do
    assert Timings.group_key(:db) == ":db"
    assert Timings.group_key("db") == ~s("db")
    assert Timings.group_key(List.duplicate(1, 100)) != Timings.group_key(List.duplicate(1, 101))
  end

  @tag :tmp_dir
  test "a missing snapshot is empty, not an error", %{tmp_dir: dir} do
    assert Timings.read(Path.join(dir, "nope.json")) == {:ok, %Timings{}}
  end

  @tag :tmp_dir
  test "damaged snapshots are rejected with the path in the message", %{tmp_dir: dir} do
    for {name, content} <- [
          {"garbage", "not json"},
          {"version", ~s({"version": 3, "max_cases": 1, "files": {}})},
          {"shape", ~s({"version": 1, "files": {}})},
          {"entry",
           ~s({"version": 1, "max_cases": 1, "files": {"a": {"sync_us": -1, "async_us": 0, "longest_async_us": 0}}})},
          {"longest",
           ~s({"version": 1, "max_cases": 1, "files": {"a": {"sync_us": 0, "async_us": 1, "longest_async_us": 2}}})},
          {"missing longest",
           ~s({"version": 1, "max_cases": 1, "files": {"a": {"sync_us": 0, "async_us": 0}}})},
          {"groups",
           ~s({"version": 2, "max_cases": 1, "files": {"a": {"sync_us": 0, "async_us": 0, "longest_async_us": 0, "groups": [1]}}})},
          {"group",
           ~s({"version": 2, "max_cases": 1, "files": {"a": {"sync_us": 0, "async_us": 0, "longest_async_us": 0, "groups": {":db": -1}}}})},
          {"zero", ~s({"version": 1, "max_cases": 0, "files": {}})}
        ] do
      path = Path.join(dir, name <> ".json")
      File.write!(path, content)

      assert {:error, message} = Timings.read(path)
      assert message =~ path
    end
  end
end
