# Security model

## Boundaries

| Layer | Control |
|-------|---------|
| Network | Hetzner Cloud Firewall (outside the VM): 80/443 from anywhere, 22 from your IP only. Containers publish no ports, except Caddy on 80/443. |
| SSH | Key-only, `PermitRootLogin no`, `AllowUsers admin`. |
| Admin | `admin` has `NOPASSWD` sudo (accepted trade-off: the SSH key plus the IP allowlist is the boundary). |
| CI runner | In the `vm-deploy` runner group, which only admits jobs from this repo's `app-pipeline.yml` on `main`. App repos and fork PRs cannot run their own jobs on it. Runs as `runner`: not in the docker group, no SSH keys. Its only sudo right is `/usr/local/bin/deploy`. |
| Prod gate | The `prod` environment in each app repo requires your approval and only accepts `main`. |
| `deploy` | Accepts only a known app, a listed env, and that app's own GHCR image pinned by digest. It runs only compose files from this repo. Registry tokens are used once, from a temporary Docker config. |
| Containers | Read-only rootfs, `cap_drop: ALL`, `no-new-privileges`, memory and pid limits, no host mounts, only the `edge` network. |
| Non-prod | Basic auth and `X-Robots-Tag: noindex` on every non-prod hostname. |
| Shared services | Started only by `infra-apply` (never by CI), pinned image versions, `cap_drop: ALL`, `no-new-privileges`. Admin paths (e.g. Keycloak `/admin` and the `master` realm) return 403 except from IPs in `/etc/infra/admin-ips`. Databases sit on internal networks with no route to Caddy. |
| Patching | `unattended-upgrades` with automatic reboot at 04:00 UTC. Containers restart automatically. |
| Secrets | Live only in `/etc/apps/**` (root, 0600) and your password manager. Never in git or in images. |

## What a compromised workflow can do

Anyone who can push to an app repo's `main` (only you) can get an image they
built deployed to dev and preprod, and to prod after approval. That means they can replace that app's
containers with arbitrary code. That code runs inside the sandbox above,
without host access, root capabilities or other apps' secrets.

Changing *how* containers run (mounts, capabilities, networks) requires a change
to this repo plus `sudo infra-apply` by the admin.

## Recovery

Apps have no backups by design. Everything is rebuilt from git, GHCR images, and
the env files kept in your password manager. The exception is Keycloak: users
and credentials are state, dumped nightly to `/var/backups/keycloak/` and
copied off-server by hand before a rebuild (see docs/KEYCLOAK.md). The server holds no GitHub
credentials: the infra repo is public and cloned over HTTPS, and registry tokens
are per-job. If in doubt, rebuild the server
(see README).
