# orca-sbx-recipes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Interactivity note:** Phase 0 (Tasks 1–3) and Phase 2 (Task 11) require Matt at the keyboard (browser OAuth login, Orca desktop UI). Run those inline with Matt present. Phase 1 (Tasks 4–10) is fully automatable and suits subagents.

**Goal:** Ship an Orca plugin whose vm recipe provisions one Docker Sandboxes (sbx) microVM per project, shared by all of that project's worktrees, connected to Orca over SSH.

**Architecture:** Lifecycle logic lives in POSIX-sh source scripts under `scripts/lifecycle/`; a build script inlines them (with a shared preamble) into the recipe JSON artifact that the plugin contributes, because Orca executes plugin recipe commands as bare strings. Tests run the exact concatenated command text against PATH-stubbed `sbx`/`ssh`/`git` binaries. A hands-on spike gates everything: Orca's SSH relay must come up inside an sbx VM before any pack code is written.

**Tech Stack:** POSIX sh (lifecycle), bash + jq (dev tooling only), shellcheck, GitHub Actions, Docker Sandboxes (`sbx`) CLI, Orca's ephemeral-VM recipe contract.

**Spec:** `docs/superpowers/specs/2026-08-17-sbx-project-sandbox-design.md` (read it first; this plan argues from it).

## Global Constraints

- Lifecycle command strings are POSIX sh, executed by Orca with `shell: true`, cwd = the consuming project's repo, on macOS/Linux. **Windows is out of scope for v1.**
- `create` and `resume` stdout must be **exactly one JSON object** (Orca parses it); every other line of output goes to stderr (`1>&2`).
- Each recipe command must stay under Orca's **32KB** per-command cap.
- Lifecycle scripts may not depend on `jq`, `node`, or `python` on the user's machine — only `sh`, `sed`, `awk`, `grep`, `git`, `ssh`, `shasum`/`sha256sum`, and `sbx`.
- Sandbox naming scheme: `orca-p-<first 12 hex of sha256(ORCA_PROJECT_ID)>` (regex `^orca-p-[0-9a-f]{12}$`).
- In-VM clone path: `<remote $HOME>/project`. Host bookkeeping dir: `~/.orca-sbx/<name>/`.
- `suspend` is a no-op; `destroy` refcounts (removes the VM only when no linked worktrees remain).
- Recipe result JSON must satisfy Orca's schema: `{"schemaVersion":1,"connection":{"type":"ssh","projectRoot":<abs path>,"target":{label,host,port,username,...}},"userData":{...}}` — `projectRoot` absolute, `port` a number.
- Commit style: conventional commits (`feat:`, `fix:`, `test:`, `docs:`, `chore:`), suffixed `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- **Spike gate:** Tasks 4+ must not start until Task 3's decision gate records PASS in `docs/spike/2026-08-17-findings.md`.

---

## Phase 0 — Validation spike (interactive, gates everything)

### Task 1: sbx install + sandbox + SSH smoke test

**Files:**
- Create: `docs/spike/2026-08-17-findings.md`

**Interfaces:**
- Produces: a findings file whose recorded values (sbx version, exact `sbx create` syntax, template user + `$HOME`, `ssh -G` output) later tasks copy into scripts. All subsequent tasks treat this file as the source of truth where it disagrees with this plan's best-guess command syntax.

- [ ] **Step 1: Install sbx and log in (Matt at keyboard)**

Run (macOS Apple silicon):
```bash
brew trust docker/tap && brew install docker/tap/sbx
sbx login          # opens browser OAuth — Matt completes it
sbx policy init balanced
sbx version
```
Record in findings: sbx version string, install method.

- [ ] **Step 2: Create a throwaway project sandbox**

```bash
mkdir -p ~/.orca-sbx/spike/workspace
sbx create --name orca-spike claude ~/.orca-sbx/spike/workspace
```
If that argument order is rejected, try `sbx create --name orca-spike -t docker/sandbox-templates:claude-code ~/.orca-sbx/spike/workspace` and record whichever form works verbatim in findings (this is the single most load-bearing recorded fact).

- [ ] **Step 3: Verify the in-VM toolchain**

```bash
sbx exec orca-spike -- sh -c 'whoami; echo "$HOME"; node --version; git --version; command -v claude'
```
Record: username, `$HOME`, node version (must exist — Orca's relay hard-requires it), git version, claude path. If node is missing from the template, record the install command that fixes it (`sbx exec orca-spike -- sh -c 'curl -fsSL https://deb.nodesource.com/setup_22.x | sudo bash - && sudo apt-get install -y nodejs'` or the template-appropriate equivalent) — create.sh grows that step in Task 5.

- [ ] **Step 4: SSH plumbing**

```bash
sbx setup ssh
ssh -G orca-spike.sbx        # record full output in findings
ssh orca-spike.sbx -- echo ok
```
Record: the resolved `hostname`, `port`, `user`, `identityfile`, `proxycommand` values, and whether plain `ssh` works. Also record whether `sbx start` on an already-running sandbox exits 0.

- [ ] **Step 5: Clone a repo inside**

```bash
sbx secret set github -t "$(gh auth token)"   # or skip if using SSH-agent forwarding
sbx exec orca-spike -- git clone https://github.com/stablyai/orca-multipass-recipes /home/<recorded-user>/project
```
Record: whether the proxy-injected clone worked, or what auth adjustment was needed.

- [ ] **Step 6: Write findings + commit**

Create `docs/spike/2026-08-17-findings.md` with sections: `## sbx version`, `## create syntax`, `## in-VM toolchain` (user/home/node/git/claude), `## ssh -G output`, `## sbx start idempotency`, `## clone auth`, `## Task 2: Orca relay`, `## Task 3: decision` (last two filled by later tasks). Fill everything observed so far.

```bash
git add docs/spike/2026-08-17-findings.md
git commit -m "docs: record sbx spike findings (install, create, ssh, clone)"
```

### Task 2: Orca relay validation against the sbx VM

**Files:**
- Modify: `docs/spike/2026-08-17-findings.md` (fill `## Task 2: Orca relay`)

**Interfaces:**
- Consumes: the running `orca-spike` sandbox and recorded SSH values from Task 1.
- Produces: PASS/FAIL per criterion below, and the answer to "configHost vs explicit fields" that Task 5's `emit_connection_json` depends on.

- [ ] **Step 1: Add the sandbox as a plain SSH host in Orca (Matt in the app)**

In the Orca desktop app: add an SSH host targeting `orca-spike.sbx` (the host alias written by `sbx setup ssh`). If Orca's add-host flow requires explicit host/port/user instead of an alias, use the `ssh -G` values from Task 1 — and record which form Orca accepted (this decides the recipe's target JSON shape).

- [ ] **Step 2: Verify the relay comes up**

Criteria to record as PASS/FAIL, each with what was observed:
1. Orca connects; git + filesystem providers become ready (worktree/file panels populate) within ~10s.
2. Import `/home/<user>/project` as a repo on that host.
3. Create a worktree through Orca on that host — linked worktree appears inside the VM (`sbx exec orca-spike -- git -C /home/<user>/project worktree list`).
4. Open a terminal in that workspace; launch claude; agent busy/idle status and tab identity behave as on any SSH host.
5. Claude auth works via `sbx secret set anthropic` or in-sandbox `/login` (record which).

- [ ] **Step 3: Second-workspace idempotency**

Create a second Orca worktree/workspace against the same imported repo. Record: both workspaces work concurrently; importing the same projectRoot twice caused no duplicate/conflict.

- [ ] **Step 4: Latency sanity**

Record rough numbers: time for `sbx ls` (the ~3s CLI floor affects recipe runs), sandbox cold boot, and whether interactive typing/git in the Orca terminal feels indistinguishable from a normal SSH host (SSH traffic does not pass through the sbx CLI, so steady-state should be clean — confirm).

- [ ] **Step 5: Record + commit**

```bash
git add docs/spike/2026-08-17-findings.md
git commit -m "docs: record Orca relay spike results"
```

### Task 3: Decision gate + plan reconciliation

**Files:**
- Modify: `docs/spike/2026-08-17-findings.md` (fill `## Task 3: decision`)
- Modify: `docs/superpowers/plans/2026-08-17-sbx-project-sandbox.md` (only if findings contradict planned command syntax)

- [ ] **Step 1: Evaluate the gate**

PASS requires: relay criteria 1–4 from Task 2 all PASS. If any FAIL: **STOP. Do not start Task 4.** Record the failure, and report back to Matt with the spec's stated fallback (plain docker+sshd engine) as a design decision to make together — per spec, this is not a decision to make silently.

- [ ] **Step 2: Reconcile the plan with findings**

Where findings differ from this plan's best guesses, edit the affected code blocks in Tasks 4–8 now (exact `sbx create` invocation; template user/home; node-install step if the template lacked node; whether `emit_connection_json` keeps `configHost`, explicit fields, or both). Record each edit in the findings file's decision section.

- [ ] **Step 3: Clean up spike sandbox + commit**

```bash
sbx rm -f orca-spike && rm -rf ~/.orca-sbx/spike
git add -A && git commit -m "docs: spike decision gate result and plan reconciliation"
```

---

## Phase 1 — Pack implementation (TDD against stubs)

### Task 4: Test harness, stubs, and `common.sh`

**Files:**
- Create: `scripts/lifecycle/common.sh`
- Create: `tests/harness.sh`, `tests/stubs/sbx`, `tests/stubs/ssh`, `tests/stubs/git`, `tests/run.sh`
- Test: `tests/test-common.sh`
- Create: `.github/workflows/ci.yml`

**Interfaces:**
- Produces (in `common.sh`, consumed by Tasks 5–7): `fail msg…`, `require_env`, `require_sbx`, `hash_cmd` (stdin→sha256 hex), `payload_sandbox_name` (stdin JSON→name or empty), `sandbox_name [payloadName]`, `sandbox_exists name`, `json_escape` (stdin filter), `ssh_cfg name key`, `emit_connection_json name`.
- Produces (in `tests/harness.sh`, consumed by all test files): `$TESTTMP`, `$SBX_LOG`, `lifecycle_cmd name` (prints common.sh + script), `run_lifecycle name` (executes it via `sh -c`), `assert_eq got expected label`, `assert_contains haystack needle label`, `finish`.
- Stub contract (env-driven): `STUB_LS_JSON` (output of `sbx ls --json`, default `[]`), `STUB_HAS_CLONE` (0 = `.git` exists in VM), `STUB_WORKTREES` (worktree count for `worktree list --porcelain`), `STUB_SSH_PROXY` (adds a `proxycommand` line to `ssh -G`); every sbx invocation appends `$*` as one line to `$SBX_LOG`.

- [ ] **Step 1: Write the failing test**

`tests/test-common.sh`:
```sh
#!/bin/sh
. "$(dirname "$0")/harness.sh"

# name derivation is deterministic and matches the documented scheme
export ORCA_PROJECT_ID="proj-123"
expected="orca-p-$(printf '%s' "proj-123" | { command -v shasum >/dev/null 2>&1 && shasum -a 256 || sha256sum; } | cut -c1-12)"
got="$(sh -c "$(cat scripts/lifecycle/common.sh); sandbox_name")"
assert_eq "$got" "$expected" "derived name"

# payload name wins over derivation, and only well-formed names are accepted
got="$(printf '{"userData":{"sandboxName":"orca-p-abc123def456"}}' \
  | sh -c "$(cat scripts/lifecycle/common.sh); sandbox_name \"\$(payload_sandbox_name)\"")"
assert_eq "$got" "orca-p-abc123def456" "payload name"
got="$(printf '{"userData":{"sandboxName":"NOT-A-NAME"}}' \
  | sh -c "$(cat scripts/lifecycle/common.sh); sandbox_name \"\$(payload_sandbox_name)\"")"
assert_eq "$got" "$expected" "malformed payload name falls back to derivation"

# emit_connection_json produces the contract shape from stubbed ssh -G + sbx exec
out="$(sh -c "$(cat scripts/lifecycle/common.sh); emit_connection_json orca-p-abc123def456")"
printf '%s' "$out" | jq -e '
  .schemaVersion == 1
  and .connection.type == "ssh"
  and (.connection.projectRoot | startswith("/"))
  and .connection.target.configHost == "orca-p-abc123def456.sbx"
  and (.connection.target.port | type == "number")
  and .userData.sandboxName == "orca-p-abc123def456"' >/dev/null \
  || { echo "FAIL emit_connection_json shape: $out"; FAILURES=$((FAILURES+1)); }

finish
```
(jq is fine **in tests** — the no-jq rule is for user-side lifecycle scripts only.)

- [ ] **Step 2: Write the harness and stubs (test infrastructure, not the code under test)**

`tests/harness.sh`:
```sh
# shellcheck shell=sh
set -u
cd "$(dirname "$0")/.." || exit 1
TESTTMP="$(mktemp -d)"; trap 'rm -rf "$TESTTMP"' EXIT
export HOME="$TESTTMP/home"; mkdir -p "$HOME"
export SBX_LOG="$TESTTMP/sbx.log"; : > "$SBX_LOG"
PATH="$(pwd)/tests/stubs:$PATH"; export PATH
FAILURES=0
lifecycle_cmd() { cat scripts/lifecycle/common.sh "scripts/lifecycle/$1.sh"; }
run_lifecycle() { _n="$1"; shift; sh -c "$(lifecycle_cmd "$_n")" lifecycle "$@"; }
assert_eq() { [ "$1" = "$2" ] || { printf 'FAIL %s: expected [%s] got [%s]\n' "${3:-eq}" "$2" "$1"; FAILURES=$((FAILURES+1)); }; }
assert_contains() { case "$1" in *"$2"*) ;; *) printf 'FAIL %s: [%s] not found\n' "${3:-contains}" "$2"; FAILURES=$((FAILURES+1)); esac; }
finish() { if [ "$FAILURES" -eq 0 ]; then echo OK; else echo "$FAILURES failure(s)"; exit 1; fi; }
```

`tests/stubs/sbx`:
```sh
#!/bin/sh
printf '%s\n' "$*" >> "${SBX_LOG:-/dev/null}"
case "$*" in
  "ls --json") printf '%s\n' "${STUB_LS_JSON:-[]}" ;;
  "setup ssh") : ;;
  create*) : ;;
  start*) : ;;
  "rm -f "*) : ;;
  *'printf %s "$HOME"'*) printf '/home/agent' ;;
  *"test -d"*) exit "${STUB_HAS_CLONE:-1}" ;;
  *"git clone"*) : ;;
  *"worktree prune"*) : ;;
  *"worktree list --porcelain"*)
    i=0; while [ "$i" -lt "${STUB_WORKTREES:-1}" ]; do
      printf 'worktree /home/agent/wt%s\nHEAD 0000\n\n' "$i"; i=$((i+1)); done ;;
  *" true") exit 0 ;;
  *) exit "${STUB_DEFAULT_EXIT:-0}" ;;
esac
```

`tests/stubs/ssh`:
```sh
#!/bin/sh
# only supports: ssh -G <alias>
[ "$1" = "-G" ] || exit 1
printf 'user agent\nhostname 127.0.0.1\nport 52022\nidentityfile ~/.ssh/sbx_ed25519\n'
[ -n "${STUB_SSH_PROXY:-}" ] && printf 'proxycommand %s\n' "$STUB_SSH_PROXY"
exit 0
```

`tests/stubs/git`:
```sh
#!/bin/sh
case "$*" in
  *"remote get-url origin") printf 'https://example.com/repo.git\n' ;;
  *) exit 0 ;;
esac
```

`tests/run.sh`:
```sh
#!/bin/sh
set -u
cd "$(dirname "$0")/.." || exit 1
rc=0
for t in tests/test-*.sh; do
  echo "== $t"; sh "$t" || rc=1
done
exit $rc
```

```bash
chmod +x tests/stubs/sbx tests/stubs/ssh tests/stubs/git tests/run.sh
```

- [ ] **Step 3: Run test to verify it fails**

Run: `sh tests/test-common.sh`
Expected: FAIL (`scripts/lifecycle/common.sh` does not exist yet — `cat` error, non-zero exit).

- [ ] **Step 4: Implement `scripts/lifecycle/common.sh`**

```sh
# orca-sbx-recipes shared preamble — inlined ahead of every lifecycle script.
# POSIX sh. stdout is reserved for the recipe result JSON; log to stderr.
set -eu
PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:$HOME/.docker/bin"

fail() { printf 'orca-sbx: %s\n' "$*" >&2; exit 1; }

require_env() {
  [ -n "${ORCA_PROJECT_ID:-}" ] || fail "ORCA_PROJECT_ID is not set; this command must be run by Orca's recipe runner"
}

require_sbx() {
  command -v sbx >/dev/null 2>&1 \
    || fail "sbx CLI not found. Install Docker Sandboxes (https://docs.docker.com/ai/sandboxes/install/), run 'sbx login', then retry."
  sbx ls --json >/dev/null 2>&1 \
    || fail "sbx is installed but not ready. Run 'sbx login' and 'sbx policy init balanced' in a terminal, then retry."
}

hash_cmd() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256; else sha256sum; fi
}

# stdin: Orca lifecycle payload JSON → recorded sandbox name, or empty.
# Names match ^orca-p-[0-9a-f]{12}$ so this sed extraction is unambiguous.
payload_sandbox_name() {
  sed -n 's/.*"sandboxName"[[:space:]]*:[[:space:]]*"\(orca-p-[0-9a-f]\{12\}\)".*/\1/p' | head -n1
}

sandbox_name() {
  if [ -n "${1:-}" ]; then printf '%s\n' "$1"; return; fi
  printf 'orca-p-%s\n' "$(printf '%s' "$ORCA_PROJECT_ID" | hash_cmd | cut -c1-12)"
}

sandbox_exists() {
  sbx ls --json 2>/dev/null | grep -Fq "\"$1\""
}

json_escape() { sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

# $1=sandbox name, $2=ssh -G key → effective client config value
ssh_cfg() {
  ssh -G "$1.sbx" 2>/dev/null | awk -v k="$2" '$1==k { sub(/^[^ ]+ /, ""); print; exit }'
}

emit_connection_json() {
  _name="$1"
  _host="$(ssh_cfg "$_name" hostname)"; _port="$(ssh_cfg "$_name" port)"
  _user="$(ssh_cfg "$_name" user)"; _idfile="$(ssh_cfg "$_name" identityfile)"
  _proxy="$(ssh_cfg "$_name" proxycommand)"
  { [ -n "$_host" ] && [ -n "$_port" ]; } \
    || fail "could not resolve SSH config for $_name.sbx — did 'sbx setup ssh' run?"
  case "$_port" in *[!0-9]*) fail "resolved SSH port '$_port' is not numeric" ;; esac
  case "$_idfile" in "~/"*) _idfile="$HOME/${_idfile#\~/}" ;; esac
  _rhome="$(sbx exec "$_name" -- sh -c 'printf %s "$HOME"')"
  [ -n "$_rhome" ] || fail "could not resolve \$HOME inside sandbox $_name"
  _extra=""
  [ -n "$_idfile" ] && _extra="$_extra,\"identityFile\":\"$(printf '%s' "$_idfile" | json_escape)\",\"identitiesOnly\":true"
  { [ -n "$_proxy" ] && [ "$_proxy" != "none" ]; } \
    && _extra="$_extra,\"proxyCommand\":\"$(printf '%s' "$_proxy" | json_escape)\""
  printf '{"schemaVersion":1,"connection":{"type":"ssh","projectRoot":"%s/project","target":{"label":"Docker Sandbox","configHost":"%s.sbx","host":"%s","port":%s,"username":"%s"%s}},"userData":{"sandboxName":"%s"}}\n' \
    "$_rhome" "$_name" "$_host" "$_port" "$_user" "$_extra" "$_name"
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `sh tests/test-common.sh`
Expected: `OK`

- [ ] **Step 6: Add CI**

`.github/workflows/ci.yml`:
```yaml
name: ci
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: shellcheck sources
        run: |
          shellcheck -s sh scripts/lifecycle/*.sh tests/harness.sh tests/stubs/* tests/run.sh tests/test-*.sh
      - name: tests
        run: sh tests/run.sh
```

- [ ] **Step 7: Shellcheck + full run + commit**

Run: `shellcheck -s sh scripts/lifecycle/common.sh tests/stubs/* && sh tests/run.sh`
Expected: no shellcheck errors, `OK`.
```bash
git add scripts tests .github
git commit -m "feat: shared lifecycle preamble with stub-driven test harness"
```

### Task 5: `create.sh`

**Files:**
- Create: `scripts/lifecycle/create.sh`
- Test: `tests/test-create.sh`

**Interfaces:**
- Consumes: every `common.sh` function (Task 4 signatures).
- Produces: the `create` lifecycle command — on success prints exactly one connection JSON object (shape from `emit_connection_json`); all logs on stderr. Task 8 inlines `common.sh + create.sh` verbatim as the recipe's `create` string.

- [ ] **Step 1: Write the failing test**

`tests/test-create.sh`:
```sh
#!/bin/sh
. "$(dirname "$0")/harness.sh"
export ORCA_PROJECT_ID="proj-123" ORCA_REPO_PATH="/tmp/whatever"
NAME="orca-p-$(printf '%s' "proj-123" | { command -v shasum >/dev/null 2>&1 && shasum -a 256 || sha256sum; } | cut -c1-12)"

# fresh project: creates sandbox, sets up ssh, clones, emits JSON
export STUB_LS_JSON='[]' STUB_HAS_CLONE=1
out="$(run_lifecycle create 2>"$TESTTMP/err")"
log="$(cat "$SBX_LOG")"
assert_contains "$log" "create --name $NAME" "sbx create called"
assert_contains "$log" "setup ssh" "ssh setup called"
assert_contains "$log" "git clone https://example.com/repo.git /home/agent/project" "clone called"
printf '%s' "$out" | jq -e ".userData.sandboxName == \"$NAME\"" >/dev/null || { echo "FAIL create JSON: $out"; FAILURES=$((FAILURES+1)); }
[ -d "$HOME/.orca-sbx/$NAME/workspace" ] || { echo "FAIL workspace dir missing"; FAILURES=$((FAILURES+1)); }

# stdout purity: the only stdout line is the JSON object
assert_eq "$(printf '%s' "$out" | wc -l | tr -d ' ')" "0" "single-line stdout"

# reuse: sandbox exists + clone exists → no create, no clone, still emits JSON
: > "$SBX_LOG"
export STUB_LS_JSON="[{\"name\":\"$NAME\",\"status\":\"running\"}]" STUB_HAS_CLONE=0
out2="$(run_lifecycle create 2>/dev/null)"
log2="$(cat "$SBX_LOG")"
case "$log2" in *"create --name"*) echo "FAIL reused path called create"; FAILURES=$((FAILURES+1));; esac
case "$log2" in *"git clone"*) echo "FAIL reused path called clone"; FAILURES=$((FAILURES+1));; esac
printf '%s' "$out2" | jq -e '.connection.type == "ssh"' >/dev/null || { echo "FAIL reuse JSON: $out2"; FAILURES=$((FAILURES+1)); }

finish
```

- [ ] **Step 2: Run test to verify it fails**

Run: `sh tests/test-create.sh`
Expected: FAIL (`scripts/lifecycle/create.sh` missing).

- [ ] **Step 3: Implement `scripts/lifecycle/create.sh`**

```sh
# create: reuse-or-create the project sandbox, ensure the clone, emit connection JSON.
require_env
require_sbx
NAME="$(sandbox_name)"
WORKROOT="$HOME/.orca-sbx/$NAME"
mkdir -p "$WORKROOT/workspace"

if ! sandbox_exists "$NAME"; then
  printf 'orca-sbx: creating sandbox %s\n' "$NAME" >&2
  # claude agent selects docker/sandbox-templates:claude-code (ships claude + node;
  # node is required by Orca's SSH relay). Exact syntax confirmed by the Task 1 spike.
  sbx create --name "$NAME" claude "$WORKROOT/workspace" 1>&2
fi
sbx setup ssh 1>&2

RHOME="$(sbx exec "$NAME" -- sh -c 'printf %s "$HOME"')"
[ -n "$RHOME" ] || fail "could not resolve \$HOME inside sandbox $NAME"
if ! sbx exec "$NAME" -- test -d "$RHOME/project/.git"; then
  URL="$(git -C "$ORCA_REPO_PATH" remote get-url origin)" \
    || fail "the source repo has no 'origin' remote; set one, or clone into the sandbox manually with 'sbx exec'"
  printf 'orca-sbx: cloning %s into %s\n' "$URL" "$NAME" >&2
  sbx exec "$NAME" -- git clone "$URL" "$RHOME/project" 1>&2 \
    || fail "clone failed inside sandbox — check 'sbx secret set github' or SSH agent forwarding"
fi

emit_connection_json "$NAME"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `shellcheck -s sh scripts/lifecycle/create.sh && sh tests/test-create.sh && sh tests/run.sh`
Expected: `OK` for all. (Shellcheck warnings about functions defined elsewhere are expected in isolation; the CI check in Task 8 lints the concatenated form. If shellcheck errors on undefined functions, add `# shellcheck disable=SC2154` where needed — but only for symbols `common.sh` defines.)

- [ ] **Step 5: Commit**

```bash
git add scripts/lifecycle/create.sh tests/test-create.sh
git commit -m "feat: create lifecycle command (reuse-or-create, clone, connection JSON)"
```

### Task 6: `suspend.sh` + `resume.sh`

**Files:**
- Create: `scripts/lifecycle/suspend.sh`, `scripts/lifecycle/resume.sh`
- Test: `tests/test-suspend-resume.sh`

**Interfaces:**
- Consumes: `common.sh` functions; stdin lifecycle payload (JSON with `recipeResult.userData.sandboxName`).
- Produces: `suspend` (drains stdin, exits 0, JSON-free stdout), `resume` (starts the sandbox if stopped, re-emits connection JSON).

- [ ] **Step 1: Write the failing test**

`tests/test-suspend-resume.sh`:
```sh
#!/bin/sh
. "$(dirname "$0")/harness.sh"
export ORCA_PROJECT_ID="proj-123"
PAYLOAD='{"schemaVersion":1,"mode":"resume","recipeResult":{"userData":{"sandboxName":"orca-p-abc123def456"}}}'

# suspend: no-op, exit 0, empty stdout
out="$(printf '%s' "$PAYLOAD" | run_lifecycle suspend 2>/dev/null)"; rc=$?
assert_eq "$rc" "0" "suspend exit code"
assert_eq "$out" "" "suspend stdout empty"

# resume: starts named sandbox from payload and re-emits JSON
export STUB_LS_JSON='[{"name":"orca-p-abc123def456","status":"stopped"}]'
out="$(printf '%s' "$PAYLOAD" | run_lifecycle resume 2>/dev/null)"
assert_contains "$(cat "$SBX_LOG")" "start orca-p-abc123def456" "sbx start called"
printf '%s' "$out" | jq -e '.userData.sandboxName == "orca-p-abc123def456"' >/dev/null \
  || { echo "FAIL resume JSON: $out"; FAILURES=$((FAILURES+1)); }

# resume: sandbox gone → non-zero with actionable stderr
: > "$SBX_LOG"; export STUB_LS_JSON='[]'
if printf '%s' "$PAYLOAD" | run_lifecycle resume >/dev/null 2>"$TESTTMP/err"; then
  echo "FAIL resume should fail when sandbox is gone"; FAILURES=$((FAILURES+1))
fi
assert_contains "$(cat "$TESTTMP/err")" "no longer exists" "resume error message"

finish
```

- [ ] **Step 2: Run test to verify it fails**

Run: `sh tests/test-suspend-resume.sh`
Expected: FAIL (scripts missing).

- [ ] **Step 3: Implement**

`scripts/lifecycle/suspend.sh`:
```sh
# suspend: deliberate no-op — the sandbox is shared by every workspace of this
# project, and a sibling may be awake. Orca tears down its own relay regardless.
cat > /dev/null
printf 'orca-sbx: suspend is a no-op for the shared project sandbox\n' >&2
exit 0
```

`scripts/lifecycle/resume.sh`:
```sh
# resume: ensure the shared sandbox is running, then re-emit connection JSON
# (the recipe contract requires a fresh result on every resume).
PAYLOAD_NAME="$(payload_sandbox_name)"
require_env
require_sbx
NAME="$(sandbox_name "$PAYLOAD_NAME")"
sandbox_exists "$NAME" \
  || fail "sandbox $NAME no longer exists (removed manually?); delete this workspace and create a new one"
sbx start "$NAME" 1>&2 || true
sbx exec "$NAME" -- true 1>&2 || fail "sandbox $NAME failed to start"
emit_connection_json "$NAME"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `shellcheck -s sh scripts/lifecycle/suspend.sh scripts/lifecycle/resume.sh && sh tests/run.sh`
Expected: `OK` across all test files.

- [ ] **Step 5: Commit**

```bash
git add scripts/lifecycle/suspend.sh scripts/lifecycle/resume.sh tests/test-suspend-resume.sh
git commit -m "feat: suspend no-op and resume lifecycle commands"
```

### Task 7: `destroy.sh`

**Files:**
- Create: `scripts/lifecycle/destroy.sh`
- Test: `tests/test-destroy.sh`

**Interfaces:**
- Consumes: `common.sh` functions; stdin lifecycle payload.
- Produces: `destroy` — prunes stale worktrees, removes the VM + `~/.orca-sbx/<name>` only when no linked worktrees remain; succeeds (exit 0) when the sandbox is already gone.

- [ ] **Step 1: Write the failing test**

`tests/test-destroy.sh`:
```sh
#!/bin/sh
. "$(dirname "$0")/harness.sh"
export ORCA_PROJECT_ID="proj-123"
PAYLOAD='{"schemaVersion":1,"mode":"destroy","recipeResult":{"userData":{"sandboxName":"orca-p-abc123def456"}}}'
mkdir -p "$HOME/.orca-sbx/orca-p-abc123def456"

# other worktrees remain (main + 2 linked) → VM kept
export STUB_LS_JSON='[{"name":"orca-p-abc123def456"}]' STUB_WORKTREES=3
printf '%s' "$PAYLOAD" | run_lifecycle destroy 2>/dev/null || { echo "FAIL destroy rc"; FAILURES=$((FAILURES+1)); }
case "$(cat "$SBX_LOG")" in *"rm -f"*) echo "FAIL removed VM with worktrees left"; FAILURES=$((FAILURES+1));; esac
[ -d "$HOME/.orca-sbx/orca-p-abc123def456" ] || { echo "FAIL host dir removed early"; FAILURES=$((FAILURES+1)); }

# last workspace (main worktree only) → VM + host dir removed
: > "$SBX_LOG"; export STUB_WORKTREES=1
printf '%s' "$PAYLOAD" | run_lifecycle destroy 2>/dev/null || { echo "FAIL destroy rc 2"; FAILURES=$((FAILURES+1)); }
assert_contains "$(cat "$SBX_LOG")" "rm -f orca-p-abc123def456" "sbx rm called"
[ ! -d "$HOME/.orca-sbx/orca-p-abc123def456" ] || { echo "FAIL host dir kept"; FAILURES=$((FAILURES+1)); }

# sandbox already gone → still exit 0
export STUB_LS_JSON='[]'
printf '%s' "$PAYLOAD" | run_lifecycle destroy 2>/dev/null || { echo "FAIL destroy-gone rc"; FAILURES=$((FAILURES+1)); }

finish
```

- [ ] **Step 2: Run test to verify it fails**

Run: `sh tests/test-destroy.sh`
Expected: FAIL (script missing).

- [ ] **Step 3: Implement `scripts/lifecycle/destroy.sh`**

```sh
# destroy: refcount — remove the shared sandbox only when this was the last
# workspace (no linked worktrees remain). Idempotent when already gone.
PAYLOAD_NAME="$(payload_sandbox_name)"
require_env
NAME="$(sandbox_name "$PAYLOAD_NAME")"
if ! command -v sbx >/dev/null 2>&1; then
  printf 'orca-sbx: sbx CLI missing; nothing to destroy\n' >&2
  exit 0
fi
if ! sandbox_exists "$NAME"; then
  printf 'orca-sbx: sandbox %s already gone\n' "$NAME" >&2
  rm -rf "$HOME/.orca-sbx/$NAME"
  exit 0
fi
RHOME="$(sbx exec "$NAME" -- sh -c 'printf %s "$HOME"')"
sbx exec "$NAME" -- git -C "$RHOME/project" worktree prune 1>&2 || true
LINKED="$(sbx exec "$NAME" -- git -C "$RHOME/project" worktree list --porcelain 2>/dev/null | grep -c '^worktree ' || true)"
if [ "${LINKED:-0}" -le 1 ]; then
  printf 'orca-sbx: removing sandbox %s (last workspace)\n' "$NAME" >&2
  sbx rm -f "$NAME" 1>&2
  rm -rf "$HOME/.orca-sbx/$NAME"
else
  printf 'orca-sbx: keeping sandbox %s (%s other worktree(s) remain)\n' "$NAME" "$((LINKED - 1))" >&2
fi
exit 0
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `shellcheck -s sh scripts/lifecycle/destroy.sh && sh tests/run.sh`
Expected: `OK` across all test files.

- [ ] **Step 5: Commit**

```bash
git add scripts/lifecycle/destroy.sh tests/test-destroy.sh
git commit -m "feat: refcounted destroy lifecycle command"
```

### Task 8: Recipe generation + plugin manifest

**Files:**
- Create: `scripts/build-recipe.sh`, `recipes/sbx-project-sandbox.json` (generated, committed), `orca-plugin.json`
- Test: `tests/test-recipe-artifact.sh`
- Modify: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: the four lifecycle scripts + `common.sh` (verbatim file content).
- Produces: `recipes/sbx-project-sandbox.json` with `{schemaVersion:1, id:"sbx-project-sandbox", name:"Docker Sandbox (project-shared)", description, create, suspend, resume, destroy}` where each command = `common.sh` + the script, and `orca-plugin.json` contributing it via `contributes.vmRecipes`.

- [ ] **Step 1: Write the failing test**

`tests/test-recipe-artifact.sh`:
```sh
#!/bin/sh
. "$(dirname "$0")/harness.sh"
ART=recipes/sbx-project-sandbox.json

jq -e '
  .schemaVersion == 1
  and .id == "sbx-project-sandbox"
  and .name == "Docker Sandbox (project-shared)"
  and (.create | length > 0)
  and (.suspend | length > 0) and (.resume | length > 0)   # suspend/resume must be paired
  and (.destroy | length > 0)' "$ART" >/dev/null \
  || { echo "FAIL artifact shape"; FAILURES=$((FAILURES+1)); }

# each command under Orca's 32KB cap
for f in create suspend resume destroy; do
  n="$(jq -r ".$f | length" "$ART")"
  [ "$n" -lt 32768 ] || { echo "FAIL $f exceeds 32KB ($n)"; FAILURES=$((FAILURES+1)); }
done

# generated commands are exactly preamble + script (regen is deterministic)
for f in create suspend resume destroy; do
  jq -r ".$f" "$ART" > "$TESTTMP/gen-$f"
  cat scripts/lifecycle/common.sh "scripts/lifecycle/$f.sh" > "$TESTTMP/src-$f"
  cmp -s "$TESTTMP/gen-$f" "$TESTTMP/src-$f" || { echo "FAIL $f drifted from source — run scripts/build-recipe.sh"; FAILURES=$((FAILURES+1)); }
done

# plugin manifest points at the artifact
jq -e '.manifestVersion == 1 and .pluginApi == 1
  and .contributes.vmRecipes == [{"path":"recipes/sbx-project-sandbox.json"}]' orca-plugin.json >/dev/null \
  || { echo "FAIL manifest"; FAILURES=$((FAILURES+1)); }

finish
```

- [ ] **Step 2: Run test to verify it fails**

Run: `sh tests/test-recipe-artifact.sh`
Expected: FAIL (artifact and manifest missing).

- [ ] **Step 3: Implement `scripts/build-recipe.sh`**

```bash
#!/usr/bin/env bash
# Dev tool (bash + jq): inlines lifecycle scripts into the plugin recipe artifact.
set -euo pipefail
cd "$(dirname "$0")/.."
body() { cat scripts/lifecycle/common.sh "scripts/lifecycle/$1"; }
mkdir -p recipes
jq -n \
  --arg create "$(body create.sh)" \
  --arg suspend "$(body suspend.sh)" \
  --arg resume "$(body resume.sh)" \
  --arg destroy "$(body destroy.sh)" '
{
  schemaVersion: 1,
  id: "sbx-project-sandbox",
  name: "Docker Sandbox (project-shared)",
  description: "One Docker Sandboxes (sbx) microVM per project; all worktrees share it. Agents run inside the VM; credentials stay host-side via the sbx proxy.",
  create: $create,
  suspend: $suspend,
  resume: $resume,
  destroy: $destroy
}' > recipes/sbx-project-sandbox.json
echo "wrote recipes/sbx-project-sandbox.json" >&2
```

`orca-plugin.json` (mirrors the bundled multipass plugin's shape):
```json
{
  "manifestVersion": 1,
  "id": "orca-sbx-recipes",
  "publisher": "mattjohnson",
  "name": "Docker Sandbox Recipes",
  "version": "0.1.0",
  "description": "Project-shared Docker Sandboxes (sbx) microVM recipes for Orca per-workspace environments.",
  "repository": "https://github.com/mattjohnson/orca-sbx-recipes",
  "engines": { "orca": ">=1.4.0" },
  "pluginApi": 1,
  "contributes": {
    "vmRecipes": [{ "path": "recipes/sbx-project-sandbox.json" }]
  },
  "capabilities": []
}
```

```bash
chmod +x scripts/build-recipe.sh && bash scripts/build-recipe.sh
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `sh tests/test-recipe-artifact.sh && sh tests/run.sh`
Expected: `OK`.

- [ ] **Step 5: Extend CI to lint the generated commands and catch drift**

Append two steps to the `test` job in `.github/workflows/ci.yml`:
```yaml
      - name: shellcheck generated recipe commands
        run: |
          for f in create suspend resume destroy; do
            jq -r ".$f" recipes/sbx-project-sandbox.json | shellcheck -s sh -
          done
      - name: regen drift check
        run: bash scripts/build-recipe.sh && git diff --exit-code recipes/
```

- [ ] **Step 6: Commit**

```bash
git add scripts/build-recipe.sh recipes orca-plugin.json tests/test-recipe-artifact.sh .github/workflows/ci.yml
git commit -m "feat: plugin manifest and generated recipe artifact with drift check"
```

### Task 9: `scripts/bootstrap.sh` (prereq checker / escape hatch)

**Files:**
- Create: `scripts/bootstrap.sh`
- Test: `tests/test-bootstrap.sh`

**Interfaces:**
- Consumes: `sbx` CLI presence/state (stubbed in tests via the Task 4 stub contract plus `STUB_SECRETS` handled below).
- Produces: a non-destructive checker printing ✓/✗ per prerequisite with the exact fix command; exit 0 when all hard prereqs pass, exit 1 otherwise. Referenced by the README as the first-run step.

- [ ] **Step 1: Extend the sbx stub for `secret ls` and `version`**

In `tests/stubs/sbx`, add two cases above the default:
```sh
  "secret ls") printf '%s\n' "${STUB_SECRETS:-}" ;;
  version) printf '%s\n' "${STUB_VERSION:-sbx version 0.38.0}" ;;
```

- [ ] **Step 2: Write the failing test**

`tests/test-bootstrap.sh`:
```sh
#!/bin/sh
. "$(dirname "$0")/harness.sh"

# all prereqs green
export STUB_LS_JSON='[]' STUB_SECRETS='github
anthropic'
out="$(sh scripts/bootstrap.sh 2>&1)"; rc=$?
assert_eq "$rc" "0" "bootstrap rc all-green"
assert_contains "$out" "sbx CLI" "reports CLI check"

# missing secrets → exit 1 and prints the fix commands
export STUB_SECRETS=''
out="$(sh scripts/bootstrap.sh 2>&1)"; rc=$?
assert_eq "$rc" "1" "bootstrap rc missing secrets"
assert_contains "$out" "sbx secret set github" "github fix hint"
assert_contains "$out" "sbx secret set anthropic" "anthropic fix hint"

# sbx older than the tested floor → exit 1 with upgrade hint
export STUB_SECRETS='github
anthropic' STUB_VERSION='sbx version 0.30.1'
out="$(sh scripts/bootstrap.sh 2>&1)"; rc=$?
assert_eq "$rc" "1" "bootstrap rc old sbx"
assert_contains "$out" "0.38" "version floor mentioned"

finish
```

- [ ] **Step 3: Run test to verify it fails**

Run: `sh tests/test-bootstrap.sh`
Expected: FAIL (script missing).

- [ ] **Step 4: Implement `scripts/bootstrap.sh`**

```sh
#!/bin/sh
# Non-destructive prerequisite checker for orca-sbx-recipes.
set -u
PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:$HOME/.docker/bin"
BAD=0
ok()  { printf '  \342\234\223 %s\n' "$1"; }
bad() { BAD=1; printf '  \342\234\227 %s\n      fix: %s\n' "$1" "$2"; }

echo "orca-sbx-recipes prerequisites:"

if command -v sbx >/dev/null 2>&1; then
  ok "sbx CLI installed"
else
  bad "sbx CLI installed" "brew trust docker/tap && brew install docker/tap/sbx  (see https://docs.docker.com/ai/sandboxes/install/)"
fi

if command -v sbx >/dev/null 2>&1 && sbx ls --json >/dev/null 2>&1; then
  ok "sbx logged in"
else
  bad "sbx logged in" "sbx login   # then: sbx policy init balanced"
fi

# Version floor: the release this pack was validated against (see
# docs/spike/2026-08-17-findings.md; reconcile if the spike recorded newer).
MIN_MAJOR=0 MIN_MINOR=38
VER="$(sbx version 2>/dev/null | sed -n 's/.*\([0-9][0-9]*\)\.\([0-9][0-9]*\)\.[0-9][0-9]*.*/\1.\2/p' | head -n1)"
MAJOR="${VER%%.*}"; MINOR="${VER#*.}"
if [ -n "$VER" ] && { [ "$MAJOR" -gt "$MIN_MAJOR" ] || { [ "$MAJOR" -eq "$MIN_MAJOR" ] && [ "$MINOR" -ge "$MIN_MINOR" ]; }; }; then
  ok "sbx version >= $MIN_MAJOR.$MIN_MINOR (found $VER)"
else
  bad "sbx version >= $MIN_MAJOR.$MIN_MINOR" "brew upgrade sbx   # this pack is validated against sbx >= $MIN_MAJOR.$MIN_MINOR"
fi

SECRETS="$(sbx secret ls 2>/dev/null || true)"
case "$SECRETS" in
  *github*) ok "github secret configured" ;;
  *) bad "github secret configured" "gh auth token | sbx secret set github" ;;
esac
case "$SECRETS" in
  *anthropic*) ok "anthropic secret configured" ;;
  *) bad "anthropic secret configured" "sbx secret set anthropic   # or run /login inside the sandboxed claude once" ;;
esac

if [ "$BAD" -eq 0 ]; then
  echo "All prerequisites satisfied."
else
  echo "Fix the items above, then re-run: sh scripts/bootstrap.sh"
fi
exit "$BAD"
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `shellcheck -s sh scripts/bootstrap.sh && sh tests/run.sh`
Expected: `OK`.

- [ ] **Step 6: Commit**

```bash
git add scripts/bootstrap.sh tests/test-bootstrap.sh tests/stubs/sbx
git commit -m "feat: bootstrap prerequisite checker"
```

### Task 10: README

**Files:**
- Create: `README.md`

- [ ] **Step 1: Write README.md with these sections and content**

- **Title + one-liner:** "Docker Sandbox recipes for Orca — one sbx microVM per project; every worktree and agent runs inside it, your host stays safe."
- **How it works:** 4–6 sentences from the spec's Architecture section (project-shared VM, SSH connection via `sbx setup ssh`, clone on VM-private disk, agents in Orca terminals inside the VM, secrets host-side via the sbx proxy). Include the spec's architecture ASCII diagram.
- **Prerequisites:** macOS 14+ Apple silicon or Ubuntu 24.04+/KVM; Docker account; `sbx` installed + `sbx login`; `sbx policy init balanced`; `gh auth token | sbx secret set github`; `sbx secret set anthropic` (or one in-sandbox `/login`). Point at `sh scripts/bootstrap.sh` to verify.
- **Install:** Orca → Settings → Experimental → enable *Per-Workspace Environments* (`experimentalEphemeralVms`); Orca → Settings → Plugins → install from git URL `https://github.com/mattjohnson/orca-sbx-recipes` (or local path); approve the consent dialog (it previews the exact lifecycle commands).
- **Use:** in the new-workspace composer, pick run target → *Per-Workspace Environment* → *Docker Sandbox (project-shared)*. First workspace boots the VM and clones; subsequent workspaces reuse it.
- **Security model (verbatim honesty, per the spec):** the hypervisor boundary protects the host; agents inside share the project VM — sibling worktrees are inside one blast radius; secrets are proxy-injected and never stored in the VM; network egress is deny-by-default under the `balanced` policy.
- **Lifecycle & cleanup:** suspend is a no-op by design; the VM is removed when the last workspace is deleted; manual escape hatch `sbx rm <name>` (names are `orca-p-<12 hex>`; find them with `sbx ls`); disk defaults to 20GB/VM (`DOCKER_SANDBOXES_ROOT_SIZE` for monorepos).
- **Troubleshooting:** "sbx CLI not found" (PATH — recipes add `/opt/homebrew/bin` themselves; re-run bootstrap), "not ready — run 'sbx login'", clone auth failures (`sbx secret set github` / SSH agent), relay never becomes ready (check `node --version` inside via `sbx exec`), Windows unsupported in v1, Intel Macs unsupported by sbx.
- **Limitations:** v1 is macOS/Linux; sbx is 0.x — pin/see the minimum version recorded in `docs/spike/2026-08-17-findings.md`.

- [ ] **Step 2: Verify claims against the repo**

Every command mentioned in the README must exist in this repo or in the findings file (no invented flags). Cross-check `bootstrap.sh` command text matches.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: user-facing README (install, security model, troubleshooting)"
```

---

## Phase 2 — Live validation (interactive)

### Task 11: End-to-end in Orca

**Files:**
- Modify: `docs/spike/2026-08-17-findings.md` (append `## Task 11: live validation`)
- Modify: lifecycle scripts + regen, if live runs surface fixes

- [ ] **Step 1: Install the plugin from the local path** — Orca → Settings → Plugins → install from local path `/Users/matt/github/mattjohnson/orca-sbx-recipes`; approve the consent dialog; confirm the recipe appears in the composer's Per-Workspace Environment submenu (experimental flag on).
- [ ] **Step 2: First workspace** — create a workspace with the recipe on a real project. Verify: VM created (`sbx ls`), clone present, relay ready, worktree created inside, claude launches with status working. Record timings (create-to-ready).
- [ ] **Step 3: Second workspace reuse** — create another workspace on the same project. Verify: no second VM, no re-clone, fast create.
- [ ] **Step 4: Sleep/wake** — sleep one workspace (sibling awake): VM keeps running. Wake it: reconnects. Stop the VM manually (`sbx stop`), wake a workspace: `resume` starts it and reconnects.
- [ ] **Step 5: Destroy refcount** — delete one workspace: VM survives (record whether Orca removed the worktree before `destroy` ran — if the count included the dying workspace's worktree, adjust `destroy.sh`'s threshold or prune logic accordingly, regen, retest). Delete the last workspace: VM and `~/.orca-sbx/<name>` removed.
- [ ] **Step 6: Record findings, fix, regen, commit**

```bash
bash scripts/build-recipe.sh && sh tests/run.sh
git add -A && git commit -m "fix: adjustments from live end-to-end validation"
```

---

## Phase 3 — Publish (each step gated on Matt's explicit go)

### Task 12: GitHub repo, issue comments, marketplace prep

- [ ] **Step 1: Create + push the GitHub repo (confirm with Matt first)**

```bash
gh repo create mattjohnson/orca-sbx-recipes --public --source /Users/matt/github/mattjohnson/orca-sbx-recipes --push
```

- [ ] **Step 2: Verify CI is green on GitHub** — `gh run watch` until the `ci` workflow passes.
- [ ] **Step 3: Draft (do not post) comments for stablyai/orca#13665 and #12756** — save to `docs/drafts/issue-comments.md`: what the pack does, the project-shared design and why (worktree `.git` resolution), install steps, limitations, link to the repo. Matt reviews and posts himself.
- [ ] **Step 4: Draft the marketplace-listing change** — a short `docs/drafts/marketplace-pr.md` describing the edit to Orca's bundled `orca-marketplace.json` (add this repo's git source) plus the PR body, ready for Matt to open against stablyai/orca when he's ready.
- [ ] **Step 5: Commit drafts**

```bash
git add docs/drafts && git commit -m "docs: draft upstream issue comments and marketplace listing PR" && git push
```
