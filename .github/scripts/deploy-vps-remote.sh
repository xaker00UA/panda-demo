#!/usr/bin/env bash
set -euo pipefail
cd "$VPS_PATH"

# GNU timeout is available on the Linux VPS; fail before changing the release.
command -v timeout >/dev/null
previous_commit=$(git rev-parse HEAD)
release_dir=$(mktemp -d)
docker_config="$release_dir/docker"
mkdir -m 700 "$docker_config"
release_started=false
has_previous=false

compose=(docker --config "$docker_config" compose --project-directory "$VPS_PATH"
  --env-file "$release_dir/new.env" -f "$VPS_PATH/docker-compose.yaml")
rollback_compose=(docker --config "$docker_config" compose --project-directory "$VPS_PATH"
  -f "$release_dir/previous.yaml" -f "$release_dir/images.yaml")

# A successful deploy must survive the whole window, including after first readiness.
# The same check verifies the restored release. Older releases may lack healthchecks.
monitor_release() {
  local deadline=$1 legacy=${2:-false}
  local healthy_since=-1 fingerprint='' previous_fingerprint=''
  local all_healthy=false service container info status health restarts started remaining
  while (( SECONDS < deadline )); do
    all_healthy=true
    fingerprint=''
    for service in panda-app nginx; do
      remaining=$((deadline - SECONDS))
      (( remaining > 0 )) || { all_healthy=false; break; }
      container=$(timeout "$remaining" "${active_compose[@]}" ps --all --quiet "$service") || return 1
      if [[ -z "$container" ]]; then
        echo "Missing container: $service" >&2
        return 1
      fi
      remaining=$((deadline - SECONDS))
      (( remaining > 0 )) || { all_healthy=false; break; }
      info=$(timeout "$remaining" docker --config "$docker_config" inspect --format \
        '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}|{{.RestartCount}}|{{.State.StartedAt}}' \
        "$container") || return 1
      IFS='|' read -r status health restarts started <<< "$info"
      fingerprint+="$container|$restarts|$started;"
      if (( restarts >= 3 )); then
        echo "Restart loop: $service restarted $restarts times" >&2
        return 1
      fi
      case "$status" in
        exited|dead|removing)
          echo "Container $service is $status" >&2
          return 1
          ;;
        running) ;;
        *) all_healthy=false; continue ;;
      esac
      if [[ "$health" == none && "$legacy" == true ]]; then
        # Compatibility with the release running before /healthz was introduced.
        remaining=$((deadline - SECONDS))
        (( remaining > 0 )) || { all_healthy=false; break; }
        if [[ "$service" == panda-app ]]; then
          timeout "$remaining" docker --config "$docker_config" exec "$container" python -c \
            "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/', timeout=2)" \
            >/dev/null 2>&1 || all_healthy=false
        else
          timeout "$remaining" docker --config "$docker_config" exec "$container" \
            curl --fail --silent --max-time 2 http://127.0.0.1/ >/dev/null 2>&1 || all_healthy=false
        fi
      elif [[ "$health" != healthy ]]; then
        all_healthy=false
      fi
    done
    if [[ "$all_healthy" == true ]]; then
      if (( healthy_since < 0 )) || [[ "$fingerprint" != "$previous_fingerprint" ]]; then
        healthy_since=$SECONDS
      fi
    else
      healthy_since=-1
    fi
    previous_fingerprint=$fingerprint
    remaining=$((deadline - SECONDS))
    if (( remaining > 0 )); then
      if (( remaining > 2 )); then sleep 2; else sleep "$remaining"; fi
    fi
  done
  if [[ "$all_healthy" == true ]] && (( healthy_since >= 0 && SECONDS - healthy_since >= 10 )); then
    return 0
  fi
  echo 'Release did not stay healthy for the last 10 seconds of the 60-second window' >&2
  return 1
}

rollback() {
  git checkout --detach "$previous_commit" || return 1
  if [[ "$has_previous" != true ]]; then
    echo 'First deployment: no previous release to restore; removing failed containers' >&2
    "${compose[@]}" down || return 1
    return 0
  fi
  echo 'Rolling back to the previous configuration and local image IDs' >&2
  active_compose=("${rollback_compose[@]}")
  local deadline=$((SECONDS + 60))
  timeout 60 "${active_compose[@]}" up -d --no-build --pull never --force-recreate || return 1
  monitor_release "$deadline" true || return 1
  echo 'Previous release restored and healthy' >&2
}

finish() {
  local result=$? keep_backup=false
  trap - EXIT
  if (( result != 0 )); then
    if [[ "$release_started" == true ]]; then
      "${compose[@]}" ps --all >&2 || true
      "${compose[@]}" logs --no-color --tail 100 >&2 || true
      if ! rollback; then
        echo "ROLLBACK FAILED; saved configuration: $release_dir" >&2
        keep_backup=true
      fi
    else
      # Pull/authentication/configuration errors must leave the live containers alone.
      git checkout --detach "$previous_commit" || true
    fi
  fi
  rm -rf "$docker_config"
  if [[ "$keep_backup" != true ]]; then rm -rf "$release_dir"; fi
  exit "$result"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

# Render the OLD configuration before updating Git. The new exported image/version
# must not override the old .env.deploy while taking this snapshot.
previous_compose=(env -u APP_IMAGE -u GIT_SHORT_HASH -u GIT_TAG
  docker --config "$docker_config" compose --project-directory "$VPS_PATH"
  -f "$VPS_PATH/docker-compose.yaml")
if [[ -f .env.deploy ]]; then previous_compose+=(--env-file .env.deploy); fi
"${previous_compose[@]}" config > "$release_dir/previous.yaml"
printf 'services:\n' > "$release_dir/images.yaml"
for service in panda-app nginx; do
  container=$("${previous_compose[@]}" ps --all --quiet "$service")
  if [[ -n "$container" ]]; then
    has_previous=true
    image=$(docker --config "$docker_config" inspect --format '{{.Image}}' "$container")
    # Pin IDs, including nginx:latest, so a moved tag cannot change the rollback.
    printf '  %s:\n    image: %s\n' "$service" "$image" >> "$release_dir/images.yaml"
  fi
done

git fetch origin "+refs/heads/$DEPLOY_BRANCH:refs/remotes/origin/$DEPLOY_BRANCH"
git switch "$DEPLOY_BRANCH"
git pull --ff-only origin "$DEPLOY_BRANCH"
# Pin Compose configuration to the commit that produced the published image.
git checkout --detach "$DEPLOY_COMMIT"

printf '%s' "$GHCR_TOKEN" | docker --config "$docker_config" login ghcr.io \
  --username "$GHCR_USER" --password-stdin
unset GHCR_TOKEN
printf 'APP_IMAGE=%s\nGIT_SHORT_HASH=%s\nGIT_TAG=%s\n' \
  "$APP_IMAGE" "$GIT_SHORT_HASH" "$GIT_TAG" > "$release_dir/new.env"

# Pull first: neither the running release nor .env.deploy changes on pull failure.
"${compose[@]}" pull
active_compose=("${compose[@]}")
deadline=$((SECONDS + 60))
release_started=true
# Recreate nginx too: it must resolve the new application's container address.
timeout 60 "${compose[@]}" up -d --no-build --pull never --force-recreate
monitor_release "$deadline"
mv "$release_dir/new.env" .env.deploy
echo 'Deployment healthy; saved .env.deploy'
