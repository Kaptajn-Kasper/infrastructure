# Infrastructure

Provisioning and deployment for one Hetzner VM hosting small web apps, each with
`dev`, `preprod` and `prod` environments. See README.md for the full picture and
docs/REDESIGN-PLAN.md for the design rationale.

## Repository structure

- `bootstrap.sh` — complete, idempotent host provisioning; run as root on a fresh/rebuilt Ubuntu 24.04 server
- `cloud-init.yaml` — optional wrapper that runs `bootstrap.sh` on a brand-new server
- `bin/deploy` — the only command the CI runner may run as root (via sudo); validates every argument
- `bin/infra-apply` — syncs this repo onto the host (scripts, sudoers, Caddy, site blocks)
- `bin/install-runner` — registers the org-level GitHub Actions runner (label `deploy`)
- `bin/render-caddy-sites` — generates Caddy site blocks from `apps/*/app.conf`
- `caddy/` — Caddy compose file and Caddyfile (edge proxy on the `edge` network)
- `apps/<app>/app.conf` — `IMAGE`, `HOST`, `DOMAIN`, `PORT`, `ENVS` (plain KEY=value, never sourced)
- `apps/<app>/compose.yml` — hardened service definition, parameterised by `IMAGE` and `ENV`
- `.github/workflows/app-pipeline.yml` — reusable: build → dev → preprod → prod (environment approval)
- `.github/workflows/ci.yml` — shellcheck, cloud-init schema, compose config, caddy validate

## Conventions

- Images are built on GitHub-hosted runners only; the VM never builds source.
- Deploys always use digest-pinned images: `ghcr.io/kaptajn-kasper/<app>@sha256:…`.
- Compose project name is `<app>-<env>`; the web service gets the network alias `<app>-<env>`.
- Hostnames: prod `<HOST>.<DOMAIN>`, others `<HOST>-<env>.<DOMAIN>` (basic auth + noindex).
- App containers: read-only rootfs, `cap_drop: ALL`, `no-new-privileges`, no published ports, no host mounts.
- Secrets live in `/etc/apps/<app>/<env>.env` on the host, never in git.
- Never give the `runner` user anything beyond `sudo /usr/local/bin/deploy`.
- Repos are public: the `vm-deploy` runner group only admits `app-pipeline.yml@main`; never add `pull_request` triggers to jobs that run on the self-hosted runner.
- Scripts are bash with `set -euo pipefail` and must pass shellcheck.
