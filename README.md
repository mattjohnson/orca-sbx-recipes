# orca-sbx-recipes

[![CI](https://github.com/mattjohnson/orca-sbx-recipes/actions/workflows/ci.yml/badge.svg)](https://github.com/mattjohnson/orca-sbx-recipes/actions/workflows/ci.yml)

**Status (v0.1 beta):** validated end-to-end so far — first workspace create → connect → terminals → Claude Code running, live in Orca. **Not yet live-verified:** second-workspace reuse, sleep/wake, and refcounted destroy — those are exercised only by the unit tests under `tests/`, not against a real sandbox. Expect rough edges and report them.

**Docker Sandbox recipes for Orca — one sbx microVM per project; every worktree and agent runs inside it, your host stays safe.**

## How it works

Each Orca project gets exactly one [Docker Sandboxes](https://docs.docker.com/ai/sandboxes/) (`sbx`) microVM, shared by every worktree and workspace opened against that project — not one VM per workspace. Orca's `create` recipe command reuses or provisions the VM with `sbx create`, then — since the VM ships with neither `sshd` nor systemd — installs `openssh-server` and starts `sshd -p 2222` directly; every lifecycle command re-ensures it's running, since nothing restarts it for you across a VM stop/start. Auth uses a per-project ed25519 keypair generated on the host under `~/.orca-sbx/<name>/` and installed into the VM's `authorized_keys`; the VM's own `sshd` host key is persisted the same way, so recreating the VM doesn't retire a trusted `known_hosts` entry. The recipe publishes that `sshd` port to a deterministic loopback port on the host — a fixed port somewhere in `30000`-`39999`, derived from a hash of the project (e.g. `sbx ports <name> --publish 33792:2222`) — so the same port survives VM restarts, and Orca connects to it over plain TCP with the project key — no SSH proxy anywhere in the path, so Orca's normal SSH connection multiplexing (ControlMaster) just works. Because that direct-TCP traffic is invisible to the `sbx` daemon's own idle-activity tracking, the recipe also holds one lightweight `sbx exec` keepalive session open per project so the sandbox isn't auto-stopped as idle while a workspace is connected. The project repo is cloned once onto the VM's own disk, not a virtiofs mount, so worktrees Orca creates on top of it get native git performance instead of a mounted filesystem. Agents run in ordinary Orca terminals inside the VM, so hooks, busy/idle status, and AI Vault all work exactly as they do on any SSH host — but v0.1 provisions the `claude` sandbox template only, so picking a different agent in Orca's composer gets you a VM without that agent's CLI preinstalled (install it yourself with `sbx exec <name> -- ...`). Secrets managed with `sbx secret` (e.g. `sbx secret set anthropic`) are injected by sbx's host-side credential proxy at the point of outbound use rather than placed in the VM — that's sbx's documented design, and this pack has verified it end-to-end for the anthropic secret path. The alternative in-VM `/login` flow is per Docker's own docs but hasn't been independently verified by this project. Neither protects against credentials a user places inside the VM by hand (e.g. running `gh auth login` in a sandbox terminal) — anything you put there yourself is not proxied and not protected.

```
Host (macOS/Linux)                          sbx microVM  orca-p-<hash>
┌─────────────────────────────┐             ┌──────────────────────────────┐
│ Orca desktop                │             │ sshd :2222 (no systemd)      │
│  recipe create/resume/…  ───┼──sbx CLI──▶ │ installs sshd, keys, port    │
│  SSH relay (SFTP + node) ───┼──127.0.0.1─▶│ node (runs Orca SSH relay)   │
│ per-project ed25519 key     │   :<port>   │ ~/project        (main clone)│
│  N workspaces, N hidden     │             │ + linked worktrees (created  │
│  runtime-owned SSH targets  │             │   by Orca's remote git flow) │
│                             │             │ agent CLI (claude, v0.1)     │
├─────────────────────────────┤             ├──────────────────────────────┤
│ sbx credential proxy        │◀───egress───│ agents; sbx-managed secrets  │
│ (secrets, network policy)   │             │                              │
└─────────────────────────────┘             └──────────────────────────────┘
```

## Prerequisites

- macOS 14+ on Apple silicon, or Ubuntu 24.04+ (or Rocky 8) with KVM. sbx doesn't support Intel Macs; this recipe pack is macOS/Linux-only in v0.1 — see Limitations.
- A free Docker account (`sbx login` requires one).
- [Docker Sandboxes (`sbx`)](https://docs.docker.com/ai/sandboxes/install/) installed and logged in: `sbx login`, then `sbx policy init balanced` (deny-by-default network egress with an AI/package-registry allowlist).
- GitHub access inside the sandbox: `gh auth token | sbx secret set github`.
- Claude auth inside the sandbox: `sbx secret set anthropic`, or run `/login` once inside a sandboxed Claude session instead (the token stays host-side either way).
- A reachable clone URL for the project: a git `origin` remote, or Orca supplying one itself — `create` clones from it into the VM the first time a workspace is opened.
- Orca >= 1.4.0.

Run `sh scripts/bootstrap.sh` to check all of the above non-destructively — it prints exactly what's missing and the command to fix it.

## Install

1. Orca → Settings → Experimental → enable **Cloud VM** (the per-workspace environments feature; flag `experimentalEphemeralVms`).
2. Orca → Settings → Plugins → install from git URL: `https://github.com/mattjohnson/orca-sbx-recipes` (a local path works too, for development).
3. Approve the consent dialog — it previews the exact lifecycle shell commands the plugin will run before you accept them.

## Use

In the new-workspace composer, pick a run target → **Per-Workspace Environment** → **Docker Sandbox (project-shared)**.

The first workspace you open this way boots the VM (a couple of minutes, cold) and clones the project into it. Every subsequent workspace against the same project reuses that VM and just adds a linked worktree inside it.

## Security model

- The hypervisor boundary protects your **host** — a misbehaving agent can't reach outside the microVM.
- It does **not** isolate agents from each other: every worktree of a project shares one VM, so sibling worktrees share one blast radius. Isolating agents from each other within a project is explicitly out of scope.
- Secrets managed via `sbx secret` are proxy-injected by `sbx` on egress rather than stored inside the VM — see How it works above for exactly what's verified versus documented-but-unverified, and for the case this doesn't cover (credentials you place inside the VM yourself).
- Network egress is deny-by-default under the `balanced` policy, with an allowlist for AI APIs and package registries.
- `sbx create` mounts a persistent, cross-sandbox **read-write** agent-skills store into every sandbox by default. This pack doesn't opt out: `--no-share-skills` is documented under `sbx skills --help` but isn't a listed flag in `sbx create --help` on the v0.38.0 this pack targets, so create.sh doesn't rely on it. Practically, a skill an agent writes in one project's sandbox is readable and writable from every other sandbox on the same host — manage the shared store yourself with `sbx skills --help` if that's not what you want.

## Lifecycle & cleanup

- **suspend** is a deliberate no-op — the VM may still be serving other awake workspaces from the same project, so Orca just tears down its own SSH connection.
- **destroy** is refcounted: the VM is only removed once the last workspace using it is deleted (checked by counting linked git worktrees left inside it).
- Manual escape hatch: `sbx rm <name>`. Sandbox names are `orca-p-<12 hex chars>` (a hash of the Orca project ID); list them with `sbx ls`. Doing this yourself orphans this project's `~/.orca-sbx/<name>/` directory and leaks its keepalive process (see below) — clean up both: `kill $(cat ~/.orca-sbx/<name>/keepalive.pid); rm -rf ~/.orca-sbx/<name>`.
- Each VM's disk defaults to 20GB; set `DOCKER_SANDBOXES_ROOT_SIZE` before creation if your monorepo needs more. This has to land in **Orca's own app environment**, not a shell rc file — Orca is a GUI app and doesn't source `.zshrc`/`.bashrc`. On macOS, run `launchctl setenv DOCKER_SANDBOXES_ROOT_SIZE <value>` before launching Orca, or launch Orca itself from a shell where the variable is already exported.
- `~/.orca-sbx/<name>/` on the host holds this project's private state: the per-project ed25519 private key, the VM's persisted `sshd` host key, the keepalive session's pidfile, and the bind-mounted `workspace/` directory `sbx create` uses. It's sensitive (private key material) and not portable to another machine.

## Troubleshooting

**"sbx CLI not found"** — recipes add `/opt/homebrew/bin`, `/usr/local/bin`, and `$HOME/.docker/bin` to `PATH` themselves, so this usually means `sbx` isn't installed at all. Re-run `sh scripts/bootstrap.sh`.

**"sbx is installed but not ready"** — run `sbx login`, then `sbx policy init balanced`.

**Clone fails inside the sandbox** — check `sbx secret set github` (for private HTTPS clones) or that your SSH agent is forwarded.

**Relay never becomes ready** — Orca's SSH relay needs a working Node inside the VM; check with `sbx exec <name> -- node --version`. `create` also installs `build-essential` on first connect (needed to build node-pty); if that step failed, your `sbx` network policy may be blocking apt access.

**Workspace creation fails with a relay upload error mentioning exit 255** — this was a caveat of the earlier sbx-proxy connection design (Orca's SSH connection-reuse/multiplexing was incompatible with the proxy); it's eliminated by the direct-TCP connection this recipe now uses. If you still see it, the sandbox's `sshd` or its published port most likely needs a refresh — put the workspace to sleep and wake it again (that re-runs `resume`, which re-ensures `sshd` and re-emits the connection). If it persists, open an issue on this repo.

**Terminals die with "SSH connection lost"** — the VM may have been stopped outside Orca (the `sbx` daemon auto-stops sandboxes it considers idle). Put the workspace to sleep and wake it again to restart `sshd` and the keepalive session.

**Windows** — unsupported in v0.1; the recipe's lifecycle commands target macOS/Linux shells only.

**Intel Macs** — unsupported; sbx itself requires Apple silicon on macOS.

## Limitations

- v0.1 supports macOS and Linux hosts only.
- v0.1 provisions the `claude` sandbox template only. Picking a different agent CLI in Orca's composer still gets you a VM, but without that agent's CLI preinstalled — install it yourself with `sbx exec <name> -- ...`.
- `sbx` is pre-1.0 and this pack is validated against v0.38.0 (see `docs/spike/2026-08-17-findings.md`); CLI behavior can change between releases. `scripts/bootstrap.sh` checks the version floor and tells you how to fix it.
- Every worktree in a project shares one VM — see Security model above.

## Contributing

Contributions welcome — see [CONTRIBUTING.md](CONTRIBUTING.md) for the dev loop and PR expectations. Bugs and ideas: [open an issue](../../issues) (the templates ask for the diagnostics that matter). Security concerns: see [SECURITY.md](SECURITY.md) — please use private reporting for anything isolation-related.

## License

[MIT](LICENSE) © Matt Johnson
