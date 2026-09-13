# Contributing

gangplank is a few hundred lines of shell and one workflow file. Keeping it that small is the point, so the bar for a change is: does it make a deploy safer, or the tool simpler.

## Before you open a PR

- Run `shellcheck` on every script you touched; CI runs it with `--severity=error` and the repo stays clean.
- Add or update a test in `tests/` that spawns the real script. Tests never reimplement a script's logic.
- Keep the gate free of network calls and external commands. It has no timeout, so it must finish on its own.
- No new runtime dependencies. The tool depends on bash, git, and the GitHub runner, and nothing else.

## What a PR needs

- A title that says what changes for the person running it, not what changed in the code.
- One paragraph on what it does not change.
- If it touches the gate or the deploy path, one sentence on how to undo it.

## Reporting a problem

Open an issue with the run log from GitHub (the failing step's output) and the output of `gangplank status`. Do not paste anything from your `.env`.

## License

By contributing you agree your work is released under the MIT license in this repo.
