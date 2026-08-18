# orca-sbx-recipes

**Docker Sandbox recipes for Orca — one sbx microVM per project; every worktree and agent runs inside it, your host stays safe.**

## How it works

Each Orca project gets exactly one [Docker Sandboxes](https://docs.docker.com/ai/sandboxes/) (`sbx`) microVM, shared by every worktree and workspace opened against that project — not one VM per workspace. Orca's `create` recipe command reuses or provisions the VM with `sbx create`, then runs `sbx setup ssh` so Orca can reach it as a normal SSH host at `<name>.sbx`. The project repo is cloned once onto the VM's own disk, not a virtiofs mount, so worktrees Orca creates on top of it get native git performance instead of a mounted filesystem. Agents (Claude Code and friends) run in ordinary Orca terminals inside the VM, so hooks, busy/idle status, and AI Vault all work exactly as they do on any SSH host. Credentials never enter the VM: `sbx`'s host-side proxy injects secrets into outbound requests at the point of use, so nothing an agent does inside the sandbox exposes your tokens.

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

## Prerequisites

- macOS 14+ on Apple silicon, or Ubuntu 24.04+ (or Rocky 8) with KVM. sbx doesn't support Intel Macs or Windows — see Limitations.
- A free Docker account (`sbx login` requires one).
- [Docker Sandboxes (`sbx`)](https://docs.docker.com/ai/sandboxes/install/) installed and logged in: `sbx login`, then `sbx policy init balanced` (deny-by-default network egress with an AI/package-registry allowlist).
- GitHub access inside the sandbox: `gh auth token | sbx secret set github`.
- Claude auth inside the sandbox: `sbx secret set anthropic`, or run `/login` once inside a sandboxed Claude session instead (the token stays host-side either way).
- Orca >= 1.4.0.

Run `sh scripts/bootstrap.sh` to check all of the above non-destructively — it prints exactly what's missing and the command to fix it.

## Install

1. Orca → Settings → Experimental → enable **Per-Workspace Environments** (`experimentalEphemeralVms`).
2. Orca → Settings → Plugins → install from git URL: `https://github.com/mattjohnson/orca-sbx-recipes` (a local path works too, for development).
3. Approve the consent dialog — it previews the exact lifecycle shell commands the plugin will run before you accept them.

## Use

In the new-workspace composer, pick a run target → **Per-Workspace Environment** → **Docker Sandbox (project-shared)**.

The first workspace you open this way boots the VM (a couple of minutes, cold) and clones the project into it. Every subsequent workspace against the same project reuses that VM and just adds a linked worktree inside it.

## Security model

- The hypervisor boundary protects your **host** — a misbehaving agent can't reach outside the microVM.
- It does **not** isolate agents from each other: every worktree of a project shares one VM, so sibling worktrees share one blast radius. Isolating agents from each other within a project is explicitly out of scope.
- Secrets are proxy-injected by `sbx` on egress and are never stored inside the VM.
- Network egress is deny-by-default under the `balanced` policy, with an allowlist for AI APIs and package registries.

## Lifecycle & cleanup

- **suspend** is a deliberate no-op — the VM may still be serving other awake workspaces from the same project, so Orca just tears down its own SSH connection.
- **destroy** is refcounted: the VM is only removed once the last workspace using it is deleted (checked by counting linked git worktrees left inside it).
- Manual escape hatch: `sbx rm <name>`. Sandbox names are `orca-p-<12 hex chars>` (a hash of the Orca project ID); list them with `sbx ls`.
- Each VM's disk defaults to 20GB; set `DOCKER_SANDBOXES_ROOT_SIZE` before creation if your monorepo needs more.

## Troubleshooting

**"sbx CLI not found"** — recipes add `/opt/homebrew/bin`, `/usr/local/bin`, and `$HOME/.docker/bin` to `PATH` themselves, so this usually means `sbx` isn't installed at all. Re-run `sh scripts/bootstrap.sh`.

**"sbx is installed but not ready"** — run `sbx login`, then `sbx policy init balanced`.

**Clone fails inside the sandbox** — check `sbx secret set github` (for private HTTPS clones) or that your SSH agent is forwarded.

**Relay never becomes ready** — Orca's SSH relay needs a working Node inside the VM; check with `sbx exec <name> -- node --version`. `create` also installs `build-essential` on first connect (needed to build node-pty); if that step failed, your `sbx` network policy may be blocking apt access.

**Connect fails with "relay upload failed (exit 255)"** — known caveat, still being validated in live testing: Orca's SSH connection-reuse (multiplexing) is incompatible with the sbx SSH proxy. On the SSH target, turn off **"Reuse SSH connection for faster setup"**.

**Windows** — unsupported in v1; the recipe's lifecycle commands target macOS/Linux shells only.

**Intel Macs** — unsupported; sbx itself requires Apple silicon on macOS.

## Limitations

- v1 supports macOS and Linux hosts only.
- `sbx` is pre-1.0 and this pack is validated against v0.38.0 (see `docs/spike/2026-08-17-findings.md`); CLI behavior can change between releases. `scripts/bootstrap.sh` checks the version floor and tells you how to fix it.
- Every worktree in a project shares one VM — see Security model above.
