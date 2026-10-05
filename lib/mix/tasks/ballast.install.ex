defmodule Mix.Tasks.Ballast.Install.Docs do
  @moduledoc false

  def short_doc, do: "Installs Ballast into a project"

  def example, do: "mix igniter.install ballast"

  def long_doc do
    """
    #{short_doc()}

    Run through Igniter, which also adds the dependency:

        $ #{example()}

    Makes these changes:

      * adds `{:ballast, "~> 0.1", only: :test, runtime: false}` to `deps/0`
      * sets `ballast.test`, `ballast.merge` and `ballast.plan` to `:test` in
        the `preferred_envs` of `cli/0`
      * adds `Ballast.Formatter` to the formatters of `ExUnit.start/1` in
        `test/test_helper.exs`
    """
  end
end

if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.Ballast.Install do
    @shortdoc __MODULE__.Docs.short_doc()

    @moduledoc __MODULE__.Docs.long_doc()

    use Igniter.Mix.Task

    @tasks [:"ballast.test", :"ballast.merge", :"ballast.plan"]
    @test_helper "test/test_helper.exs"
    @start "ExUnit.start(formatters: [ExUnit.CLIFormatter, Ballast.Formatter])"

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :ballast,
        example: __MODULE__.Docs.example(),
        only: [:test],
        dep_opts: [runtime: false]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      igniter
      |> add_preferred_envs()
      |> add_formatter()
      |> Igniter.add_notice("""
      Before sharding in CI, read "Keeping shards consistent" and
      "GitHub Actions" in https://hexdocs.pm/ballast/readme.html
      """)
    end

    defp add_preferred_envs(igniter) do
      Enum.reduce(@tasks, igniter, fn task, igniter ->
        Igniter.Project.MixProject.update(igniter, :cli, [:preferred_envs, task], fn
          nil -> {:ok, {:code, :test}}
          zipper -> {:ok, zipper}
        end)
      end)
    end

    defp add_formatter(igniter) do
      if Igniter.exists?(igniter, @test_helper) do
        Igniter.update_elixir_file(igniter, @test_helper, &update_start/1)
      else
        Igniter.add_warning(igniter, manual_step("#{@test_helper} does not exist."))
      end
    end

    defp update_start(zipper) do
      with {:ok, call} <-
             Igniter.Code.Function.move_to_function_call(zipper, {ExUnit, :start}, [0, 1]),
           {:ok, _call} = updated <- add_to_call(call) do
        updated
      else
        _ -> {:warning, manual_step("Ballast could not update ExUnit.start/1.")}
      end
    end

    defp add_to_call(call) do
      case Igniter.Code.Function.move_to_nth_argument(call, 0) do
        {:ok, opts} ->
          Igniter.Code.Keyword.set_keyword_key(
            opts,
            :formatters,
            quote(do: [ExUnit.CLIFormatter, Ballast.Formatter]),
            &Igniter.Code.List.append_new_to_list(&1, quote(do: Ballast.Formatter))
          )

        :error ->
          {:ok, Igniter.Code.Common.replace_code(call, @start)}
      end
    end

    defp manual_step(reason) do
      """
      #{reason} Add Ballast.Formatter to the formatters in #{@test_helper}:

          #{@start}
      """
    end
  end
else
  defmodule Mix.Tasks.Ballast.Install do
    @shortdoc "#{__MODULE__.Docs.short_doc()} | Install `igniter` to use"

    @moduledoc __MODULE__.Docs.long_doc()

    use Mix.Task

    @impl Mix.Task
    def run(_argv) do
      Mix.shell().error(
        "mix ballast.install requires igniter: https://hexdocs.pm/igniter/readme.html#installation"
      )

      exit({:shutdown, 1})
    end
  end
end
