# Infrastructure Redesign Plan

Plan for rebuilding the Hetzner VM from scratch with a smaller, more secure setup.
It is meant for a few hobby web apps (starting with `map-guesser-game`), deployed
from GitHub through a self-hosted runner, with `dev`, `preprod` and `prod`
environments for each app.

Status: **decided, Phase 1 in progress.** Decisions are recorded in §10.

---

## 1. Goals and non-goals

**Goals**

1. **Simple.** One file provisions the host and one script deploys. You should be able to read the whole repo in about 15 minutes.
2. **Secure by default.** Only 80/443 are open to the world, and SSH only from your IP. CI never gets SSH access or root.
3. **Disposable.** Everything can be regenerated, so there are no backups. You can delete the VM and rebuild it in under 30 minutes from git plus a few secrets kept in a password manager.
4. **Three environments per app.** Each one is isolated and reachable at its own subdomain, and the same image is promoted from dev to preprod to prod.
5. **Hands-off CI/CD.** A push to `main` deploys to dev and then preprod automatically. Prod takes one click.

**Non-goals**

- Kubernetes, Terraform-managed fleets, multiple servers, or high availability.
- Building images on the VM.
- Backups or a self-hosted monitoring stack.

---

## 2. Review of the current setup

| Area | Today | Problem |
|------|-------|---------|
| Size | ~3,500 lines of bash in 20 scripts, plus MOTD and banners | Too much to maintain for a hobby box. Most of it reimplements cloud-init and Ubuntu defaults. |
| SSH | Custom port only. `PasswordAuthentication` and `PermitRootLogin` are not set. | A custom port hides SSH but does not secure it. Key-only login and no root login are what matter. |
| Operator user | Gets root's GitHub SSH key copied in | One stolen key gives root access plus access to GitHub. |
| `gh-actions` user | In the `docker` group, with `NOPASSWD: /usr/bin/docker, /usr/bin/systemctl` | Both are equivalent to root. This is not least privilege. |
| Deploy model | The server `git clone`s app repos and builds them on the box (`deploy-apps`) | The server needs GitHub credentials, runs the app repo's build code with Docker (root-level) access, and burns CPU/RAM on a small VM. |
| Firewall | UFW only | Docker-published ports bypass UFW. A Hetzner Cloud Firewall cannot be bypassed this way. |
| Environments | `--env` generates a compose override and rewrites `container_name` with sed | Fragile. Compose project names (`-p app-env`) give the same isolation. |
| Config | `environment.prod.ts` copied into the source tree before build | A separate image is built for each environment, so preprod and prod are not the same artifact. |
| App repo leftovers | `setup_server.sh`, `re_deploy.sh`, `Caddyfile.snippet*` | Dead code. `Caddyfile.snippet.dev` points at `:4200`, but the image serves on `:80`, so the dev route is broken. |

What still works and should be kept: Caddy for automatic HTTPS, Docker Compose for
each app, secrets on the server rather than in git, and one shared proxy network.

---

## 3. Target architecture

```
                 GitHub (Kaptajn-Kasper org, private repos)
 ┌────────────────────────────────────────────────────────────────┐
 │ app repo: push to main                                         │
 │   └─ build           (GitHub-hosted)  → ghcr.io/…/<app>@sha256 │
 │   └─ deploy dev      (self-hosted, label "deploy")             │
 │   └─ deploy preprod  (self-hosted, after dev is healthy)       │
 │ app repo: "promote" workflow, manual button                    │
 │   └─ deploy prod = image currently running in preprod          │
 └───────────────────────────────┬────────────────────────────────┘
                                 │ outbound HTTPS only (runner polls GitHub)
 ┌───────────────────────────────▼────────────────────────────────┐
 │ Hetzner VM (Ubuntu 24.04, CX22)                                │
 │  Hetzner Cloud Firewall: 80, 443 from anywhere; 22 from your IP│
 │                                                                │
 │  actions-runner (systemd, user "runner", no docker group)      │
 │     └─ sudo /usr/local/bin/deploy <app> <env> <image|--from>   │
 │                                                                │
 │  /srv/infra                 checkout of this repo (root-owned) │
 │  /etc/apps/<app>/<env>.env  runtime config/secrets (0600 root) │
 │                                                                │
 │  docker network "edge"                                         │
 │    caddy :80/:443 ─┬─► map-guesser-game-dev                    │
 │                    ├─► map-guesser-game-preprod                │
 │                    └─► map-guesser-game-prod                   │
 └────────────────────────────────────────────────────────────────┘
```

### Key design decisions

1. **Build on GitHub, deploy on the VM.** Images are built on GitHub-hosted runners and pushed to GHCR. The VM never builds source code.
2. **The self-hosted runner has no privileges.** Its only privilege is one sudoers line for `/usr/local/bin/deploy`. It has no docker group and no SSH keys.
3. **The registry login is short-lived.** The deploy job passes the workflow's own `GITHUB_TOKEN` (`packages: read`) to `deploy` on stdin. `deploy` logs in using a temporary Docker config directory and deletes it afterwards, so no registry credentials stay on disk.
4. **The infra repo owns every compose file.** App repos provide an image and nothing else. The compose files enforce read-only rootfs, `cap_drop: ALL`, `no-new-privileges`, memory limits, no host mounts and no published ports.
5. **Build once, promote the same digest.** Prod is promoted with `deploy <app> prod --from preprod`, so it always gets exactly the image preprod is running.
6. **Compose project = app + env.** `docker compose -p map-guesser-game-preprod` isolates each environment.
7. **The Hetzner Cloud Firewall is the outer wall.** There is no UFW.

---

## 4. New repository layout

```
infrastructure/
├── README.md                        # overview, rebuild steps, day-2 operations
├── CLAUDE.md
├── cloud-init.yaml                  # entire host provisioning
├── bin/
│   ├── deploy                       # the ONLY privileged CI entrypoint
│   ├── infra-apply                  # sync repo → host (bin, sudoers, caddy, sites)
│   ├── install-runner               # register the GitHub Actions runner
│   └── render-caddy-sites           # apps/*/app.conf → Caddy site blocks
├── caddy/
│   ├── compose.yml
│   └── Caddyfile
├── apps/
│   └── map-guesser-game/
│       ├── app.conf                 # IMAGE, HOST, PORT, ENVS
│       └── compose.yml              # hardened service definition
├── .github/workflows/
│   ├── ci.yml                       # shellcheck, cloud-init schema, caddy validate, compose config
│   ├── app-pipeline.yml             # reusable: build → dev → preprod
│   └── app-promote.yml              # reusable: preprod → prod
└── docs/
    ├── REDESIGN-PLAN.md             # this file
    ├── ADDING-AN-APP.md
    └── SECURITY.md
```

**Deleted:** `setup.sh`, `bootstrap.sh`, `.env.template`, `apps.conf`, `scripts/**`,
`docs/CONFIGURATION.md`, `docs/TROUBLESHOOTING.md` and `docs/DEPLOYMENT-PLAN.md`.

---

## 5. Host provisioning (`cloud-init.yaml`)

You paste one file into Hetzner's "Cloud config" field when creating the server.

| Concern | Implementation |
|---------|----------------|
| OS | Ubuntu 24.04 LTS, packages upgraded on first boot |
| Admin user | `admin`, with your SSH key and `NOPASSWD` sudo, in the docker group |
| SSH | `PermitRootLogin no`, `PasswordAuthentication no`, `AllowUsers admin`, port 22. The Hetzner Firewall limits it to your IP. |
| Updates | `unattended-upgrades` with automatic reboot at 04:00 UTC |
| Docker | Official `docker-ce` repo. Log rotation, `no-new-privileges`, `live-restore`. |
| Swap | 2 GB swapfile |
| Runner user | `runner` system user, not in the docker group |
| Infra repo access | A read-only **deploy key** is generated at `/root/.ssh/infra_deploy`. GitHub's host key is pinned. |
| Bootstrap | `infra-bootstrap <runner-token>` clones `/srv/infra`, runs `infra-apply` and registers the runner |
| Cleanup | Weekly `docker image prune` timer |

Steps you do by hand after boot (documented in the README):

1. Add `/root/.ssh/infra_deploy.pub` as a read-only deploy key on the infra repo.
2. Run `sudo infra-bootstrap <runner registration token>`.
3. Fill in `/etc/apps/<app>/<env>.env`.

---

## 6. CI/CD design

### 6.1 GitHub Free with private repos

Making the repos private on the Free org plan changes three things:

- **Environments and required reviewers are not available for private repos on Free.** The prod gate is therefore a separate **manual `promote` workflow**. It can only be triggered by someone with write access, which is just you. It deploys whatever image is currently running in preprod.
- **Runner groups limited to "selected workflows" are not something we rely on.** With private repos, fork PRs from outsiders are no longer a threat. The runner is registered at org level in the Default group, with the label `deploy`.
- **Limits:** 2,000 GitHub-hosted Actions minutes per month and 500 MB of private GHCR storage. Self-hosted runner minutes are free and an Angular build takes a few minutes, so this is plenty. Prune old package versions if storage grows.

The infra repo must allow its reusable workflows to be called by other org repos:
Settings → Actions → General → Access → "Accessible from repositories in the organization".

### 6.2 App repo workflows (~25 lines total)

```yaml
# .github/workflows/pipeline.yml
name: pipeline
on:
  push:
    branches: [main]
  workflow_dispatch:   # run from any branch → build + deploy to dev only
permissions:
  contents: read
  packages: write
jobs:
  pipeline:
    uses: Kaptajn-Kasper/infrastructure/.github/workflows/app-pipeline.yml@main
    with:
      app: map-guesser-game
```

```yaml
# .github/workflows/promote.yml
name: promote to prod
on: workflow_dispatch
permissions:
  packages: read
jobs:
  promote:
    uses: Kaptajn-Kasper/infrastructure/.github/workflows/app-promote.yml@main
    with:
      app: map-guesser-game
```

### 6.3 Environments and URLs

| Env | Trigger | URL | Protection |
|-----|---------|-----|------------|
| dev | push to `main`, or manual run from any branch | `map-guesser-dev.kaptajnkasper.net` | basic auth + `noindex` |
| preprod | automatically after dev is healthy (`main` only) | `map-guesser-preprod.kaptajnkasper.net` | basic auth + `noindex` |
| prod | manual "promote to prod" workflow | `map-guesser.kaptajnkasper.net` | — |

**DNS:** one wildcard A record `*.kaptajnkasper.net` points at the VM. Caddy gets a
certificate for each host through HTTP-01.

**Rollback:** run `sudo deploy map-guesser-game prod <older digest>` on the VM.
Previous digests are listed in `/var/log/deploy.log`. A failed health check also
rolls back to the previous image automatically.

### 6.4 `bin/deploy`: the trust boundary

```
deploy <app> <env> ghcr.io/kaptajn-kasper/<app>@sha256:<digest>
deploy <app> <env> --from <other-env>
```

1. The app must exist in `/srv/infra/apps`, and the env must be listed in that app's `ENVS`.
2. The image must be exactly this app's GHCR repository, pinned by digest.
3. If a token is provided on stdin, `deploy` logs in to GHCR with a temporary Docker config and pulls the image.
4. It runs `docker compose -p <app>-<env> up -d --wait`. If the health check fails, it redeploys the previous image and exits non-zero.
5. It records the image in `/var/lib/deploy/<app>-<env>.image` and appends a line to `/var/log/deploy.log`.

---

## 7. Changes in `map-guesser-game` (Phase 4)

1. **Runtime config.** Serve `/config.json`, generated at container start from env vars (`MAPTILER_KEY`), and load it with `provideAppInitializer`. Then one image works in every environment. The key ends up in the browser anyway, so protect it with the **HTTP-referrer restriction in MapTiler** for all three hostnames.
2. **Dockerfile.** Build with `node:22-alpine` and serve with `nginxinc/nginx-unprivileged:alpine` on port 8080. Write only to `/tmp`, because the rootfs is read-only.
3. **Workflows.** Add `pipeline.yml` and `promote.yml` (§6.2).
4. **Delete:** `setup_server.sh`, `re_deploy.sh`, `docker-compose.prod.yml`, `Caddyfile.snippet*`, the unused `nginx/default.conf` and `nginx/production.conf`, and the `.compose.env-override.yml` ignore line.
5. **Docs.** Update `CLAUDE.md`, `README.md` and `ENVIRONMENT_SETUP.md`.

---

## 8. Security summary

| Threat | Control |
|--------|---------|
| Internet scanning and SSH brute force | Hetzner Firewall allows only 80/443, plus 22 from your IP. Key-only auth, no root login. |
| Stolen admin key | Still requires your IP. There are no GitHub credentials on the server apart from one read-only deploy key for the infra repo. |
| Malicious PR runs on the runner | Repos are private. No `pull_request` triggers reach the runner. |
| Compromised workflow or token | The runner can only call `deploy` with this app's digest-pinned image into a compose file owned by the infra repo. It has no root shell and no docker socket. |
| Compromised app container | Read-only rootfs, non-root, `cap_drop: ALL`, `no-new-privileges`, memory limit, no host mounts, no published ports. |
| Unpatched OS | `unattended-upgrades` with automatic reboot. Rebuilding is the escape hatch. |
| Non-prod environments indexed or abused | Basic auth and `noindex` on dev and preprod. |

Accepted trade-off: `admin` has `NOPASSWD` sudo, so the SSH key plus your IP are the
whole boundary for admin access.

---

## 9. Migration plan

The old VM keeps serving until the new one is verified.

1. **Phase 1: infra repo rewrite** (this branch). Everything in §4.
2. **Phase 2: GitHub setup (manual).**
   - Make the repos private.
   - Allow org access to the infra repo's workflows.
   - Protect `main` on the infra repo.
3. **Phase 3: new VM.**
   - Create the Hetzner Firewall.
   - Create the CX22 with `cloud-init.yaml`.
   - Add the deploy key and run `infra-bootstrap`.
   - Create the env files.
   - Add the wildcard DNS record.
4. **Phase 4: map-guesser-game PR** (§7). Merging it deploys dev and preprod on the new VM.
5. **Phase 5: cut over.**
   - Run "promote to prod" and point `map-guesser.kaptajnkasper.net` at the new IP.
   - Delete the old VM.
   - Revoke its old SSH keys and deploy keys in GitHub.

---

## 10. Decisions

| Question | Decision |
|----------|----------|
| SSH access | Hetzner Firewall allows 22 only from your IP |
| Hostnames | Flat: `<host>-<env>.kaptajnkasper.net`, one wildcard record |
| Preprod gate | Automatic after dev succeeds |
| Admin sudo | `NOPASSWD` |
| Backups | None. Everything is rebuilt from git. |
| Repo visibility | Private ("internal" visibility needs GitHub Enterprise, so private is the equivalent here). The prod gate is a manual workflow because environment approvals are not available for private repos on Free. |
