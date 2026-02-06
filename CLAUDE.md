# Infrastructure

Automated server provisioning and app deployment for Ubuntu VPS instances with Docker Compose and Caddy reverse proxy.

## Repository structure

- `setup.sh` — Main orchestrator, runs core + optional scripts
- `bootstrap.sh` — Cloud-init entry point for fresh servers
- `apps.conf` — App deployment manifest (which repos to deploy where)
- `scripts/core/` — Always-run setup scripts (SSH, firewall, users, MOTD)
- `scripts/optional/` — Conditionally-run scripts (Docker, Caddy, app directory)
- `scripts/deploy-apps.sh` — App deployment script (installed as `deploy-apps`)
- `scripts/lib/common.sh` — Shared logging/utility functions
- `docs/CONFIGURATION.md` — Full configuration reference including deployment workflows
- `docs/TROUBLESHOOTING.md` — Common issues and solutions

## Server layout

- `/opt/apps/` — App clone directories
- `/opt/apps/configs/<app>/` — Per-app secret/config files (persist across deploys)
- `/opt/apps/caddy/conf.d/` — Caddy reverse proxy snippets (one `.caddy` file per app)
- `/opt/apps/logs/` — Deployment logs

## deploy-apps

The main deployment tool. Reads `apps.conf` and for each app: clones/pulls the repo, seeds/injects configs, builds containers, and configures Caddy.

### Key commands

```bash
deploy-apps                                                    # Deploy all apps (prod)
deploy-apps --app map-guesser-game                             # Deploy single app (prod)
deploy-apps --app map-guesser-game --env dev --branch feature/x  # Deploy branch to isolated env
deploy-apps --app map-guesser-game --env dev --teardown        # Tear down an env
deploy-apps --app map-guesser-game --branch hotfix/fix         # Deploy specific branch to prod
```

### Environment deployments (`--env`)

`--env <name>` creates a fully isolated deployment alongside prod:

| Aspect | Prod (no `--env`) | `--env dev` |
|--------|-------------------|-------------|
| Clone dir | `/opt/apps/<app>/` | `/opt/apps/<app>-dev/` |
| Config dir | `/opt/apps/configs/<app>/` | `/opt/apps/configs/<app>-dev/` |
| Container names | `*-prod` (from compose) | `*-dev` (auto-generated override) |
| Caddy snippet | `Caddyfile.snippet` | `Caddyfile.snippet.dev` |
| Git branch | default | specified via `--branch` |

Rules: `--env prod` is rejected (prod = no flag), `--teardown` requires `--env`, env names must match `^[a-z][a-z0-9-]*$`.

### Config injection flow

1. First deploy seeds example files into `/opt/apps/configs/<app>/` and stops — edit with real values
2. Every subsequent deploy copies configs from that directory into the app before building

### Adding env support to a new app

1. Add `Caddyfile.snippet.<env>` to the app repo (e.g. `Caddyfile.snippet.dev`)
2. Add `.compose.env-override.yml` to the app's `.gitignore`
3. Add a DNS record for the env subdomain

## Conventions

- App repos contain `Caddyfile.snippet` for prod routing and `Caddyfile.snippet.<env>` for env routing
- App repos contain `docker-compose.prod.yml` (or `docker-compose.yml` / `compose.yml`)
- Secrets go in `/opt/apps/configs/`, never committed to git
- Container names in compose files use `-prod` suffix (gets replaced by `--env`)
- All containers join the `caddy-network` Docker network for Caddy routing
