# Deployment Optimization Plan

Streamline the workflow for provisioning a new server and deploying all apps with minimal manual steps.

**Goal**: Go from "new Hetzner server" to "all apps running" in 2 steps instead of 10+.

---

## Task 1: Create an app manifest (DONE)

**Problem**: There's no record of which apps should be deployed on a server. Every time you set up a new server, you have to remember which repos to clone and where to put them.

**Solution**: Create an `apps.conf` file in the infrastructure repo root that lists all apps to deploy.

**Format**:

```bash
# apps.conf — app deployment manifest
# Format: <github-org/repo> <local-directory-name>
#
# Each line maps a GitHub repo to a directory under /opt/apps/
# Lines starting with # are comments, blank lines are ignored

myorg/frontend        frontend
myorg/api-service     api
myorg/admin-panel     admin
myorg/worker-service  worker
```

**Why a simple text file**: No dependencies (no `yq`, no `jq`), easy to read and edit, works with basic bash (`while read`), and it's diffable in git. YAML or JSON would add complexity for no real benefit here.

**Notes**:

- The file is checked into git so it's versioned and shared across setups
- You can comment out apps to skip them during deployment
- The local directory name lets you decouple the repo name from the deploy path (e.g., `myorg/api-service-v2` can still deploy to `api`)

---

## Task 2: Establish per-app Caddy snippet convention (DONE)

**Problem**: After cloning and starting each app, you have to manually edit `/etc/caddy/Caddyfile` to add reverse proxy rules for every app. This is tedious, error-prone, and not version-controlled with the app.

**Solution**: Each app repo includes a `Caddyfile.snippet` file at its root that defines its own reverse proxy configuration. The deploy script (Task 4) will copy these into `/etc/caddy/conf.d/` automatically.

**Convention**: Each app repo should contain:

```
myapp/
├── docker-compose.yml      # already exists
├── Caddyfile.snippet        # NEW — reverse proxy config for this app
├── .env.example             # optional — environment template
└── ...
```

Example `Caddyfile.snippet` for a web app:

```caddy
myapp.example.com {
    reverse_proxy myapp:3000
}
```

Example for an API with path-based routing:

```caddy
api.example.com {
    reverse_proxy api-service:8080
}
```

**Changes**:

- Update `scripts/optional/caddy.sh` to ensure the main Caddyfile includes an import line for snippets:
  ```caddy
  import /etc/caddy/conf.d/*.caddy
  ```
- Ensure `/etc/caddy/conf.d/` exists and is writable (this directory is already created by `caddy.sh`)
- Document this convention in `docs/CONFIGURATION.md`

**Why per-app snippets**:

- Caddy config lives with the app that needs it — version-controlled in the app repo
- Adding or removing an app doesn't require editing a shared Caddyfile
- Each app team/context owns its own routing rules
- The deploy script can manage these files automatically

---

## Task 3: Build the deploy-apps script (DONE)

**Problem**: Deploying apps is a multi-step manual process: clone repo, cd into it, docker compose up, edit Caddy config, reload. Multiply by N apps.

**Solution**: Create `scripts/deploy-apps.sh` — a single script that reads `apps.conf` and handles the full deployment lifecycle for every app.

**What the script does**:

```
For each app in apps.conf:
  1. If /opt/apps/<dir> doesn't exist → git clone
  2. If /opt/apps/<dir> exists → git pull (update to latest)
  3. If .env.example exists but .env doesn't → warn (app needs env config)
  4. Run: docker compose up -d --build
  5. If Caddyfile.snippet exists → copy to /etc/caddy/conf.d/<dir>.caddy

After all apps:
  6. Validate Caddy config: caddy validate
  7. Reload Caddy: systemctl reload caddy
  8. Print summary: which apps succeeded, which failed, which need attention
```

**Script details**:

- Source `scripts/lib/common.sh` for logging and utility functions
- Accept optional flags:
  - `--app <name>` to deploy a single app instead of all
  - `--pull-only` to update repos without restarting containers
  - `--no-caddy` to skip Caddy configuration
- Run as the operator user (not root) — Docker access via docker group membership
- Exit with non-zero if any app failed, but continue deploying remaining apps
- Log output to `/opt/apps/logs/deploy-<timestamp>.log`

**Installation**:

- Symlink or copy to `/usr/local/bin/deploy-apps` so operator can run it from anywhere
- This installation step should be added to `scripts/optional/app-directory.sh` since it depends on the app directory existing

**Error handling**:

- If git clone/pull fails → log error, skip app, continue
- If docker compose fails → log error, skip Caddy step for that app, continue
- If Caddy validation fails after all apps → warn but don't reload (prevents breaking existing routing)
- Missing `docker-compose.yml` in a cloned repo → warn and skip

---

## Task 4: Update documentation (DONE)

Documentation for all completed tasks has been added to `docs/CONFIGURATION.md` and `docs/TROUBLESHOOTING.md`.
