# Infrastructure

One Hetzner VM that hosts small hobby web apps. Each app has `dev`, `preprod`
and `prod` environments, deployed from GitHub Actions through a self-hosted
runner on the VM.

```
push to main ─► build image (GitHub-hosted) ─► ghcr.io/kaptajn-kasper/<app>@sha256:…
             ─► deploy dev      (self-hosted runner → sudo deploy)
             ─► deploy preprod  (automatic, once dev is healthy)
             ─► deploy prod     (waits for your approval on the "prod" environment)
```

Design rationale and the security model: [docs/REDESIGN-PLAN.md](docs/REDESIGN-PLAN.md),
[docs/SECURITY.md](docs/SECURITY.md).

## Layout

| Path | Purpose |
|------|---------|
| `bootstrap.sh` | Complete host provisioning (users, SSH, Docker, updates, swap), then `infra-apply`. Idempotent. |
| `cloud-init.yaml` | Optional wrapper that runs `bootstrap.sh` on a brand-new server |
| `bin/deploy` | The only command CI may run as root: deploy a digest-pinned image to one app env |
| `bin/infra-apply` | Sync this repo onto the host: scripts, sudoers, Caddy, site config |
| `bin/install-runner` | Register the GitHub Actions runner as the unprivileged `runner` user |
| `bin/render-caddy-sites` | Generate Caddy site blocks from `apps/*/app.conf` |
| `caddy/` | Edge proxy (automatic HTTPS) on the `edge` Docker network |
| `apps/<app>/` | `app.conf` (image, hostname, port, envs) and hardened `compose.yml` |
| `.github/workflows/app-pipeline.yml` | Reusable workflow that app repos call |

On the host:

| Path | Purpose |
|------|---------|
| `/srv/infra` | Checkout of this repo |
| `/etc/apps/<app>/<env>.env` | Runtime config and secrets per app env (root, 0600) |
| `/etc/infra/caddy/` | Generated site blocks and non-prod basic auth |
| `/var/lib/deploy/<app>-<env>.image` | Image currently deployed per env |
| `/var/log/deploy.log` | Deploy history (use it to find digests for rollback) |

## Setting up the server

This works on a **rebuilt** server (Hetzner Console → server → Rebuild →
Ubuntu 24.04), which keeps the server's price and IP address. A rebuild wipes
the disk, so first copy anything you still need off the old system, such as API
keys in `/opt/apps/configs/`.

**1. Hetzner Cloud Firewall** (Console → Firewalls), inbound rules:

| Protocol | Port | Source |
|----------|------|--------|
| TCP | 22 | your IP (`/32`) |
| TCP | 80 | any |
| TCP | 443 | any |
| UDP | 443 | any |

**2. Rebuild the server** with the plain **Ubuntu 24.04** image, and attach the
firewall. Avoid the "Docker CE" app image; `bootstrap.sh` installs Docker itself.

**3. DNS:** create an A record `*.kaptajnkasper.net` (and the bare
`kaptajnkasper.net` if used) pointing to the server IP.

**4. Bootstrap:** log in as root (with the SSH key or root password Hetzner
gives you after the rebuild) and run:

```bash
ssh root@<server-ip>
git clone https://github.com/Kaptajn-Kasper/infrastructure.git /srv/infra

# Runner token: github.com/organizations/Kaptajn-Kasper/settings/actions/runners/new
/srv/infra/bootstrap.sh \
  --ssh-key "ssh-ed25519 AAAA… you@laptop" \
  --runner-token <runner-registration-token>
```

- `--ssh-key` is the public key you log in with from now on. If you leave it
  out, root's `authorized_keys` is copied, which works when Hetzner installed
  your key during the rebuild.
- `--runner-token` can be left out and the runner registered later with
  `sudo /srv/infra/bin/install-runner <token>`.
- The script prints the non-prod basic auth password once. Save it in your
  password manager.
- Root login over SSH is disabled at the end. **Keep the root session open**
  and check `ssh admin@<server-ip>` in a new terminal before closing it.

The script is idempotent, so you can re-run it if something fails half-way.

For a brand-new server, `cloud-init.yaml` runs the same steps automatically when
pasted into "Cloud config" (with your SSH key selected at creation).

**5. App config:** fill in `/etc/apps/<app>/<env>.env` for each app (e.g.
`MAPTILER_KEY=…`), then re-run the app's pipeline.

## Day-to-day

```bash
# Apply changes merged to this repo (new app, Caddy tweak, script change)
sudo infra-apply

# Roll back prod to an earlier image
grep map-guesser-game-prod /var/log/deploy.log
sudo deploy map-guesser-game prod ghcr.io/kaptajn-kasper/map-guesser-game@sha256:<digest>

# Logs and status
docker compose ls
docker logs -f map-guesser-game-prod-web-1
journalctl -u 'actions.runner.*' -f
```

If an image is not cached locally, the manual `deploy` needs registry access first:
`docker login ghcr.io` with a token that has `read:packages`.

## Adding an app

See [docs/ADDING-AN-APP.md](docs/ADDING-AN-APP.md).

## One-time GitHub settings

The repos are public, so the self-hosted runner must only ever run jobs defined
in this repo. Set these up before registering the runner:

1. **Runner group:** Org settings → Actions → Runner groups → New group `vm-deploy`.
   - Repository access: *Selected repositories* (the app repos). Tick "Allow public repositories".
   - Workflow access: *Selected workflows*:
     `Kaptajn-Kasper/infrastructure/.github/workflows/app-pipeline.yml@refs/heads/main`
2. **Fork PRs:** Org settings → Actions → General → "Require approval for all
   external contributors" (or stricter).
3. **Branch protection** on `main` of this repo. It defines what the runner may do.
4. **Per app repo:** Settings → Environments → `prod` → Required reviewers: you,
   with deployment branches limited to `main`. Do the same branch limit for
   `preprod`. **Without required reviewers, prod deploys automatically.**
