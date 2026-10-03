# Infrastructure Redesign Plan

Plan for rebuilding the Hetzner VM from scratch with a smaller, more secure setup.
It is meant for a few hobby web apps (starting with `map-guesser-game`), deployed
from GitHub through a self-hosted runner, with `dev`, `preprod` and `prod`
environments for each app.

Status: **decided. Phase 1 (infra repo) and Phase 4 (map-guesser-game) implemented on their `claude/hetzner-vm-infrastructure-plan-2t78mm` branches.** Decisions are recorded in §10.

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
                 GitHub (Kaptajn-Kasper org, public repos)
 ┌────────────────────────────────────────────────────────────────┐
 │ app repo: push to main                                         │
 │   └─ build           (GitHub-hosted)  → ghcr.io/…/<app>@sha256 │
 │   └─ deploy dev      (self-hosted, label "deploy")             │
 │   └─ deploy preprod  (self-hosted, after dev is healthy)       │
 │   └─ deploy prod     (self-hosted, after your approval)        │
 │ runner group "vm-deploy": only app-pipeline.yml@main may use it│
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
5. **Build once, promote the same digest.** dev, preprod and prod all deploy the digest produced by the run's build job.
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
│   └── app-pipeline.yml             # reusable: build → dev → preprod → prod
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
| Infra repo access | Public repo cloned over HTTPS. No GitHub credentials on the server. |
| Bootstrap | `infra-bootstrap <runner-token>` clones `/srv/infra`, runs `infra-apply` and registers the runner |
| Cleanup | Weekly `docker image prune` timer |

Steps you do by hand after boot (documented in the README):

1. Run `sudo infra-bootstrap <runner registration token>`.
2. Fill in `/etc/apps/<app>/<env>.env`.

---

## 6. CI/CD design

### 6.1 Self-hosted runner on public repos

GitHub warns against self-hosted runners on public repos, because anyone can open
a fork PR that adds a workflow targeting the runner. These org settings close that
hole, and all of them are available on the Free plan:

- **Runner group `vm-deploy` with "Selected workflows".** Only jobs defined in
  `Kaptajn-Kasper/infrastructure/.github/workflows/app-pipeline.yml@refs/heads/main`
  may run on it, and only for the app repos you select. A workflow written in an
  app repo or a fork cannot target the runner at all.
- **Fork PR approval:** "Require approval for all external contributors".
- **No `pull_request` triggers** in `app-pipeline.yml`, plus branch protection on
  the infra repo's `main`.
- **Environment `prod` with required reviewers** (free for public repos), with
  deployment branches limited to `main`.

Even if all of that failed, the runner user can only call `sudo deploy` with an
image from the app's own GHCR repository.

### 6.2 App repo workflow (~15 lines)

```yaml
# .github/workflows/pipeline.yml (the only workflow an app needs)
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

### 6.3 Environments and URLs

| Env | Trigger | URL | Protection |
|-----|---------|-----|------------|
| dev | push to `main`, or manual run from any branch | `map-guesser-dev.kaptajnkasper.net` | basic auth + `noindex` |
| preprod | automatically after dev is healthy (`main` only) | `map-guesser-preprod.kaptajnkasper.net` | basic auth + `noindex` |
| prod | after preprod, once you approve the waiting job | `map-guesser.kaptajnkasper.net` | — |

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
3. **Workflow.** Add `pipeline.yml` (§6.2) and create the `prod` environment with you as required reviewer.
4. **Delete:** `setup_server.sh`, `re_deploy.sh`, `docker-compose.prod.yml`, `Caddyfile.snippet*`, the unused `nginx/default.conf` and `nginx/production.conf`, and the `.compose.env-override.yml` ignore line.
5. **Docs.** Update `CLAUDE.md`, `README.md` and `ENVIRONMENT_SETUP.md`.

---

## 8. Security summary

| Threat | Control |
|--------|---------|
| Internet scanning and SSH brute force | Hetzner Firewall allows only 80/443, plus 22 from your IP. Key-only auth, no root login. |
| Stolen admin key | Still requires your IP. There are no GitHub credentials on the server. |
| Malicious fork PR runs on the runner | Runner group only admits `app-pipeline.yml@main`, fork PR approval is required, and there are no `pull_request` triggers. |
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
   - Create the `vm-deploy` runner group (selected repos and selected workflow).
   - Require approval for fork PR workflows.
   - Protect `main` on the infra repo.
   - Create the `prod` environment with required reviewers in each app repo.
3. **Phase 3: new VM.**
   - Create the Hetzner Firewall.
   - Create the CX22 with `cloud-init.yaml`.
   - Run `infra-bootstrap`.
   - Create the env files.
   - Add the wildcard DNS record.
4. **Phase 4: map-guesser-game PR** (§7). Merging it deploys dev and preprod on the new VM.
5. **Phase 5: cut over.**
   - Approve the waiting prod job and point `map-guesser.kaptajnkasper.net` at the new IP.
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
| Repo visibility | Public. The runner is protected by a runner group limited to selected workflows (§6.1), and prod is gated by environment approval. |
