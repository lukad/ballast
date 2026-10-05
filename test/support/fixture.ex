defmodule Ballast.Fixture do
  @moduledoc """
  A throwaway Mix project that depends on Ballast by path, for tests that
  need a real `mix test` run.

  Each test file appends its path to `$RUN_LOG`, so tests can see what
  actually ran.

  Files sleep only when `$SLEEP` is set.
  """

  @ballast_root Path.expand("../..", __DIR__)

  # {name, sleep in ms, async?}. Sorted round-robin over 3 shards groups
  # t01, t04, t07 and t10, the worst split for these.
  @files [
    {"t01", 600, false},
    {"t02", 20, false},
    {"t03", 20, false},
    {"t04", 300, false},
    {"t05", 50, false},
    {"t06", 50, false},
    {"t07", 200, false},
    {"t08", 400, true},
    {"t09", 400, true},
    {"t10", 150, false},
    {"t11", 100, true},
    {"web/t12", 100, true}
  ]

  def files, do: for({name, _, _} <- @files, do: "test/sample/#{name}_test.exs")

  def create!(dir) do
    File.rm_rf!(dir)
    File.mkdir_p!(Path.join(dir, "test/sample/web"))
    File.mkdir_p!(Path.join(dir, "test/support"))

    write!(dir, "mix.exs", """
    defmodule Sample.MixProject do
      use Mix.Project

      def project do
        [app: :sample, version: "0.1.0", elixirc_paths: ["lib", "test/support"], deps: deps()]
      end

      def cli, do: [preferred_envs: ["ballast.test": :test, "ballast.merge": :test, "ballast.plan": :test]]

      defp deps, do: [{:ballast, path: #{inspect(@ballast_root)}, only: :test}]
    end
    """)

    write_helper!(dir, "ExUnit.start(formatters: [ExUnit.CLIFormatter, Ballast.Formatter])")

    # Only t01 calls this, keeping single-shard coverage far below 100%.
    File.mkdir_p!(Path.join(dir, "lib"))
    write!(dir, "lib/sample.ex", "defmodule Sample do\n  def one, do: 1\n  def two, do: 2\nend\n")

    # Files `mix test` must not load. If Ballast.Files drifts from what
    # `mix test` does, one of these shows up in a plan.
    write!(dir, "test/support/factory.ex", "defmodule Sample.Factory do\nend\n")
    write!(dir, "test/sample/shared.exs", "# required by nobody\n")

    for {name, sleep, async?} <- @files do
      path = "test/sample/#{name}_test.exs"
      module = name |> String.replace("/", "_") |> Macro.camelize()

      write!(dir, path, """
      defmodule Sample.#{module}Test do
        use ExUnit.Case, async: #{async?}

        test "runs" do
          File.write!(System.fetch_env!("RUN_LOG"), "#{path}\\n", [:append])
          if System.get_env("SLEEP"), do: Process.sleep(#{sleep})
          #{if name == "t01", do: "assert Sample.one() + Sample.two() == 3", else: ""}
          if System.get_env("FAIL_FILE") == "#{name}", do: flunk("asked to fail")
        end
      end
      """)
    end

    dir
  end

  def write_helper!(dir, content), do: write!(dir, "test/test_helper.exs", content <> "\n")

  @doc """
  Runs `mix ARGS` in the fixture with MIX_ENV unset. Returns `{output, status, files_run}`.

  Each call logs to its own file, so concurrent calls are safe.
  """
  def mix(dir, args, env \\ []) do
    log = Path.join(dir, "run-#{System.unique_integer([:positive])}.log")

    {output, status} =
      System.cmd("mix", args,
        cd: dir,
        stderr_to_stdout: true,
        env: [{"MIX_ENV", nil}, {"RUN_LOG", log}] ++ env
      )

    ran =
      case File.read(log) do
        {:ok, content} -> content |> String.split("\n", trim: true) |> Enum.sort()
        {:error, :enoent} -> []
      end

    File.rm(log)

    {output, status, ran}
  end

  defp write!(dir, path, content), do: File.write!(Path.join(dir, path), content)
end
