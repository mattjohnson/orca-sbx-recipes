# Security Policy

This pack configures sandboxes that people rely on for isolating agent work from their host machine. If you find something that weakens that isolation — mishandled SSH keys, `sshd` reachable beyond loopback, command injection via repo-controlled values (branch names, remote URLs, etc.) flowing into the lifecycle scripts, or anything else that lets an agent or a malicious repo escape the intended boundary — please report it privately.

## Reporting

Use GitHub's private vulnerability reporting: go to the **Security** tab on this repo and click **Report a vulnerability**. Please don't open a public issue for security problems.

This is a solo-maintained project, so there's no formal SLA — I'll respond as soon as I practically can, and I'd rather you report something that turns out to be a non-issue than stay quiet about a real one.

## Out of scope

- Vulnerabilities in [Docker Sandboxes (`sbx`)](https://docs.docker.com/ai/sandboxes/) itself — report those to Docker.
- Vulnerabilities in Orca itself — report those to the Orca project.

This repo is just the recipe glue between the two; issues in either underlying tool aren't something a change here can fix.
