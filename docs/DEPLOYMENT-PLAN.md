# Deployment Optimization Plan

Streamline the workflow for provisioning a new server and deploying all apps with minimal manual steps.

**Goal**: Go from "new Hetzner server" to "all apps running" in 2 steps instead of 10+.

---

## Task 1: Auto-register SSH keys with GitHub via token

**Problem**: After `setup.sh` generates an SSH key for the operator user, you have to manually copy it and add it to GitHub. This blocks everything downstream — you can't clone any repos until it's done.

**Solution**: Accept a GitHub Personal Access Token (`GH_TOKEN`) during setup and use the `gh` CLI (which is already installed by `05-setup-github-ssh.sh`) to automatically register the generated SSH key with GitHub.

**Changes**:

- Add `GH_TOKEN` to `.env.template` with a comment explaining it's optional and only used during initial setup
- Update `bootstrap.sh` to pass `GH_TOKEN` through to `.env` from environment variables (same pattern as `SSH_PORT`, `OPERATOR_USER`, etc.)
- Update `scripts/core/05-setup-github-ssh.sh` to:
  - If `GH_TOKEN` is set: authenticate with `gh auth login --with-token`, then run `gh ssh-key add` to register the operator's public key with a title like `operator@$(hostname)`
  - If `GH_TOKEN` is not set: fall back to current behavior (display the key and ask you to add it manually)
  - After successful registration, unset the token variable so it doesn't linger in memory
- Update `scripts/core/06-create-gh-actions.sh` to do the same for the gh-actions user's deploy key if `GH_TOKEN` is available

**Security notes**:

- Use a fine-grained GitHub PAT scoped to: SSH key admin + repo read access for your org
- Set a short expiry (7 days) — it's only needed once during provisioning
- The token should never be written to disk or logs — only passed via environment variable
- After the key is registered, the token is no longer needed

**Verification**: After running setup, `sudo -u operator ssh -T git@github.com` should succeed without any manual GitHub interaction.

---

## Task 2: Create an app manifest

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

## Task 3: Establish per-app Caddy snippet convention

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

## Task 4: Build the deploy-apps script

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

## Task 5: Wire everything into the setup flow

**Problem**: The new scripts and conventions need to be integrated into the existing setup flow so that a fresh server can go from zero to fully deployed in one pass.

**Changes to existing files**:

1. **`bootstrap.sh`** — Add `GH_TOKEN` passthrough (from Task 1):
   ```bash
   [ -n "$GH_TOKEN" ] && set_env "GH_TOKEN" "$GH_TOKEN"
   ```

2. **`.env.template`** — Add new variables:
   ```bash
   # GitHub token for automated SSH key registration (optional, only used during setup)
   # Use a fine-grained PAT with SSH key admin + repo read scope. Set short expiry.
   GH_TOKEN=

   # Deploy apps after setup (requires GH_TOKEN or pre-registered SSH key)
   DEPLOY_APPS_ON_SETUP=false
   ```

3. **`setup.sh`** — Add optional app deployment at the end:
   ```bash
   if [ "$DEPLOY_APPS_ON_SETUP" = "true" ]; then
       run_script "optional" "deploy-apps"
   fi
   ```
   This runs after Docker, Caddy, and the app directory are all set up.

4. **`scripts/verify.sh`** — Add checks for:
   - `apps.conf` exists and is readable
   - `/usr/local/bin/deploy-apps` is installed
   - Running containers match expected apps from manifest (when `DEPLOY_APPS_ON_SETUP=true`)

5. **`scripts/optional/app-directory.sh`** — Add:
   - Copy `apps.conf` to `/opt/apps/apps.conf` (or symlink to repo)
   - Install `deploy-apps` command to `/usr/local/bin/`

**New cloud-init example** (fully automated):

```bash
#!/bin/bash
export GITHUB_REPO="https://github.com/yourorg/infrastructure.git"
export GH_TOKEN="ghp_xxxxxxxxxxxx"
export SSH_PORT=42042
export OPERATOR_USER=operator
export SERVER_HOSTNAME=app-02
export DEPLOY_APPS_ON_SETUP=true
curl -fsSL https://raw.githubusercontent.com/yourorg/infrastructure/main/bootstrap.sh | bash
```

**Result**: Server boots, runs cloud-init, installs everything, registers SSH keys with GitHub, clones all apps, starts all containers, configures Caddy. You SSH in and everything is already running.

---

## Task 6: Update documentation

**Changes**:

- **`docs/CONFIGURATION.md`** — Add documentation for:
  - `GH_TOKEN` variable and how to create a fine-grained PAT
  - `DEPLOY_APPS_ON_SETUP` variable
  - `apps.conf` format and how to add/remove apps
  - `Caddyfile.snippet` convention for app repos
  - `deploy-apps` command usage and flags

- **`docs/TROUBLESHOOTING.md`** — Add entries for:
  - "App failed to clone" — check SSH key registration, verify repo access
  - "Caddy validation failed after deploy" — check snippet syntax
  - "App container won't start" — missing `.env`, check `docker compose logs`
  - "deploy-apps: command not found" — re-run `app-directory.sh` or check symlink

---

## Summary

| Step | Manual today | After this plan |
|------|-------------|-----------------|
| Create server | Hetzner console | Hetzner console (same) |
| SSH in, create key, add to GitHub | 5 min manual | Automated via `GH_TOKEN` |
| Clone infrastructure repo | Manual | Automated via cloud-init |
| Run setup | Manual `./setup.sh` | Automated via cloud-init |
| Switch to operator | Manual | SSH directly as operator |
| Clone each app | Manual x N apps | `deploy-apps` (one command) |
| Start each app | Manual x N apps | Handled by `deploy-apps` |
| Configure Caddy per app | Manual x N apps | Handled by `deploy-apps` |
| Reload Caddy | Manual | Handled by `deploy-apps` |

**Before**: ~10 manual steps, scales linearly with app count.
**After**: 1 cloud-init paste + 1 SSH command (or fully zero-touch with `DEPLOY_APPS_ON_SETUP=true`).
