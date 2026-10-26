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
  local services=(panda-app nginx) healthy_since=(-1 -1) last_checked=(-1 -1)
  local container_ids=('' '') fingerprints=('' '') previous_states=('' '')
  local index service container info status health restarts started remaining result
  local fingerprint state healthy stable age failed=false
  while (( SECONDS < deadline )); do
    for index in "${!services[@]}"; do
      service=${services[$index]}
      remaining=$((deadline - SECONDS))
      # Ending the observation window is not a failed healthcheck. Keep the last
      # confirmed state if the deadline falls between queries or interrupts one.
      (( remaining > 0 )) || break 2
      if container=$(timeout "$remaining" "${active_compose[@]}" ps --all --quiet "$service"); then
        :
      else
        result=$?
        if (( result == 124 && SECONDS >= deadline )); then break 2; fi
        echo "Failed to find container for $service (exit $result)" >&2
        return 1
      fi
      if [[ -z "$container" ]]; then
        echo "Missing container: $service" >&2
        return 1
      fi
      if [[ "$container" != "${container_ids[$index]}" ]]; then
        healthy_since[$index]=-1
        container_ids[$index]=$container
      fi
      remaining=$((deadline - SECONDS))
      (( remaining > 0 )) || break 2
      if info=$(timeout "$remaining" docker --config "$docker_config" inspect --format \
        '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}|{{.RestartCount}}|{{.State.StartedAt}}' \
        "$container"); then
        :
      else
        result=$?
        if (( result == 124 && SECONDS >= deadline )); then break 2; fi
        echo "Failed to inspect $service (exit $result)" >&2
        return 1
      fi
      IFS='|' read -r status health restarts started <<< "$info"
      fingerprint="$container|$restarts|$started"
      if [[ "$fingerprint" != "${fingerprints[$index]}" ]]; then
        healthy_since[$index]=-1
        fingerprints[$index]=$fingerprint
      fi
      state="$status|$health|$restarts|$started"
      if [[ "$state" != "${previous_states[$index]}" ]]; then
        printf '[health] %s: status=%s health=%s restarts=%s started=%s\n' \
          "$service" "$status" "$health" "$restarts" "$started" >&2
        previous_states[$index]=$state
      fi
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
        *) healthy_since[$index]=-1; continue ;;
      esac
      healthy=false
      if [[ "$health" == none && "$legacy" == true ]]; then
        # Compatibility with the release running before /healthz was introduced.
        remaining=$((deadline - SECONDS))
        (( remaining > 0 )) || break 2
        local probe=(docker --config "$docker_config" exec "$container")
        if [[ "$service" == panda-app ]]; then
          probe+=(python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/', timeout=2)")
        else
          probe+=(curl --fail --silent --max-time 2 http://127.0.0.1/)
        fi
        if timeout "$remaining" "${probe[@]}" >/dev/null 2>&1; then
          healthy=true
        else
          result=$?
          if (( result == 124 && SECONDS >= deadline )); then break 2; fi
        fi
      elif [[ "$health" == healthy ]]; then
        healthy=true
      fi
      last_checked[$index]=$SECONDS
      if [[ "$healthy" == true ]]; then
        if (( healthy_since[index] < 0 )); then healthy_since[$index]=$SECONDS; fi
      else
        healthy_since[$index]=-1
      fi
    done
    remaining=$((deadline - SECONDS))
    if (( remaining > 0 )); then
      if (( remaining > 2 )); then sleep 2; else sleep "$remaining"; fi
    fi
  done
  for index in "${!services[@]}"; do
    stable=0
    age=-1
    if (( healthy_since[index] >= 0 )); then stable=$((SECONDS - healthy_since[index])); fi
    if (( last_checked[index] >= 0 )); then age=$((SECONDS - last_checked[index])); fi
    printf '[health] %s: stable=%ss last_check_age=%ss\n' "${services[$index]}" "$stable" "$age" >&2
    # Do not accept a stale success if Docker stopped responding near the deadline.
    if (( healthy_since[index] < 0 || stable < 10 || age < 0 || age > 5 )); then failed=true; fi
  done
  if [[ "$failed" == true ]]; then
    echo 'Release needs 10 seconds of stable health and a health confirmation within the last 5 seconds' >&2
    return 1
  fi
  return 0
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
