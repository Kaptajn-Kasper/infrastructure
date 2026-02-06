# Configuration Reference

This document provides detailed information about all configuration options in the `.env` file.

## Quick Reference

| Variable | Default | Description |
|----------|---------|-------------|
| `SSH_PORT` | `22022` | Custom SSH port (1024-65535) |
| `OPERATOR_USER` | `operator` | Daily admin username |
| `GH_ACTIONS_USER` | `gh-actions` | CI/CD deployment username |
| `INSTALL_DOCKER` | `true` | Install Docker + Compose |
| `INSTALL_CADDY` | `true` | Install Caddy reverse proxy |
| `INSTALL_UNATTENDED_UPGRADES` | `true` | Enable auto security updates |
| `CREATE_APP_DIRECTORY` | `true` | Create /opt/apps structure |
| `CONFIGURE_SWAP` | `true` | Auto-configure swap |
| `CONFIGURE_TIMEZONE` | `true` | Set timezone to UTC |
| `SERVER_HOSTNAME` | *(empty)* | Set server hostname |
| `AUTO_REBOOT` | `false` | Auto-reboot after updates |
| `AUTO_REBOOT_TIME` | `02:00` | When to auto-reboot |

---

## SSH Configuration

### `SSH_PORT`

Custom SSH port to use instead of the default port 22.

- **Type**: Integer
- **Range**: 1024-65535
- **Default**: `22022`
- **Required**: Yes

Using a non-standard port reduces automated attack surface. Most bots only scan port 22.

```bash
SSH_PORT=22022
```

**Important**: After setup, connect using:
```bash
ssh -p 22022 user@server
```

Or add to `~/.ssh/config`:
```
Host myserver
    HostName your-server-ip
    Port 22022
    User operator
```

---

## User Accounts

### `OPERATOR_USER`

The daily admin user account. This replaces root for routine operations.

- **Type**: String (valid Unix username)
- **Pattern**: `^[a-z_][a-z0-9_-]*$`
- **Default**: `operator`
- **Required**: No (uses default if not set)

This user has:
- Full passwordless sudo access (`NOPASSWD: ALL`)
- Docker group membership (when Docker is installed)
- SSH access via root's authorized_keys (copied automatically)
- GitHub SSH key for repository access

```bash
OPERATOR_USER=operator
```

### `GH_ACTIONS_USER`

Dedicated user for GitHub Actions CI/CD deployments.

- **Type**: String (valid Unix username)
- **Pattern**: `^[a-z_][a-z0-9_-]*$`
- **Default**: None
- **Required**: Yes

This user has **limited** sudo access:
- `/usr/bin/docker` - for container management
- `/usr/bin/systemctl` - for service management

The setup generates an SSH key pair for this user. Add the private key to your GitHub repository secrets.

```bash
GH_ACTIONS_USER=gh-actions
```

---

## Optional Components

All optional components default to `true`. Set to `false` to skip installation.

### `INSTALL_DOCKER`

Install Docker Engine and Docker Compose plugin.

- **Type**: Boolean (`true` or `false`)
- **Default**: `true`

When enabled, installs:
- Docker CE from official Docker repository
- Docker Compose v2 plugin
- Docker Buildx plugin
- Configured logging (10MB max, 3 files)

```bash
INSTALL_DOCKER=true
```

### `INSTALL_CADDY`

Install Caddy web server / reverse proxy.

- **Type**: Boolean (`true` or `false`)
- **Default**: `true`

When enabled, installs:
- Caddy from official repository
- Creates default Caddyfile
- Opens ports 80 and 443 in firewall

Caddy provides:
- Automatic HTTPS via Let's Encrypt
- HTTP/2 and HTTP/3 support
- Easy reverse proxy configuration

```bash
INSTALL_CADDY=true
```

### `INSTALL_UNATTENDED_UPGRADES`

Enable automatic security updates.

- **Type**: Boolean (`true` or `false`)
- **Default**: `true`

When enabled:
- Installs unattended-upgrades package
- Configures automatic security updates
- Removes unused kernels and dependencies
- Logs to `/var/log/unattended-upgrades/`

```bash
INSTALL_UNATTENDED_UPGRADES=true
```

### `CREATE_APP_DIRECTORY`

Create `/opt/apps` directory structure for applications.

- **Type**: Boolean (`true` or `false`)
- **Default**: `true`

When enabled, creates:
```
/opt/apps/
├── data/       # Persistent data volumes
├── configs/    # Application configurations
├── logs/       # Application logs
├── backups/    # Backup storage
├── docker-compose.example.yml
└── README.md
```

Also creates a Docker network `caddy-network` for Caddy to communicate with containers.

```bash
CREATE_APP_DIRECTORY=true
```

---

## System Configuration

### `CONFIGURE_SWAP`

Automatically configure swap space based on available RAM.

- **Type**: Boolean (`true` or `false`)
- **Default**: `true`

Swap size formula:
- RAM ≤ 2GB: swap = RAM
- RAM ≤ 8GB: swap = RAM / 2
- RAM > 8GB: swap = 4GB

Also sets swappiness to 10 (only swap when necessary).

```bash
CONFIGURE_SWAP=true
```

### `CONFIGURE_TIMEZONE`

Set system timezone to UTC.

- **Type**: Boolean (`true` or `false`)
- **Default**: `true`

UTC is recommended for servers because:
- No daylight saving time changes
- Consistent log timestamps
- Easier coordination across regions

```bash
CONFIGURE_TIMEZONE=true
```

### `SERVER_HOSTNAME`

Set the server's hostname.

- **Type**: String (valid hostname)
- **Pattern**: `^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$`
- **Default**: *(empty - hostname not changed)*
- **Required**: No

Leave empty to keep the existing hostname.

```bash
SERVER_HOSTNAME=web01
```

---

## Advanced Options

### `AUTO_REBOOT`

Automatically reboot the server when required by updates.

- **Type**: Boolean (`true` or `false`)
- **Default**: `false`

Only applies when `INSTALL_UNATTENDED_UPGRADES=true`.

Some updates (kernel, glibc) require a reboot. Enable this for fully automated maintenance, or leave disabled to control reboot timing manually.

```bash
AUTO_REBOOT=false
```

### `AUTO_REBOOT_TIME`

Time to perform automatic reboot (24-hour format).

- **Type**: String (HH:MM format)
- **Default**: `02:00`

Only applies when `AUTO_REBOOT=true`.

Choose a low-traffic time for your application.

```bash
AUTO_REBOOT_TIME=02:00
```

---

## App Deployment

### `apps.conf`

The app manifest file in the repository root defines which applications to deploy on this server.

**Format**: One app per line — `<github-org/repo> <local-directory-name> [compose-file]`

```bash
# apps.conf
Kaptajn-Kasper/map-guesser-game  map-guesser-game  docker-compose.prod.yml
Kaptajn-Kasper/api-service       api
```

- Lines starting with `#` are comments
- Blank lines are ignored
- The local directory name maps to `/opt/apps/<name>`
- The compose file column is optional — if omitted, auto-detects from: `docker-compose.yml`, `compose.yml`, `docker-compose.prod.yml`
- Comment out an app line to skip it during deployment

### `deploy-apps` command

Installed to `/usr/local/bin/deploy-apps` by the app-directory setup. Reads `apps.conf` and handles cloning, container startup, and Caddy configuration for all apps.

```bash
deploy-apps                      # Deploy all apps from manifest
deploy-apps --app <name>         # Deploy a single app by directory name
deploy-apps --pull-only          # Update repos without restarting containers
deploy-apps --no-caddy           # Skip Caddy snippet configuration and reload
deploy-apps --app <name> --env dev --branch feature/x
                                 # Deploy a branch to an isolated environment
deploy-apps --app <name> --env dev --teardown
                                 # Tear down an environment
```

| Flag | Description |
|------|-------------|
| `--app <name>` | Deploy a single app by its directory name |
| `--pull-only` | Update repos without restarting containers |
| `--no-caddy` | Skip Caddy snippet configuration and reload |
| `--env <name>` | Deploy to a named environment (e.g. `dev`, `staging`) |
| `--branch <branch>` | Git branch to clone/checkout (default: repo default branch) |
| `--teardown` | Tear down the specified `--env` environment |

Deployment logs are written to `/opt/apps/logs/deploy-<timestamp>.log`.

### Environment deployments (`--env`)

The `--env` flag deploys an app into a completely isolated environment alongside prod. This lets you test feature branches on the real server without touching the production deployment.

**What `--env dev` changes:**

| Aspect | Prod (no `--env`) | Dev (`--env dev`) |
|--------|-------------------|-------------------|
| Clone directory | `/opt/apps/map-guesser-game/` | `/opt/apps/map-guesser-game-dev/` |
| Config directory | `/opt/apps/configs/map-guesser-game/` | `/opt/apps/configs/map-guesser-game-dev/` |
| Container name | `map-guesser-game-app-prod` (from compose) | `map-guesser-game-app-dev` (auto-generated override) |
| Caddy snippet | `Caddyfile.snippet` → `map-guesser-game.caddy` | `Caddyfile.snippet.dev` → `map-guesser-game-dev.caddy` |
| Git branch | default branch | specified via `--branch` |

The dev environment reuses the same `docker-compose.prod.yml` and `Dockerfile.prod` — it's a production-quality build of a different branch, not a live-reload dev server.

**Validation rules:**

- `--env prod` is rejected — prod is the default no-flag behavior
- `--teardown` requires `--env`
- Environment names must match `^[a-z][a-z0-9-]*$`

**How container name overrides work:**

When `--env` is set, the script reads the base compose file, finds all `container_name:` entries, replaces `-prod` suffixes with `-<env>` (or appends `-<env>` if no `-prod` suffix), and writes a `.compose.env-override.yml` alongside the compose file. Both files are passed to `docker compose` via `-f` flags. This file is gitignored.

### `Caddyfile.snippet` convention

Each app repo can include a `Caddyfile.snippet` at its root to define its own reverse proxy configuration. During deployment, the snippet is copied to `/opt/apps/caddy/conf.d/<app-name>.caddy` and Caddy is reloaded.

Example `Caddyfile.snippet`:

```caddy
myapp.example.com {
    reverse_proxy myapp:3000
}
```

**Environment-specific snippets:** For env deployments, the script looks for `Caddyfile.snippet.<env>` instead. For example, `Caddyfile.snippet.dev` is used when deploying with `--env dev`. This file must be added to the app repo before deploying that environment.

Example `Caddyfile.snippet.dev`:

```caddy
dev.myapp.example.com {
    reverse_proxy myapp-dev:3000
}
```

The main Caddyfile imports all snippets via `import /opt/apps/caddy/conf.d/*.caddy`. Apps without a matching snippet are skipped — you can always add Caddy config manually later.

**DNS prerequisite:** Add an A record for the dev subdomain (e.g. `dev.myapp.example.com`) pointing to the server IP before deploying a new environment. A wildcard record (`*.myapp.example.com`) covers all future environments.

### Config injection

App secrets and environment files are managed through `/opt/apps/configs/<app>/`. This directory persists across deploys and git operations.

**How it works**:

1. **First deploy**: The deploy script scans the app for example/template files (`.env.example`, `*.example.*`, `*.template.*`), copies them into `/opt/apps/configs/<app>/` with the example part stripped from the filename, and stops before building. You edit the files with real values.

2. **Every deploy after that**: The script copies files from `/opt/apps/configs/<app>/` into the app directory (preserving relative paths) before building. No manual steps needed.

**Config directory structure** mirrors the app directory:

```
/opt/apps/configs/map-guesser-game/
├── .env                                    → /opt/apps/map-guesser-game/.env
└── src/environments/environment.prod.ts    → /opt/apps/map-guesser-game/src/environments/environment.prod.ts
```

Environment deployments get their own config directory (e.g. `/opt/apps/configs/map-guesser-game-dev/`). On first deploy, configs are seeded from the app's example files — you can copy values from the prod config directory if appropriate.

**Adding config files manually**: You can put any file into the configs directory at the appropriate relative path. The deploy script will copy it into the app on every deploy. This is useful for files that don't have a corresponding example file in the repo.

### Deployment workflows

#### Deploy prod (default)

```bash
deploy-apps --app map-guesser-game
```

Pulls the default branch, builds, and deploys. No `--env` flag means prod.

#### Deploy a feature branch to dev

```bash
# First run — seeds configs, stops before building:
deploy-apps --app map-guesser-game --env dev --branch feature/new-maps

# Edit configs with real values (or copy from prod):
cp /opt/apps/configs/map-guesser-game/src/environments/environment.prod.ts \
   /opt/apps/configs/map-guesser-game-dev/src/environments/environment.prod.ts
cp /opt/apps/configs/map-guesser-game/src/environments/environment.ts \
   /opt/apps/configs/map-guesser-game-dev/src/environments/environment.ts

# Second run — builds and starts the dev container:
deploy-apps --app map-guesser-game --env dev --branch feature/new-maps
```

#### Update dev after pushing new commits

```bash
deploy-apps --app map-guesser-game --env dev --branch feature/new-maps
```

Fetches, checks out the branch, pulls, rebuilds, and restarts.

#### Switch dev to a different branch

```bash
deploy-apps --app map-guesser-game --env dev --branch feature/other-thing
```

The script runs `git fetch && git checkout <branch> && git pull` on the existing clone.

#### Deploy a hotfix to prod from a specific branch

```bash
deploy-apps --app map-guesser-game --branch hotfix/urgent-fix
```

`--branch` works without `--env` — this deploys the branch directly to prod.

#### Tear down dev

```bash
deploy-apps --app map-guesser-game --env dev --teardown
```

Stops containers, removes the clone directory and Caddy snippet, and reloads Caddy. The config directory (`/opt/apps/configs/map-guesser-game-dev/`) is preserved to avoid accidental secret loss — remove it manually if no longer needed.

### Adding a new app for env deployments

To support `--env` deployments for a new app:

1. **Add a `Caddyfile.snippet.<env>` to the app repo** with the subdomain routing to the env container name. For example, `Caddyfile.snippet.dev`:
   ```caddy
   dev.myapp.example.com {
       reverse_proxy myapp-container-dev:3000
   }
   ```

2. **Add `.compose.env-override.yml` to the app's `.gitignore`** — this file is auto-generated by the deploy script.

3. **Add a DNS record** for the env subdomain pointing to the server IP.

4. **Deploy**:
   ```bash
   deploy-apps --app myapp --env dev --branch my-feature-branch
   ```

---

## Example Configurations

### Minimal Server (No Docker/Caddy)

```bash
SSH_PORT=22022
OPERATOR_USER=admin
GH_ACTIONS_USER=deploy
INSTALL_DOCKER=false
INSTALL_CADDY=false
CREATE_APP_DIRECTORY=false
```

### Production Web Server

```bash
SSH_PORT=22022
OPERATOR_USER=operator
GH_ACTIONS_USER=gh-actions
INSTALL_DOCKER=true
INSTALL_CADDY=true
INSTALL_UNATTENDED_UPGRADES=true
CREATE_APP_DIRECTORY=true
CONFIGURE_SWAP=true
CONFIGURE_TIMEZONE=true
SERVER_HOSTNAME=web-prod-01
AUTO_REBOOT=true
AUTO_REBOOT_TIME=03:00
```

### Development/Staging Server

```bash
SSH_PORT=2222
OPERATOR_USER=dev
GH_ACTIONS_USER=ci
INSTALL_DOCKER=true
INSTALL_CADDY=true
INSTALL_UNATTENDED_UPGRADES=true
CREATE_APP_DIRECTORY=true
SERVER_HOSTNAME=staging
AUTO_REBOOT=false
```

---

## Validation

Configuration is validated before setup runs. Common validation errors:

| Error | Cause | Fix |
|-------|-------|-----|
| `SSH_PORT must be between 1024 and 65535` | Port out of range | Use port 1024-65535 |
| `OPERATOR_USER must match pattern` | Invalid username | Use lowercase, no special chars |
| `must be 'true' or 'false'` | Invalid boolean | Use exactly `true` or `false` |
| `cannot be the same` | Duplicate usernames | Use different usernames |

Run validation manually:
```bash
sudo ./scripts/core/00-validate-config.sh
```
