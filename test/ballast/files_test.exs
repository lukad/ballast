defmodule Ballast.FilesTest do
  use ExUnit.Case, async: false

  alias Ballast.Files

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    for path <- ~w(
      test/a_test.exs test/web/b_test.exs test/web/deep/c_test.exs
      test/test_helper.exs test/support/factory.ex test/web/helpers.exs
      spec/d_spec.exs other/e_test.exs
    ) do
      full = Path.join(dir, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, "")
    end

    cwd = File.cwd!()
    File.cd!(dir)
    on_exit(fn -> File.cd!(cwd) end)
  end

  test "default configuration finds *_test.exs under test/, sorted" do
    assert Files.discover([]) == ~w(test/a_test.exs test/web/b_test.exs test/web/deep/c_test.exs)
  end

  test "honors :test_paths" do
    assert Files.discover(test_paths: ["test", "other"]) ==
             ~w(other/e_test.exs test/a_test.exs test/web/b_test.exs test/web/deep/c_test.exs)
  end

  test "honors :testa_pattern and :test_load_filters" do
    config = [
      test_paths: ["spec"],
      test_pattern: "*_spec.exs",
      test_load_filters: [~r/_spec\.exs$/]
    ]

    assert Files.discover(config) == ~w(spec/d_spec.exs)
  end

  test "a string in :test_load_filters matches that exact path" do
    assert Files.discover(test_load_filters: ["test/a_test.exs"]) == ~w(test/a_test.exs)
  end

  test "positional paths narrow the search" do
    assert Files.discover([], ["test/web"]) == ~w(test/web/b_test.exs test/web/deep/c_test.exs)
    assert Files.discover([], ["nope"]) == []
  end

  test "a file named directly is always included" do
    assert Files.discover([], ["test/web/helpers.exs", "test/a_test.exs"]) ==
             ~w(test/a_test.exs test/web/helpers.exs)
  end

  test "absolute and repeated paths collapse to one project-relative entry", %{tmp_dir: dir} do
    assert Files.discover([], [Path.expand("test/a_test.exs"), "test/a_test.exs", "test"]) ==
             Files.discover([])

    assert Files.normalize(Path.join(dir, "test/a_test.exs")) == "test/a_test.exs"
  end

  test "normalize/2 is relative to the given root" do
    assert Files.normalize("/project/test/a_test.exs", "/project") == "test/a_test.exs"
  end
end
