#!/usr/bin/env bash
# Sends one JSON header line (+ the gzipped context for deploys) to the VM's
# deploy script over SSH through Cloudflare Access. Secrets only travel on stdin.
set -euo pipefail

missing=""
[ -n "$VM_SSH_KEY" ] || missing="$missing ssh_key"
[ -n "$TUNNEL_SERVICE_TOKEN_ID" ] || missing="$missing cf_access_client_id"
[ -n "$TUNNEL_SERVICE_TOKEN_SECRET" ] || missing="$missing cf_access_client_secret"
if [ -n "$missing" ]; then
  echo "::error::empty input(s):$missing. Are the secrets set on this repo (or its org/environment)? Forks never get secrets."
  exit 1
fi

tmp="$(mktemp -d "$RUNNER_TEMP/vm-deploy.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
umask 077
printf '%s\n' "$VM_SSH_KEY" > "$tmp/key"
printf '%s\n' "$VM_KNOWN_HOSTS" > "$tmp/known_hosts"

[ "$IN_ACTION" = status ] || [ -n "$IN_SUBDOMAIN" ] || { echo "::error::subdomain is required"; exit 1; }

header="$(jq -cn \
  --arg action "$IN_ACTION" --arg subdomain "$IN_SUBDOMAIN" --arg domain "$IN_DOMAIN" \
  --arg repo "$REPO" --arg git_sha "$SHA" \
  --arg dockerfile "$IN_DOCKERFILE" --arg compose_file "$IN_COMPOSE_FILE" --arg service "$IN_SERVICE" \
  --arg port "$IN_PORT" --arg build_args "$IN_BUILD_ARGS" --arg env "$IN_ENV" --arg app_env "$IN_APP_ENV" \
  --arg data_dir "$IN_DATA_DIR" --arg memory "$IN_MEMORY" --arg cpus "$IN_CPUS" --arg gpu "$IN_GPU" \
  --arg gpu_memory_gb "$IN_GPU_MEMORY_GB" --arg health_path "$IN_HEALTH_PATH" \
  --arg health_timeout "$IN_HEALTH_TIMEOUT" --arg ttl_hours "$IN_TTL_HOURS" \
  --arg purge_data "$IN_PURGE_DATA" --arg lines "$IN_LINES" --arg since "$IN_SINCE" \
  --arg log_service "$IN_LOG_SERVICE" \
  '{action: $action, subdomain: $subdomain, domain: $domain, repo: $repo, git_sha: $git_sha}
   + (if $action == "deploy" then {dockerfile: $dockerfile, compose_file: $compose_file, service: $service,
        port: $port, build_args: $build_args, env: $env, app_env: $app_env, data_dir: $data_dir,
        memory: $memory, cpus: $cpus, gpu: $gpu, gpu_memory_gb: $gpu_memory_gb,
        health_path: $health_path, health_timeout: $health_timeout, ttl_hours: $ttl_hours}
      elif $action == "destroy" then {purge_data: $purge_data}
      elif $action == "logs" then {lines: $lines, since: $since, service: $log_service}
      else {} end)')"

send() {
  printf '%s\n' "$header"
  if [ "$IN_ACTION" = deploy ]; then
    [ -d "$IN_CONTEXT" ] || { echo "::error::context directory $IN_CONTEXT not found" >&2; return 1; }
    tar -czf - -C "$IN_CONTEXT" --exclude=./.git .
  fi
}

# cloudflared reads TUNNEL_SERVICE_TOKEN_ID / TUNNEL_SERVICE_TOKEN_SECRET from the environment.
set +e
send | ssh -T -i "$tmp/key" \
  -o IdentitiesOnly=yes -o BatchMode=yes \
  -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$tmp/known_hosts" \
  -o ServerAliveInterval=30 -o ServerAliveCountMax=10 \
  -o ProxyCommand="cloudflared access ssh --hostname %h" \
  "deployer@$VM_HOST" vm-deploy > "$tmp/out"
status=$?
set -e

result="$(tail -n 1 "$tmp/out" || true)"
if ! jq -e . >/dev/null 2>&1 <<<"$result"; then
  echo "::error::no result from the VM (ssh exit $status). Check the service token, your key and that you are onboarded."
  exit 1
fi
echo "result=$result" >> "$GITHUB_OUTPUT"
if [ "$(jq -r .ok <<<"$result")" != true ]; then
  echo "::error::$(jq -r .error <<<"$result")"
  exit 1
fi

url="$(jq -r '.url // empty' <<<"$result")"
[ -z "$url" ] || echo "url=$url" >> "$GITHUB_OUTPUT"
{
  case "$IN_ACTION" in
    deploy|rollback)
      echo "### Deployed $(jq -r .hostname <<<"$result")"
      echo
      echo "| | |"
      echo "|---|---|"
      echo "| URL | $url |"
      echo "| Commit | \`$(jq -r .git_sha <<<"$result")\` |"
      echo "| Release | \`$(jq -r .tag <<<"$result")\` |"
      echo
      echo "Logs in Grafana: \`{app=\"$(jq -r .hostname <<<"$result")\"}\`"
      ;;
    destroy)
      echo "### Destroyed $(jq -r .hostname <<<"$result") (data purged: $(jq -r .purged <<<"$result"))"
      ;;
    status)
      echo "### Your apps"
      echo
      echo "| URL | State | Memory | CPUs | GPU GB | TTL h | Repo |"
      echo "|---|---|---|---|---|---|---|"
      jq -r '.apps[] | "| \(.url) | \(.state) | \(.memory) | \(.cpus) | \(.gpu_memory_gb // "-") | \(.ttl_hours // "-") | \(.repo) |"' <<<"$result"
      ;;
  esac
} >> "$GITHUB_STEP_SUMMARY"
