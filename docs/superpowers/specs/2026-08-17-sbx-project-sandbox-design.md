# orca-sbx-recipes: Project-Shared Docker Sandbox for Orca

> **Superseded:** historical design document — the connection layer shipped differently (direct TCP via in-VM sshd, not the sbx SSH proxy described below); `docs/spike/2026-08-17-findings.md` is authoritative for what actually shipped.

- **Date:** 2026-08-17
- **Status:** Approved design, pre-implementation
- **Answers:** [stablyai/orca#13665](https://github.com/stablyai/orca/issues/13665) (Docker Sandboxes support), aligned with [stablyai/orca#12756](https://github.com/stablyai/orca/issues/12756) (Docker support "via extension")

## Problem

Orca launches TUI coding agents in yolo mode (`claude --dangerously-skip-permissions` and per-agent equivalents) directly on the host. Issue #13665 asks for an option to run agents inside Docker Sandboxes (`sbx run claude`) so a misbehaving agent cannot damage the host, with host credentials still reaching the agent.

The threat model is **host protection from yolo agents**. Isolation between agents of the same project is explicitly not a goal.

## Constraints established by research (verified 2026-08-17)

**Docker Sandboxes (`sbx`, v0.38.0 stable):**

- Standalone CLI; no Docker Desktop/Engine needed; mandatory free Docker account (`sbx login`).
- Per-sandbox KVM/HVF microVM with its own kernel, Docker Engine, and network. Platforms: macOS 14+ Apple silicon only, Windows 11 + WHP, Ubuntu 24.04+/Rocky 8 with KVM.
- Direct mode bind-mounts the workspace via virtiofs at the same absolute path; Docker documents virtiofs cache git-index corruption and slow git ops on large mounted repos.
- **Git worktrees are broken in direct mode** (the `.git` pointer file cannot resolve when only the worktree is mounted) and `--clone` mode is rejected from linked worktrees.
- Credentials: host-side proxy injects secrets (`sbx secret set anthropic|github|…`) into outbound requests; secrets never enter the VM. Claude `/login` OAuth is held host-side. SSH agent forwarding supported.
- Agent state (`~/.claude`) lives inside the VM; host user-level agent config is not forwarded.
- `sbx setup ssh` writes a managed `~/.ssh/config` block so SSH-capable tools connect to `<name>.sbx` (VS Code Remote-SSH is documented).
- Machine-driving surfaces: `sbx ls --json`, `sbx create`, `sbx exec [-it|-d] [-e]`, `sbx cp`, `sbx policy init <preset>`. No complete JSON/exit-code contract yet (open issue docker/sbx#422). ~3s CLI latency floor per invocation.

**Orca:**

- The ephemeral-VM ("Per-Workspace Environment") recipe system runs recipe lifecycle commands locally (cwd = source repo, `shell: true`, `ORCA_*` env). `create` must print one JSON object: an SSH target or orca-server pairing + absolute runtime `projectRoot`. Orca then registers a hidden runtime-owned SSH target, uploads its relay over SFTP, and executes it with a **Node runtime it must find on the remote**.
- In `orca-worktree` checkout mode Orca imports `projectRoot` as a repo on the runtime host and creates linked worktrees there through the remote git provider. The repo URL is *not* passed to the recipe in this mode (`ORCA_REPO_PATH`, the local repo, is).
- Orca has full feature parity on SSH hosts: terminals, git, editor file access, agent hooks/status, sleeping sessions/resume, AI Vault scanning.
- Plugins contribute `vmRecipes` (also `panels`, `commands`, `languagePacks` — not skills). Plugin recipe commands are bare strings executed from the repo root, 32KB cap, trust-gated by a consent dialog previewing the exact commands.
- The whole system is gated behind the default-off `experimentalEphemeralVms` setting and runs for local, non-folder git repos.
- Team signals: maintainers stated Docker support lands "via extension" (#12756); community core-Docker PRs sit unmerged; features in this family ship experimental-gated and plugin-distributed.

## Decisions

1. **Extension, not core** (path B): a recipe pack on the existing ephemeral-VM system. A "Sandboxed" permission mode using agent-native sandboxes (path C) is a separate, later effort.
2. **Distribution:** standalone repo `mattjohnson/orca-sbx-recipes` (this repo), installable via git URL in Orca's Plugins dialog; marketplace-listing PR and comments on #13665/#12756 after it works.
3. **Engine:** Docker Sandboxes (`sbx`) only.
4. **Architecture:** one sandbox **per project**, not per workspace. All of a project's worktrees live inside the same VM, so linked-worktree `.git` pointers resolve normally and `orca-worktree` checkout mode works as designed.
5. **Integration:** recipe-integrated with idempotent reuse-or-create semantics; Orca auto-registers the SSH connection per workspace. A manual bootstrap script ships as the escape hatch.

## Architecture

```
Host (macOS/Linux)                          sbx microVM  orca-p-<hash>
┌─────────────────────────────┐             ┌──────────────────────────────┐
│ Orca desktop                │   SSH via   │ sshd ⟵ sbx setup ssh         │
│  recipe create/resume/…  ───┼──sbx CLI──▶ │ node (runs Orca SSH relay)   │
│  SSH relay (SFTP + node) ───┼─<name>.sbx─▶│ ~/project        (main clone)│
│  N workspaces, N hidden     │             │ + linked worktrees (created  │
│  runtime-owned SSH targets  │             │   by Orca's remote git flow) │
│                             │             │ agent CLIs (claude, …)       │
├─────────────────────────────┤             ├──────────────────────────────┤
│ sbx credential proxy        │◀───egress───│ agents; secrets never in VM  │
│ (secrets, network policy)   │             │                              │
└─────────────────────────────┘             └──────────────────────────────┘
```

- The clone lives on the **VM's private disk, not a virtiofs mount** — native git performance, and Docker's virtiofs corruption caveat never applies. The sandbox's required host workspace dir is a dedicated empty directory (`~/.orca-sbx/<name>/workspace`).
- Each Orca workspace gets its own runtime record and hidden SSH target pointing at the shared VM. Sleeping one workspace disconnects only its own relay.
- Agents run in Orca terminals inside the VM, so hooks, busy/idle status, native chat, sleeping sessions, resume, and AI Vault all work through Orca's existing SSH support. `sbx run` is not used; the sandbox is created from the claude-code template and Orca drives everything over SSH.

## Repo layout

```
orca-plugin.json                     # manifestVersion 1, contributes.vmRecipes
recipes/sbx-project-sandbox.json     # the recipe artifact (schemaVersion 1)
scripts/bootstrap.sh                 # prereq installer/checker (manual escape hatch)
docs/superpowers/specs/              # this spec
README.md                            # prereqs, install, security model, troubleshooting
.github/workflows/ci.yml             # shellcheck + `orca vm recipe doctor` against the artifact
```

## Recipe contract

`recipes/sbx-project-sandbox.json`: `{schemaVersion: 1, id: "sbx-project-sandbox", name: "Docker Sandbox (project-shared)", create, suspend, resume, destroy}`. `checkoutMode` omitted (defaults to `orca-worktree`). Commands are inline POSIX shell (v1 targets macOS/Linux; Windows recipe strings run under cmd.exe and are deferred — see Risks).

Shared preamble in each command: derive `NAME="orca-p-$(printf %s "$ORCA_PROJECT_ID" | shasum -a 256 | cut -c1-12)"`; fail fast with a clear stderr message if `sbx` is missing or not logged in.

- **create** (idempotent):
  1. If `sbx ls --json` lacks `$NAME`: `mkdir -p ~/.orca-sbx/$NAME/workspace`; `sbx create --name $NAME -t docker/sandbox-templates:claude-code` on that directory (this template ships claude + node, satisfying the relay's Node requirement); `sbx setup ssh`.
  2. If the VM lacks `~/project/.git`: `URL=$(git -C "$ORCA_REPO_PATH" remote get-url origin)`; `sbx exec $NAME -- git clone "$URL" ~/project` (credentials via the sbx proxy or forwarded SSH agent).
  3. Ensure node + agent CLIs exist in the VM (claude + node come from the template; other agent CLIs installed via `sbx exec` on demand).
  4. Print `{"schemaVersion":1,"connection":{"type":"ssh","projectRoot":"/home/<user>/project","target":{"label":"Docker Sandbox","configHost":"<NAME>.sbx",…}},"userData":{"sandboxName":"<NAME>"}}`.
     Whether `configHost` suffices or explicit `proxyCommand`/host/port must be extracted from the managed SSH config block is a spike question; the schema supports both.
- **suspend**: no-op (`exit 0`). Sibling workspaces may be awake; Orca tears down its own relay connection regardless.
- **resume**: `sbx start $NAME` if stopped (start is idempotent), then re-print the same connection JSON (the contract requires a fresh emit).
- **destroy**: remove this workspace's worktree inside the VM if Orca's teardown left it, then refcount: if `sbx exec $NAME -- git -C ~/project worktree list --porcelain` shows no linked worktrees, `sbx rm -f $NAME` and delete `~/.orca-sbx/$NAME`. Manual escape hatch: `sbx rm <name>`; Orca's cleanup-command flow covers stuck runtimes.

All lifecycle scripts read `userData.sandboxName` from the stdin payload when present rather than re-deriving, so renames of the derivation scheme never orphan existing runtimes (Orca snapshots lifecycle commands per runtime, so old runtimes keep old commands regardless).

## Credentials & network

Bootstrap (README + `scripts/bootstrap.sh`) walks through: install `sbx`, `sbx login`, `sbx policy init balanced` (deny-by-default egress with the AI/package-registry allowlist), `sbx secret set github` (`gh auth token` piped in) and `sbx secret set anthropic` — or one in-sandbox `/login` for Claude subscription auth, whose token sbx keeps host-side. This is the answer to the issue's "forward host credentials" concern: secrets are proxy-injected on egress and never stored in the VM.

## Milestone 0: validation spike (before any recipe code)

Run on the target machine, manually, using Orca's *plain SSH host* flow as the vehicle:

1. `sbx create` + `sbx setup ssh`; verify plain `ssh <name>.sbx` works, and identify what the managed config block contains (ProxyCommand? port?).
2. Add `<name>.sbx` as an SSH host in Orca; verify the relay comes up: node discovered in the VM, SFTP bundle upload succeeds, git + filesystem providers ready within the 10s window.
3. Import a clone inside as a repo; create a worktree through Orca; launch claude in a terminal; verify hooks/status/native-chat/AI Vault behave as on any SSH host.
4. Determine the recipe SSH-target shape (`configHost` vs explicit fields) that Orca's relay accepts.
5. Create a second workspace against the same VM; verify importing the same `projectRoot` twice is idempotent.
6. Sanity-check steady-state latency and the effect of the ~3s sbx CLI floor (recipe runs only; SSH traffic doesn't pass through the CLI).

Any failure reshapes the recipe contract section before implementation. If (2) fails on the stock template, the create command grows a node-install step; if it fails structurally (relay incompatible with sbx SSH), the design falls back to plain-docker-sshd engine — a decision to bring back to review, not to make silently.

## Risks

- **sbx is 0.x**: CLI churn can break bare-string recipe commands. Mitigation: bootstrap pins a minimum sbx version; CI exercises `sbx --version` gating; runtime records snapshot commands.
- **Platform gaps**: Intel Macs unsupported by sbx; Windows recipe deferred (cmd.exe command strings; sbx-on-Windows also has open mounted-workspace bugs). Documented limitation, revisit for the marketplace PR.
- **Mandatory Docker login**: documented prerequisite; nothing we can mitigate.
- **Disk**: 20GB default per sandbox root; one VM per project bounds it, `DOCKER_SANDBOXES_ROOT_SIZE` documented for monorepos.
- **Blast radius within a project**: agents in sibling worktrees share the VM — accepted per the threat model, stated plainly in the README.

## Out of scope (recorded for later)

- **Path C**: a "Sandboxed" third permission mode in Orca core mapping to agent-native sandboxes (codex `--sandbox workspace-write`, Claude Code `/sandbox`, `GEMINI_SANDBOX`) — separate brainstorm.
- **Shape 2**: direct-mounting the project tree and wrapping agent launches with `sbx exec` while workspaces stay local — requires core hook-relay and wrapper-recognition work in stablyai/orca.
- **Core "project-scoped environments" proposal**: first-class shared runtimes so suspend/destroy refcounting moves out of recipe shell into Orca.
- Windows recipe variant; orca-server connection mode as an alternative to SSH.
