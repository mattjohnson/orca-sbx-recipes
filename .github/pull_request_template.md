## Summary

<!-- What does this change do, and why? -->

## Checklist

- [ ] Ran the verify loop: `sh tests/run.sh`, `shellcheck -s sh scripts/lifecycle/*.sh scripts/bootstrap.sh tests/harness.sh tests/stubs/* tests/run.sh tests/test-*.sh`, `bash scripts/build-recipe.sh && git diff --exit-code recipes/`
- [ ] Regenerated `recipes/sbx-project-sandbox.json` (via `scripts/build-recipe.sh`) if any `scripts/lifecycle/*.sh` file changed, and committed the result
- [ ] Live-tested in Orca, or explained below why that's not needed for this change
- [ ] Updated docs (README/CONTRIBUTING/etc.) if behavior or setup steps changed
