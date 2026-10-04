# Keycloak (shared identity provider)

One Keycloak instance at `https://auth.kaptajnkasper.net`, shared by all apps,
with one realm per environment:

| Realm | Used by | Issuer |
|-------|---------|--------|
| `dev` | `<host>-dev.kaptajnkasper.net` | `https://auth.kaptajnkasper.net/realms/dev` |
| `preprod` | `<host>-preprod.kaptajnkasper.net` | `https://auth.kaptajnkasper.net/realms/preprod` |
| `prod` | `<host>.kaptajnkasper.net` | `https://auth.kaptajnkasper.net/realms/prod` |

Test users and tokens never mix with prod, but only one Keycloak (about 1 GB of
RAM) runs.

## Files

| Path | Purpose |
|------|---------|
| `services/keycloak/compose.yml` | Keycloak plus its own Postgres (on a private network) |
| `services/keycloak/service.conf` | Caddy routing and the admin paths to restrict |
| `services/keycloak/realms/*.json` | Realm definitions, imported on startup **only if the realm does not exist yet** |
| `services/keycloak/setup.sh` | Generates secrets and installs the backup timer (run by `infra-apply`) |
| `bin/keycloak-backup` | Nightly `pg_dump` to `/var/backups/keycloak` (keeps 14) |
| `/etc/infra/keycloak.env` | Admin and database passwords (root, 0600, generated) |
| `/etc/infra/admin-ips` | IPs allowed to reach the admin console |

## First-time setup

1. `sudo infra-apply` starts Keycloak. The first run prints a temporary
   `bootstrap-admin` password. It is also in `/etc/infra/keycloak.env`.
2. Add your **IPv4** address to `/etc/infra/admin-ips`, then run
   `sudo infra-apply` again. Until then `/admin` and the `master` realm return
   403 for everyone.
3. Open https://auth.kaptajnkasper.net/admin, log in as `bootstrap-admin`,
   create your own admin user in the `master` realm with the `admin` role,
   log in as that user, and delete `bootstrap-admin`.

## Adding an app as a client

Create the client in each realm the app uses. The quickest way is the admin
console: realm → Clients → Create client.

- **Client type:** OpenID Connect. For a browser-only SPA like an Angular app,
  turn *Client authentication* off and keep *Standard flow* (PKCE) on.
- **Valid redirect URIs:** e.g. `https://map-guesser-dev.kaptajnkasper.net/*`
  in `dev`, and `http://localhost:4200/*` too if you develop locally against
  `dev`.
- **Web origins:** `+` (same as redirect URIs).

To keep clients reproducible on a rebuild, add them to the realm's JSON under
`"clients"` in the same PR as the app change. Keycloak only imports a realm
that doesn't exist yet, so on a running server also create the client in the
console. Alternatively, export the realm (realm settings → Action → Partial
export, without secrets) and commit the clients section.

The app gets its runtime config from `/etc/apps/<app>/<env>.env`, for example:

```
OIDC_ISSUER=https://auth.kaptajnkasper.net/realms/dev
OIDC_CLIENT_ID=map-guesser-game
```

Apps reach Keycloak through its public URL (browser redirects and token
validation alike), because the token issuer must match that URL.

## Backups and restore

Keycloak holds state git can't regenerate (users, credentials, sessions), so the
"no backups" rule does not cover it. A nightly dump is written at 03:30 UTC to
`/var/backups/keycloak/`. Those dumps are on the same disk, so **copy the latest one
off the server before a rebuild**:

```bash
sudo keycloak-backup                                   # take a fresh dump
scp admin@<server>:/var/backups/keycloak/keycloak-*.sql.gz .
```

Restore onto a fresh server, after `infra-apply` has started Keycloak once:

```bash
cd /srv/infra/services/keycloak
sudo docker compose -p keycloak stop keycloak
gunzip -c keycloak-<date>.sql.gz | sudo docker compose -p keycloak exec -T db psql -U keycloak keycloak
sudo docker compose -p keycloak start keycloak
```

## Upgrades

Keycloak has no LTS line; only the latest release gets security fixes. To
upgrade:

1. Read the release notes.
2. Bump the image tag in `services/keycloak/compose.yml` in a PR and merge it.
3. On the server, run `sudo keycloak-backup && sudo infra-apply`.

The upgrade hits every app and environment at once.
