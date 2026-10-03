# Adding an app

An app is any repo with a Dockerfile that serves HTTP on a fixed port as a
non-root user and only writes to `/tmp` (the container runs with a read-only
root filesystem).

## 1. In the app repo

`.github/workflows/pipeline.yml`:

```yaml
name: pipeline
on:
  push:
    branches: [main]
  workflow_dispatch:   # run from any branch → deploys that branch to dev
permissions:
  contents: read
  packages: write
jobs:
  pipeline:
    uses: Kaptajn-Kasper/infrastructure/.github/workflows/app-pipeline.yml@main
    with:
      app: my-app
```

In the repo settings, create the environment `prod` with yourself as required
reviewer and deployment branches limited to `main`. Give `preprod` the same
branch limit. Without a required reviewer, prod deploys automatically.

In org settings, add the repo to the `vm-deploy` runner group's repository list.

Use runtime configuration (env vars from `/etc/apps/<app>/<env>.env`) rather
than build-time config, so the same image can run in every environment.

## 2. In this repo

Copy `apps/map-guesser-game/` to `apps/my-app/` and adjust:

- `app.conf`: `IMAGE` (`ghcr.io/kaptajn-kasper/<repo-name>`), `HOST`, `PORT`, `ENVS`
- `compose.yml`: the env file path, the health check URL/port, the network alias,
  and limits

If the app needs a database, add it as a second service on an internal
network. Only the web service joins `edge`. Use a named volume for its data.

Merge, then on the server run `sudo infra-apply`.

## 3. On the server

Fill in `/etc/apps/my-app/{dev,preprod,prod}.env`. `infra-apply` creates them
empty.

## 4. First deploy

Push to `main` in the app repo. Dev and preprod deploy automatically. Approve
the waiting prod job in the Actions run when preprod looks good.

The wildcard DNS record already covers `<host>.kaptajnkasper.net` and
`<host>-<env>.kaptajnkasper.net`.
