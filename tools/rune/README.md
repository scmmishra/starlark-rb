# Rune CI card

A [Rune](https://github.com/scmmishra/rune) card that shows CI for this repo. It has three rows.

- **GitHub · main.** The latest `CI` run on `main`. Click it to open the run. Each failed job adds a row that opens its log.
- **Local tests.** The last local `bundle exec rspec` run. Each failing example adds a row. Click it to open the example in Rune's drawer.
- **Coverage.** Line and branch coverage from that run.

## Setup

Rune reads cards only from `~/.rune/cards`. Link the card file there:

```bash
ln -s "$PWD/tools/rune/starlark-ci.toml" ~/.rune/cards/starlark-ci.toml
```

Then add the card in Rune with **Show Card…** in the command palette.

The script needs `gh`, logged in. It uses only Ruby's standard library, so any Ruby on the login shell's `PATH` works, including the macOS system Ruby.

## Where the numbers come from

Rune stops a card after 10 seconds, so the card never runs the tests. It reads files from your last run.

| File | Written by |
|---|---|
| `tmp/rspec.json` | The JSON formatter in `.rspec` |
| `coverage/.last_run.json` | SimpleCov, from `spec/spec_helper.rb` |

The badges mean:

| Badge | Meaning |
|---|---|
| Green `✓` | Passed, or coverage meets its target. |
| Red `✗` | A failure, or coverage below its target. |
| Orange `!` | The local results may be out of date. See below. |
| Yellow `●` | The GitHub run is queued or running. |

The local badges turn orange in these cases:

- A file in `lib/`, `spec/`, or `.rspec` changed after the last run.
- The last run skipped some spec files, such as `rspec spec/lexer_spec.rb`. Coverage from a partial run is lower than the full suite's.
- SimpleCov did not write coverage on the last run.

The coverage targets are 100% for lines and 95% for branches. They are constants at the top of `ci-card`.
