# Contributing

Contributions are welcome. This is a small, focused plugin — one recipe, one job — and it's meant to stay that way, so expect scope to stay tight even as PRs come in.

## Dev setup

Clone the repo. You need POSIX `sh`, `shellcheck`, `jq`, and `bash` to develop and test — `sbx` itself is only needed if you're live-testing against a real sandbox.

The verify loop, three commands, run before every PR:

```sh
sh tests/run.sh
shellcheck -s sh scripts/lifecycle/*.sh scripts/bootstrap.sh tests/harness.sh tests/stubs/* tests/run.sh tests/test-*.sh
bash scripts/build-recipe.sh && git diff --exit-code recipes/
```

## How the code is organized

- `scripts/lifecycle/` — the actual `create`/`suspend`/`resume`/`destroy` logic, written in POSIX `sh`. These run *inside* the user's environment at recipe-execution time, so no `jq`, `node`, or `python` at runtime — only what's guaranteed to exist on the host/VM shell.
- `recipes/sbx-project-sandbox.json` is **generated** by `scripts/build-recipe.sh`, which inlines the lifecycle scripts into the plugin's recipe artifact. Never hand-edit it — edit the source in `scripts/lifecycle/`, regenerate, and commit the updated artifact alongside your change.
- `tests/` runs the concatenated lifecycle sources (`scripts/lifecycle/common.sh` + the per-command script — the same text `scripts/build-recipe.sh` inlines into the artifact) against `sbx`/`git` binaries stubbed onto `PATH` from `tests/stubs/`. `tests/test-recipe-artifact.sh`'s drift check, plus `bash scripts/build-recipe.sh && git diff --exit-code recipes/`, make the generated artifact provably equivalent to what the tests exercise, so tests still cover what actually ships.

## Live-testing a change in Orca

Install the plugin from your local clone path via Orca → Settings → Plugins.

Important quirk: Orca copies plugin content at install time, not at run time. After *any* recipe change, you must reinstall the plugin and start a brand-new workspace to pick it up — never click Retry on an existing workspace, since Retry replays the old install's snapshot and will silently test stale code.

## Pull requests

Fork, branch, open a PR. CI must be green, and all changes go through maintainer review before merge — this repo has one maintainer, so please be patient. Keep diffs small and scoped to one behavior change, and explain the sbx/Orca behavior your change addresses — link to a findings doc or upstream issue where you can, since the sbx/Orca surface here is quirky enough that "why" matters more than "what."

## Reporting issues

Use the issue templates. Always include your `sbx version` and the output of `sh scripts/bootstrap.sh` — most reports are unresolvable without them.

## Licensing of contributions

By contributing, you agree your contributions are licensed under the MIT License, same as the rest of the project. No CLA required.
