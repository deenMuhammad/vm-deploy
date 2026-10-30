# vm-deploy

Deploy any repo to **`<subdomain>.oson.ai`** or **`<subdomain>.bosvor.app`** on the team VM from GitHub Actions.

```yaml
- uses: actions/checkout@v4
- id: deploy
  uses: deenMuhammad/vm-deploy@v1
  with:
    ssh_key: ${{ secrets.VM_DEPLOY_KEY }}
    cf_access_client_id: ${{ secrets.CF_ACCESS_CLIENT_ID }}
    cf_access_client_secret: ${{ secrets.CF_ACCESS_CLIENT_SECRET }}
    subdomain: myapp
    domain: bosvor.app
    port: "3000"
    app_env: ${{ secrets.APP_ENV }}
```

> **Every deployed app is public on the internet.** There is no login in front of it, so add your own auth for anything that isn't meant for everyone.

The action sends your build context to the VM over SSH, using Cloudflare Access to get through. The VM builds the image, starts the app, waits until it is healthy and returns the URL. If the new version fails its health check, the previous one is put back automatically.

## Onboarding (once per developer)

1. Create a deploy key:
   ```sh
   ssh-keygen -t ed25519 -f vm-deploy -N "" -C "<your-name>"
   ```
2. Send **`vm-deploy.pub`** to the admin, who adds you to the VM. The private key never leaves you.
3. In each repo (or as org secrets), add:
   | Secret | Value |
   |---|---|
   | `VM_DEPLOY_KEY` | contents of `vm-deploy` (the private key) |
   | `CF_ACCESS_CLIENT_ID` | from the admin (shared by the team) |
   | `CF_ACCESS_CLIENT_SECRET` | from the admin (shared by the team) |
   | `APP_ENV` | optional: your app's secret `.env` (`KEY=VALUE` lines) |
4. Copy a workflow from [`examples/`](examples).

## Two ways to deploy

- **Dockerfile** (the default): `Dockerfile` in `context`, one container listening on `port`. Use `data_dir` for a persistent folder.
- **Compose**: set `compose_file` and `service` (the service that gets the subdomain). Other services, such as postgres, redis or workers, stay private to your app. Data in **named volumes** survives redeploys.

Compose restrictions (they protect the shared VM):
- no bind mounts, `privileged`, host networking, devices, `cap_add`, `sysctls` or the Docker socket;
- one replica per service;
- no `include` or `extends` from another file.

`ports:` and `container_name` are dropped. Apps never bind host ports; routing goes by hostname.

## Inputs

| Input | Default | |
|---|---|---|
| `action` | `deploy` | `deploy`, `destroy`, `rollback`, `logs`, `status` |
| `subdomain` | | One DNS label (`a-z0-9-`, up to 40 characters). Names that already have their own DNS record (for example `api.oson.ai`) and reserved names are refused. The first deploy claims the name for you. `@` deploys to the bare domain (only `bosvor.app`, and only if the admin enabled it for you). |
| `domain` | `bosvor.app` | `oson.ai` or `bosvor.app` |
| `context` | `.` | Directory sent to the VM. Up to 500 MB compressed; `.git` is excluded and `.dockerignore` applies during the build. |
| `dockerfile` | `Dockerfile` | Relative to `context` |
| `compose_file` / `service` | | Compose mode |
| `port` | `8080` | Port the public service listens on |
| `build_args` | | `KEY=VALUE` lines (not secret), e.g. `NEXT_PUBLIC_API_URL=...` |
| `env` | | `KEY=VALUE` lines (not secret) |
| `app_env` | | Secret `KEY=VALUE` lines. **Replaced on every deploy**: remove a key in GitHub and it disappears from the app. Also usable as `${VAR}` in your compose file. |
| `data_dir` | | Dockerfile mode: persistent volume mounted at this path |
| `memory` / `cpus` | `512m` / `0.5` | Limits for the public service. Other compose services use their own `deploy.resources.limits`, or the defaults. |
| `gpu` / `gpu_memory_gb` | | GPU access (if your account is enabled) plus your VRAM budget |
| `health_path` / `health_timeout` | `/` / `120` | Healthy means the image's `HEALTHCHECK` passes, or, without one, the path answers below 500 |
| `ttl_hours` | | Destroy automatically after N hours. TTL apps don't count toward the quota. |
| `purge_data` | `false` | `destroy`: also delete the app's volumes. Otherwise they are kept for 7 days. |
| `lines` / `since` / `log_service` | `200` | `logs` options |

Outputs: `url`, `logs_url` (Grafana, from this deploy on) and `result` (raw JSON). The job summary shows the URL, release and a logs link.

Every app gets these environment variables: `APP_HOST`, `APP_URL`, `PORT`, `GIT_SHA` and `DEPLOYED_BY` (plus `GPU_MEMORY_GB` and `GPU_MEMORY_FRACTION` for GPU apps).

## Limits

| | Default |
|---|---|
| Per container | 512 MB, 0.5 CPU, 512 processes (raise with `memory`/`cpus` or compose limits) |
| Per developer, all apps together | 6 GB, 6 CPUs |
| Apps per developer | 5 without `ttl_hours` (previews with a TTL are free) |
| Whole VM | 20 GB for all apps |
| GPU | one RTX 3090 Ti; the `gpu_memory_gb` of all running GPU apps must fit in 22 GB |

A deploy over a limit is refused, and the message shows what you are already using. Ask the admin to raise a limit.

Redeploys restart the containers, so expect a few seconds of downtime. The VM keeps the last two releases (`action: rollback`). **There are no backups.** This is a dev environment.

## Apps calling each other

All public services share one network. Call another app directly at `http://<subdomain>.<domain>:<its port>`, or through its public `https://` URL.

## Logs

- Quick: `action: logs` (see [`examples/ops.yml`](examples/ops.yml)).
- Grafana Cloud (ask the admin for access): Explore → Loki → `{app="myapp.bosvor.app"}`, or `{owner="<you>"}` for all your apps.

## Troubleshooting

| Error | Meaning |
|---|---|
| `no result from the VM` | Wrong service token or key, or you aren't onboarded yet |
| `owned by <name>` | Someone else claimed that subdomain |
| `already has its own DNS record` | Production name; pick another |
| `over your ceiling` / `app quota reached` | Destroy an app, use `ttl_hours`, or ask the admin |
| `did not become healthy` | See the log tail in the job. Check `port` and `health_path`. The previous version is still running. |
