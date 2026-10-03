# Infrastructure Redesign Plan

Plan for rebuilding the Hetzner VM from scratch with a smaller, more secure setup.
It is meant for a few hobby web apps (starting with `map-guesser-game`), deployed
from GitHub through a self-hosted runner, with `dev`, `preprod` and `prod`
environments for each app.

Status: **proposal**. Nothing in this document has been built yet.

---

## 1. Goals and non-goals

**Goals**

1. **Simple.** One file provisions the host and one script deploys. You should be able to read the whole repo in about 15 minutes.
2. **Secure by default.** No inbound ports except 80/443 (and SSH, restricted). CI never gets SSH access or root.
3. **Reproducible.** You can delete the VM and rebuild it in under 30 minutes from git plus a small set of secrets.
4. **Three environments per app.** Each one is isolated and reachable at its own subdomain, and the same image is promoted from dev to preprod to prod.
5. **Hands-off CI/CD.** A push to `main` builds the app and deploys it. Prod needs one click to approve.

**Non-goals**

- Kubernetes, Nomad, Terraform-managed fleets, multiple servers, or high availability.
- Building images on the VM.
- A self-hosted monitoring stack (Prometheus/Grafana). An external uptime check is enough.

---

## 2. Review of the current setup

| Area | Today | Problem |
|------|-------|---------|
| Size | ~3,500 lines of bash in 20 scripts, plus MOTD and banners | Too much to maintain for a hobby box. Most of it reimplements what cloud-init and Ubuntu defaults already do. |
| SSH | Custom port only. `PasswordAuthentication` and `PermitRootLogin` are not set. | A custom port hides SSH but does not secure it. Key-only login and no root login are what matter. |
| Operator user | Full `NOPASSWD` sudo, and gets root's GitHub SSH key copied in | One stolen key gives root access plus access to GitHub. |
| `gh-actions` user | In the `docker` group, with `NOPASSWD: /usr/bin/docker, /usr/bin/systemctl` | Both are equivalent to root (`docker run -v /:/host`, `systemctl` with a custom unit). This is not least privilege. |
| Deploy model | The server `git clone`s app repos and builds them on the box (`deploy-apps`) | The server needs GitHub credentials, runs the app repo's build code with Docker (root-level) access, and burns CPU/RAM on a small VM. |
| Firewall | UFW only | Docker-published ports bypass UFW. A Hetzner Cloud Firewall (outside the VM) is simpler and cannot be bypassed this way. |
| Environments | `--env` generates a compose override and rewrites `container_name` with sed | Fragile. Compose project names (`-p app-env`) give the same isolation without any of this. |
| Secrets/config | `environment.prod.ts` copied into the source tree before build | A separate image is built for each environment, so preprod and prod are not the same artifact. |
| App repo leftovers | `setup_server.sh` (nginx and certbot), `re_deploy.sh`, `Caddyfile.snippet*` | Dead code from earlier designs. `Caddyfile.snippet.dev` points at port `4200`, but the prod image serves on `80`, so the dev route is broken. |

What still works and should be kept:

- **Caddy** for automatic HTTPS.
- **Docker Compose** for each app.
- **Secrets on the server, never in git.**
- **A single shared Docker network for the reverse proxy.**

---

## 3. Target architecture

```
                 GitHub (Kaptajn-Kasper org)
 ┌────────────────────────────────────────────────────────────────┐
 │ app repo: push to main                                         │
 │   └─ job "build"  (GitHub-hosted ubuntu-latest)                │
 │        test → docker build → push ghcr.io/kaptajn-kasper/<app> │
 │   └─ job "deploy-dev"      runs-on: [self-hosted, deploy]      │
 │   └─ job "deploy-preprod"  needs dev,     environment: preprod │
 │   └─ job "deploy-prod"     needs preprod, environment: prod ✋ │
 └───────────────────────────────┬────────────────────────────────┘
                                 │ outbound HTTPS only (runner polls GitHub)
 ┌───────────────────────────────▼────────────────────────────────┐
 │ Hetzner VM  (Ubuntu 24.04, CX22)                               │
 │  Hetzner Cloud Firewall: in 80,443 (+22 from your IP / none)   │
 │                                                                │
 │  actions-runner (systemd, user "runner", no docker group)      │
 │     └─ sudo /usr/local/bin/deploy <app> <env> <image-digest>   │
 │                                                                │
 │  /srv/infra   (checkout of this repo, root-owned)              │
 │  /etc/apps/<app>/<env>.env  (secrets, 0600 root)               │
 │                                                                │
 │  docker network "edge"                                         │
 │    caddy  :80/:443  ─┬─► map-guesser-game-dev                  │
 │                      ├─► map-guesser-game-preprod              │
 │                      └─► map-guesser-game-prod                 │
 └────────────────────────────────────────────────────────────────┘
```

### Key design decisions

1. **Build on GitHub, deploy on the VM.** Images are built on GitHub-hosted runners and pushed to GHCR. The VM never sees source code, never builds anything, and needs no GitHub credentials for public packages.
2. **The self-hosted runner has no privileges.** Its only privilege is one `sudoers` line that lets it run `/usr/local/bin/deploy`. It has no docker group, no general sudo, and no SSH key.
3. **The infra repo owns every compose file.** App repos provide an image and nothing else. The deploy script only runs compose files from `/srv/infra/apps/<app>/compose.yml`, which you have reviewed. These files enforce `no-new-privileges`, `cap_drop: ALL`, no host mounts, no `privileged`, and memory limits. Even a compromised workflow can only deploy *an image* into a sandbox you defined. It cannot change how that image runs.
4. **Build once, promote the same digest.** dev, preprod and prod all run the exact same image (`@sha256:…`). Differences between environments come from runtime env files only.
5. **Compose project = app + env.** `docker compose -p map-guesser-game-preprod …` isolates containers, networks and volumes for each environment. No `container_name` rewriting is needed.
6. **The Hetzner Cloud Firewall is the outer wall.** UFW becomes optional. SSH is either limited to your IP or closed completely if you use Tailscale (see §8).

---

## 4. New repository layout

```
infrastructure/
├── README.md                      # 1-page: rebuild steps + how deploys work
├── cloud-init.yaml                # entire host provisioning (replaces setup.sh, bootstrap.sh, scripts/core, scripts/optional)
├── bin/
│   ├── deploy                     # the ONLY privileged entrypoint (≈100 lines bash)
│   └── infra-apply                # sync /srv/infra → Caddy config, install bin/, reload
├── caddy/
│   ├── compose.yml                # caddy:2 container on "edge" network
│   └── Caddyfile                  # global opts + `import /srv/infra/caddy/sites/*.caddy`
├── apps/
│   └── map-guesser-game/
│       ├── app.conf               # DOMAIN, IMAGE, PORT, ENVS="dev preprod prod"
│       └── compose.yml            # hardened service definition, uses ${IMAGE} ${ENV}
├── .github/workflows/
│   ├── ci.yml                     # shellcheck, `caddy validate`, `docker compose config`
│   └── app-pipeline.yml           # REUSABLE workflow every app repo calls
└── docs/
    ├── REBUILD.md                 # step-by-step from empty Hetzner project
    ├── ADDING-AN-APP.md
    └── SECURITY.md                # threat model, what each control defends
```

**Deleted:** `setup.sh`, `bootstrap.sh`, `.env.template`, `apps.conf`,
`scripts/**` (all 20 scripts including `deploy-apps.sh`, `verify.sh` and the MOTD),
`docs/DEPLOYMENT-PLAN.md`, and most of `docs/CONFIGURATION.md` and
`docs/TROUBLESHOOTING.md`.

---

## 5. Host provisioning (`cloud-init.yaml`)

You paste one file into Hetzner's "Cloud config" field when creating the server. It is idempotent, has no custom bash framework, and does the following:

| Concern | Implementation |
|---------|----------------|
| OS | Ubuntu 24.04 LTS, `package_upgrade: true` |
| Admin user | One user (e.g. `kasper`) with your SSH public key, `sudo` group. Sudo **asks for a password** (set on first login), or `NOPASSWD` if you accept the trade-off. |
| SSH | Drop-in `/etc/ssh/sshd_config.d/10-hardening.conf`: `PermitRootLogin no`, `PasswordAuthentication no`, `KbdInteractiveAuthentication no`, `AllowUsers kasper`. Keep port 22 (the firewall does the filtering). |
| Updates | `unattended-upgrades` with `Automatic-Reboot "true"` at 04:00. Containers restart on their own (`restart: unless-stopped`). |
| Brute-force | Not needed with key-only SSH behind an IP-restricted firewall. Add `fail2ban` only if SSH is left open to the world. |
| Docker | Official `docker-ce` apt repo. `/etc/docker/daemon.json`: log rotation (`max-size 10m`, `max-file 3`), `"no-new-privileges": true`, `"live-restore": true`. |
| Swap | 2 GB swapfile (one `runcmd` line). |
| Runner user | `runner` system user, **not** in the docker group. |
| Sudoers | `/etc/sudoers.d/runner`: `runner ALL=(root) NOPASSWD: /usr/local/bin/deploy` |
| Infra checkout | `git clone https://github.com/Kaptajn-Kasper/infrastructure /srv/infra` (public repo, no key needed), then `/srv/infra/bin/infra-apply` |
| Cleanup | Weekly systemd timer: `docker image prune -af --filter until=168h` |

Steps you still do by hand after boot (documented in `docs/REBUILD.md`):

1. Register the GitHub runner (needs a short-lived registration token, see §6.3).
2. Create the `/etc/apps/<app>/<env>.env` secret files.

**Optional later:** describe the server, firewall, SSH key and DNS in a ~60-line OpenTofu file with the `hcloud` provider. This is not needed to start.

---

## 6. CI/CD design

### 6.1 Reusable pipeline (lives in the infra repo)

Each app repo has one small workflow:

```yaml
# map-guesser-game/.github/workflows/pipeline.yml
name: pipeline
on:
  push:
    branches: [main]
  workflow_dispatch:          # manual: deploy any branch to dev
    inputs:
      target: { type: choice, options: [dev], default: dev }
permissions:
  contents: read
  packages: write
jobs:
  pipeline:
    uses: Kaptajn-Kasper/infrastructure/.github/workflows/app-pipeline.yml@main
    with:
      app: map-guesser-game
```

`app-pipeline.yml` (in the infra repo) does the following:

1. **build** (`ubuntu-latest`): runs `npm ci && npm test`, then `docker/build-push-action` builds and pushes `ghcr.io/kaptajn-kasper/<app>:sha-<short>`. It outputs the **digest**.
2. **deploy-dev** (`runs-on: [self-hosted, deploy]`, `environment: dev`): runs `sudo /usr/local/bin/deploy <app> dev <digest>`. There is no `actions/checkout`, so no repo code runs on the VM.
3. **deploy-preprod** (`needs: deploy-dev`, `environment: preprod`): same, after a smoke test of the dev URL.
4. **deploy-prod** (`needs: deploy-preprod`, `environment: prod`): same. The `prod` GitHub Environment has **required reviewers = you**, so the run waits for one click. Required reviewers are free for public repos.

On a `workflow_dispatch` from a feature branch, only build and deploy-dev run. This replaces today's `--env dev --branch feature/x`.

### 6.2 Environments and URLs

| Env | Trigger | Approval | URL | Extra protection |
|-----|---------|----------|-----|------------------|
| dev | push to `main`, or manual dispatch of any branch | none | `map-guesser-dev.kaptajnkasper.net` | Caddy `basic_auth` + `X-Robots-Tag: noindex` |
| preprod | after dev succeeds (main only) | none (or optional) | `map-guesser-preprod.kaptajnkasper.net` | Caddy `basic_auth` + `noindex` |
| prod | after preprod succeeds | **required reviewer** | `map-guesser.kaptajnkasper.net` | — |

**DNS:** use a single wildcard `*.kaptajnkasper.net → VM IP`. The flat hostnames
(`<app>-<env>`) mean a new app or environment never needs a new DNS record. Today's
nested hostnames (`dev.map-guesser.…`) would need a wildcard per app. Caddy still
gets a separate Let's Encrypt certificate for each host through HTTP-01, so no DNS
API token is needed on the server.

**Rollback:** re-run the `deploy-prod` job of an earlier successful workflow run (it carries the old digest), or SSH in and run `sudo deploy map-guesser-game prod sha256:…`.

### 6.3 Self-hosted runner hardening

Both repos are **public**, and GitHub warns against self-hosted runners on public
repos because fork PRs could run code on them. These controls close that hole:

1. **Org-level runner in a dedicated runner group** (`vm-deploy`), limited to *selected repositories* and *selected workflows*. The only allowed workflow is `Kaptajn-Kasper/infrastructure/.github/workflows/app-pipeline.yml@refs/heads/main`. A workflow in an app repo cannot target the runner directly.
2. **Org setting:** "Require approval for all outside collaborators" for fork PR workflows. The pipeline also never triggers on `pull_request` or `pull_request_target`.
3. **Environment deployment branch rules:** `preprod` and `prod` accept only `main`. `dev` accepts any branch, but only you can push branches.
4. **Branch protection on `main`** in the infra repo (PR required, no force-push), because that branch defines what the runner may run.
5. **The runner process is unprivileged.** It runs as a systemd service under user `runner`, has no docker socket access, and its `sudo` is limited to `/usr/local/bin/deploy`.
6. **Optional:** run the runner with `--ephemeral` under a systemd loop so each job gets a clean work directory. This is cheap and removes leftover state.

### 6.4 `bin/deploy`: the trust boundary

This is the one place to be strict. It is about 100 lines of bash with `set -euo pipefail` and is linted with shellcheck in CI.

```
deploy <app> <env> <image-ref>
```

1. Validate `app` against the existing directories in `/srv/infra/apps/`.
2. Validate `env` against `ENVS` in that app's `app.conf`.
3. Validate `image-ref`: it must match `^ghcr\.io/kaptajn-kasper/<app>@sha256:[a-f0-9]{64}$`, so it must be this app's own image and pinned by digest.
4. `docker pull` the image.
5. `docker compose -p <app>-<env> -f /srv/infra/apps/<app>/compose.yml --env-file /etc/apps/<app>/<env>.env up -d --wait`. `IMAGE`, `ENV` and `APP` are passed through the environment.
6. Write `/srv/infra/caddy/sites/<app>-<env>.caddy` from `app.conf` if it is missing, then `caddy reload` (via `docker exec`).
7. Record the deploy in `/var/log/deploy.log` (app, env, digest, timestamp, GitHub run ID).

Example `apps/map-guesser-game/compose.yml`:

```yaml
services:
  web:
    image: ${IMAGE}
    restart: unless-stopped
    read_only: true
    tmpfs: [/tmp, /var/cache/nginx, /var/run]
    cap_drop: [ALL]
    security_opt: [no-new-privileges:true]
    mem_limit: 128m
    env_file: /etc/apps/map-guesser-game/${ENV}.env
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://127.0.0.1:8080/"]
    networks:
      edge:
        aliases: [map-guesser-game-${ENV}]
networks:
  edge:
    external: true
```

---

## 7. Changes in `map-guesser-game`

1. **Runtime config instead of build-time `environment.prod.ts`.** Serve `/config.json`, generated at container start from env vars by a tiny entrypoint (`envsubst`), and load it with `provideAppInitializer`. Each environment can then use its own MapTiler key with one image. Note that the MapTiler key always ends up in the browser, so it is *not* a secret. Its protection is the **HTTP-referrer restriction in the MapTiler dashboard**, which should list all three hostnames.
2. **Dockerfile:** switch to `nginxinc/nginx-unprivileged:alpine` (port 8080, non-root) and `node:22-alpine` for the build stage (Angular 21 needs Node ≥ 20.19). Add `HEALTHCHECK`.
3. **Add** `.github/workflows/pipeline.yml` (the ~15-line caller shown in §6.1).
4. **Delete:** `setup_server.sh`, `re_deploy.sh`, `docker-compose.prod.yml`, `Caddyfile.snippet`, `Caddyfile.snippet.dev`, `nginx/default.conf`, `nginx/production.conf` (the proxy configs to `:4200` are unused), and the `.compose.env-override.yml` line in `.gitignore`.
5. Keep `docker-compose.dev.yml` and `Dockerfile.dev` for local development only.
6. Update `CLAUDE.md`, `ENVIRONMENT_SETUP.md` and `README.md` to describe the new flow.

**Adding another app later:**

1. Add a Dockerfile and the 15-line `pipeline.yml` to the app repo.
2. Add `apps/<app>/{app.conf,compose.yml}` to the infra repo and run `sudo infra-apply` on the VM.
3. Add the app repo to the runner group's repository list.
4. Create the `/etc/apps/<app>/{dev,preprod,prod}.env` files.

---

## 8. Security summary

| Threat | Control |
|--------|---------|
| Internet scanning and SSH brute force | Hetzner Firewall allows only 80/443. SSH is limited to your IP, or closed if you use Tailscale. Key-only auth, no root login. |
| Stolen admin laptop key | Sudo password (recommended). No GitHub credentials stored on the server. |
| Malicious fork PR runs on the runner | No PR triggers. Runner group limited to the infra repo's reusable workflow on `main`. Fork approval required. |
| Compromised workflow or GitHub token | The runner can only call `deploy` with this app's digest-pinned image into a compose file from the infra repo. It has no shell as root and no docker socket. |
| Compromised app container | Read-only rootfs, non-root user, `cap_drop: ALL`, `no-new-privileges`, memory limit, no host mounts, and only the `edge` network (no published ports). |
| Unpatched OS | `unattended-upgrades` with automatic reboot. Rebuilding from `cloud-init.yaml` is the escape hatch. |
| Data loss | Mostly stateless apps. Turn on Hetzner automatic backups (+20% of server price) for the VM, or snapshot before risky changes. Keep secrets in a password manager so a rebuild never depends on the old disk. |
| Non-prod environments indexed or abused | `basic_auth` and `noindex` on dev and preprod. |

**SSH access decision (pick one):**

- **A (simplest):** the Hetzner Firewall allows 22/tcp only from your home IP. Update the rule in the console if your IP changes.
- **B (most secure):** install Tailscale with cloud-init (auth key used once) and **remove** port 22 from the Hetzner Firewall entirely. SSH goes over the tailnet only. The Hetzner web console remains the break-glass option.

---

## 9. Migration plan

The current VM keeps serving until the new one is verified. You can then switch DNS and delete the old server.

**Phase 0: Decisions (30 min)**
Confirm the open questions in §10.

**Phase 1: Infra repo rewrite (one PR)**

1. Delete the old scripts and add `cloud-init.yaml`, `bin/deploy`, `bin/infra-apply`, `caddy/` and `apps/map-guesser-game/`.
2. Add `ci.yml` (shellcheck, `docker compose config`, `caddy validate` in a container, and a cloud-init schema check with `cloud-init schema`).
3. Add `app-pipeline.yml` (reusable).
4. Rewrite `README.md`, `CLAUDE.md` and `docs/` (`REBUILD.md`, `ADDING-AN-APP.md`, `SECURITY.md`).

**Phase 2: GitHub org setup (manual, ~15 min)**

1. Create the runner group `vm-deploy` with selected repos and the selected workflow.
2. Turn on fork PR approval for all outside collaborators.
3. In each app repo, create the Environments `dev`, `preprod` and `prod`. Add a required reviewer on `prod` and branch rules on `preprod` and `prod`.
4. Turn on branch protection for `main` in the infra repo.

**Phase 3: New VM**

1. Create a Hetzner Cloud Firewall (80, 443, and 22 from your IP).
2. Create a CX22 server with Ubuntu 24.04 and `cloud-init.yaml`, and attach the firewall.
3. SSH in, then register the runner (`config.sh --url https://github.com/Kaptajn-Kasper --runnergroup vm-deploy --labels deploy`) and install it as a service running as `runner`.
4. Create the `/etc/apps/map-guesser-game/*.env` files and the `basic_auth` hash for non-prod.
5. Add the wildcard DNS record pointing at the **new** IP, but leave the apex/prod record on the old VM for now.

**Phase 4: map-guesser-game PR**

1. Make the runtime config, Dockerfile and `pipeline.yml` changes and delete the dead files.
2. Merge. Expect build, then dev, then preprod, then waiting for prod approval.
3. Check the dev and preprod URLs on the new VM.

**Phase 5: Cut over**

1. Approve prod and point `map-guesser.kaptajnkasper.net` at the new VM.
2. Watch the site for a day, then delete the old VM and its GitHub SSH keys and deploy keys. Revoke the old `gh-actions` and `operator` keys from GitHub settings.

---

## 10. Open questions

1. **SSH access:** firewall IP allowlist (A) or Tailscale (B)? The plan works with either. B is recommended if you are on a dynamic IP.
2. **Hostnames:** OK to move from `dev.map-guesser.kaptajnkasper.net` to `map-guesser-dev.kaptajnkasper.net` so that one wildcard record covers everything?
3. **Preprod gate:** should preprod deploy automatically after dev (proposed), or also wait for approval? Another option is to trigger preprod and prod only from a `v*` tag instead of every `main` push.
4. **Sudo for the admin user:** password required (proposed) or `NOPASSWD`?
5. **Backups:** turn on Hetzner automatic backups, or rely on rebuild plus stateless apps?
6. **Repo visibility:** keep both repos public? The runner controls in §6.3 make that safe. Making them private would mean prod approvals need a paid plan, so the proposal keeps them public.
