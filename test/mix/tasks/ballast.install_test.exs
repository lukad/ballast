defmodule Mix.Tasks.Ballast.InstallTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  defp install(files \\ %{}) do
    [files: files]
    |> test_project()
    |> Igniter.compose_task("ballast.install", [])
  end

  test "sets up a new project" do
    install()
    |> assert_has_patch("mix.exs", """
       + |  def cli do
       + |    [
       + |      preferred_envs: ["ballast.test": :test, "ballast.merge": :test, "ballast.plan": :test]
       + |    ]
       + |  end
    """)
    |> assert_has_patch("test/test_helper.exs", """
    - |ExUnit.start()
    + |ExUnit.start(formatters: [ExUnit.CLIFormatter, Ballast.Formatter])
    """)
  end

  test "keeps existing preferred_envs" do
    install(%{
      "mix.exs" => """
      defmodule Test.MixProject do
        use Mix.Project

        def project do
          [app: :test, version: "0.1.0", deps: deps()]
        end

        def cli do
          [preferred_envs: [precommit: :test]]
        end

        defp deps do
          []
        end
      end
      """
    })
    |> assert_has_patch("mix.exs", """
    - |    [preferred_envs: [precommit: :test]]
    + |    [
    + |      preferred_envs: [
    + |        precommit: :test,
    + |        "ballast.test": :test,
    + |        "ballast.merge": :test,
    + |        "ballast.plan": :test
    + |      ]
    + |    ]
    """)
  end

  test "keeps other ExUnit.start options" do
    install(%{"test/test_helper.exs" => "ExUnit.start(exclude: [:slow])\n"})
    |> assert_has_patch("test/test_helper.exs", """
    - |ExUnit.start(exclude: [:slow])
    + |ExUnit.start(exclude: [:slow], formatters: [ExUnit.CLIFormatter, Ballast.Formatter])
    """)
  end

  test "appends to existing formatters" do
    install(%{"test/test_helper.exs" => "ExUnit.start(formatters: [Foo])\n"})
    |> assert_has_patch("test/test_helper.exs", """
    - |ExUnit.start(formatters: [Foo])
    + |ExUnit.start(formatters: [Foo, Ballast.Formatter])
    """)
  end

  test "changes nothing when run again" do
    install()
    |> apply_igniter!()
    |> Igniter.compose_task("ballast.install", [])
    |> assert_unchanged()
  end

  test "warns when it cannot find the formatters" do
    for helper <- ["Mox.defmock(Foo, for: Bar)\n", "ExUnit.start(opts)\n"] do
      install(%{"test/test_helper.exs" => helper})
      |> assert_unchanged("test/test_helper.exs")
      |> assert_has_warning(&(&1 =~ "Add Ballast.Formatter"))
    end
  end
end
