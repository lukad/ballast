# Ballast usage rules

Ballast splits an ExUnit suite into shards that take about the same time, based
on how long each test file took in earlier runs. `mix ballast.test --shard N/T`
replaces `mix test --partitions T`.

## Setup

- Prefer `mix igniter.install ballast`. It does all of the steps below.
- Add the dependency with `only: :test, runtime: false`.
- Set `"ballast.test"`, `"ballast.merge"` and `"ballast.plan"` to `:test` in the
  `preferred_envs` of `cli/0` in `mix.exs`. Without that, Mix runs the tasks in
  `:dev`, where Ballast is not loaded, and reports
  `The task "ballast.test" could not be found`. Do not add Ballast to `:dev`
  instead.
- Add `Ballast.Formatter` to the formatters in `test/test_helper.exs`:
  `ExUnit.start(formatters: [ExUnit.CLIFormatter, Ballast.Formatter])`. It does
  nothing under a plain `mix test`.

## Running shards

- Use `mix ballast.test --shard INDEX/TOTAL`. `INDEX` is 1-based.
- Never pass `--partitions`; it is rejected.
- Other `mix test` options and test paths are passed through to `mix test`.
- A `--formatter` flag replaces the formatters from `test_helper.exs`. When you
  pass one, also pass `--formatter Ballast.Formatter`, or no timings are
  recorded.
- `FILE:LINE` cannot be combined with `--shard`.
- `--failed`, `--stale`, `--only`, `-n`/`--name-pattern`,
  `--repeat-until-failure`, `--dry-run` and `FILE:LINE` runs are never
  recorded. That is expected, not a bug.
- `mix ballast.test --shard 3/8 --failed` reruns the failures of shard 3 and
  keeps the shard's files.
- Each shard writes `tmp/ballast/shard-INDEX-of-TOTAL.json`.
- With `--shard`, `--cover` exports `cover/ballast-INDEX.coverdata` and prints
  no summary. Combine the shards' `cover/` directories with `mix test.coverage`.
- Use `mix ballast.plan --shards TOTAL` to see the split without running tests.
  `--files INDEX` prints only that shard's files, one per line.

## Snapshots and CI

- `tmp/ballast/timings.json` is the snapshot the shards plan from. Keep it in
  the CI cache or pass it along as an artifact. Do not commit it to git.
- Every shard must see the same test files and the same snapshot, or the
  shards skip or repeat files without any error. Look up the snapshot once per
  run, in a job before the shards, and restore exactly that entry in every
  shard. Do not let each shard restore "the newest" entry on its own.
- A missing snapshot is fine: Ballast then splits like `--partitions`.
- Run `mix ballast.merge --check` after the shards on every CI run. It fails if
  the reports come from different plans, a shard is missing or repeated, or a
  shard had failures.
- Run `mix ballast.merge` to write the next snapshot, usually only on the main
  branch. It reads `tmp/ballast/shard-*.json` by default.
- `mix ballast.merge` refuses shards with failing tests. Fix the tests instead
  of passing `--partial`. `--partial` is only for bootstrapping or repairing a
  snapshot.
- For a complete GitHub Actions workflow, see the README:
  https://hexdocs.pm/ballast/readme.html#github-actions

## Not supported

- Umbrella project roots.
- Splitting one test file across shards. A shard can never be shorter than its
  slowest file.
