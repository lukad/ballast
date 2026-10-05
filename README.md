# Ballast

Timing-balanced test sharding for ExUnit.

`mix test --partitions` deals files out round-robin regardless of how long they
take, so one slow shard holds up CI. Ballast records how long each file takes
and balances the shards so they finish together.

    $ mix ballast.plan --shards 3
    73 files, 0 without history, max_cases 36, plan 69e9b4be5416

    shard  files  ballast  round-robin
        1     41    31.4s        38.9s
        2     22    31.4s        32.1s
        3      3    31.5s        15.6s
        4      7    31.5s        35.4s

    slowest shard: 31.5s (round-robin: 38.9s)

## Setup

```elixir
# mix.exs
def cli do
  [preferred_envs: ["ballast.test": :test, "ballast.merge": :test, "ballast.plan": :test]]
end

defp deps do
  [{:ballast, "~> 0.1", only: :test, runtime: false}]
end
```

```elixir
# test/test_helper.exs
ExUnit.start(formatters: [ExUnit.CLIFormatter, Ballast.Formatter])
```

The formatter does nothing under a plain `mix test`.

Without the `preferred_envs` entries, Mix runs the tasks in `:dev`, where the
dependency is not loaded, and reports `The task "ballast.test" could not be found`.

## Use

    $ mix ballast.test --shard 3/8          # run shard 3 of 8, write tmp/ballast/shard-3-of-8.json
    $ mix ballast.merge --check             # check that shards 1..8 share a plan and cover every file once
    $ mix ballast.merge                     # write tmp/ballast/timings.json for the next run
    $ mix ballast.plan --shards 8           # show the split without running it

Other `mix test` options, such as `--exclude`, `--warnings-as-errors` and
`--failed`, are passed through unchanged. Test paths narrow which files get
sharded. `--partitions` is rejected, because `--shard` replaces it.

`mix help ballast.test`, `mix help ballast.plan` and `mix help ballast.merge`
list every option.

With no snapshot, Ballast splits exactly like `--partitions`.

## Keeping shards consistent

Every shard computes the plan on its own machine. They only agree if they see
the same test files and the same snapshot.

- Keep `tmp/ballast/timings.json` in the CI cache, not in git. Restore it in
  one job and hand that copy to every shard. If each shard job restores the
  cache itself, another run can save a newer snapshot in between, and two
  shards of one run plan from different snapshots.
- Run `mix ballast.merge --check` on every CI run. Without it, disagreeing
  shards silently skip or repeat files.

## GitHub Actions

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:

env:
  MIX_ENV: test

jobs:
  timings:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/cache/restore@v6
        with:
          path: tmp/ballast/timings.json
          key: ballast-timings-${{ github.run_id }}
          restore-keys: ballast-timings-
      # No cache yet: an empty snapshot plans like --partitions.
      - run: |
          mkdir -p tmp/ballast
          test -f tmp/ballast/timings.json ||
            echo '{"version": 1, "max_cases": 1, "files": {}}' > tmp/ballast/timings.json
      - uses: actions/upload-artifact@v7
        with: { name: ballast-timings, path: tmp/ballast/timings.json }

  test:
    needs: timings
    runs-on: ubuntu-24.04
    strategy:
      fail-fast: false
      matrix:
        shard: [1, 2, 3, 4]
    steps:
      - uses: actions/checkout@v7
      - uses: erlef/setup-beam@v1
        with: { elixir-version: "1.20", otp-version: "27" }
      - run: mix deps.get
      - uses: actions/download-artifact@v8
        with: { name: ballast-timings, path: tmp/ballast }
      - run: mix ballast.test --shard ${{ matrix.shard }}/${{ strategy.job-total }}
      - uses: actions/upload-artifact@v7
        with:
          name: ballast-shard-${{ matrix.shard }}
          path: tmp/ballast/shard-*.json

  verify:
    needs: test
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v7
      - uses: erlef/setup-beam@v1
        with: { elixir-version: "1.20", otp-version: "27" }
      - run: mix deps.get
      - uses: actions/download-artifact@v8
        with:
          { pattern: ballast-shard-*, path: tmp/ballast, merge-multiple: true }
      - run: mix ballast.merge --check
      - if: github.ref == 'refs/heads/main'
        run: mix ballast.merge
      # Cache entries are immutable, so every run on main saves a new one and
      # restore-keys picks the newest.
      - if: github.ref == 'refs/heads/main'
        uses: actions/cache/save@v6
        with:
          path: tmp/ballast/timings.json
          key: ballast-timings-${{ github.run_id }}
```

## Details

- Sync modules add up; async modules overlap up to `max_cases`. A shard costs
  `sync + max(longest async module, async / max_cases)`.
- New files get the median weight of the known ones until they have a timing
  of their own.
- With `--shard`, `--cover` exports `cover/ballast-N.coverdata` and prints no
  summary. Collect the `cover/` directories and run `mix test.coverage` for the
  combined report and threshold.
- `mix ballast.test --shard 3/8 --failed` reruns the failures of shard 3. The
  plan is computed on the full suite first, so the shard keeps its files.
  (`--partitions --failed` re-partitions the failed files.)
- Partial runs (`--failed`, `--stale`, `--only`, `-n`,
  `--repeat-until-failure`, `--dry-run`, `FILE:LINE`) are never recorded.
- `mix ballast.merge` refuses shards with failures, because a failing test is
  not a representative timing. `--partial` overrides this, for bootstrapping or
  repairing a snapshot.

## Not supported yet

Umbrella roots, `FILE:LINE` together with `--shard`, and splitting a single
file across shards.

## License

Licensed under either of:

- [Apache License, Version 2.0](./LICENSE-APACHE)
- [MIT license](./LICENSE-MIT)

at your option.

Unless you explicitly state otherwise, any contribution intentionally submitted
for inclusion in this project shall be dual licensed as above, without any
additional terms or conditions.
