#!/usr/bin/env bash
set -euo pipefail

: "${VPS_HOST:?Set VPS_HOST}"
: "${VPS_USER:?Set VPS_USER}"
: "${VPS_SSH_KEY:?Set VPS_SSH_KEY}"
: "${VPS_KNOWN_HOSTS:?Set VPS_KNOWN_HOSTS}"
: "${VPS_PATH:?Set VPS_PATH}"
: "${APP_IMAGE:?Set APP_IMAGE}"
: "${GIT_SHORT_HASH:?Set GIT_SHORT_HASH}"
: "${DEPLOY_COMMIT:?Set DEPLOY_COMMIT}"
: "${DEPLOY_BRANCH:?Set DEPLOY_BRANCH}"
: "${GHCR_USER:?Set GHCR_USER}"
: "${GHCR_TOKEN:?Set GHCR_TOKEN}"

ssh_dir=$(mktemp -d)
trap 'rm -rf "$ssh_dir"' EXIT
chmod 700 "$ssh_dir"
printf '%s\n' "$VPS_SSH_KEY" > "$ssh_dir/key"
printf '%s\n' "$VPS_KNOWN_HOSTS" > "$ssh_dir/known_hosts"
chmod 600 "$ssh_dir/key" "$ssh_dir/known_hosts"

# Send configuration over stdin; secrets do not appear in SSH arguments.
{
  printf 'export VPS_PATH=%q\n' "$VPS_PATH"
  printf 'export APP_IMAGE=%q\n' "$APP_IMAGE"
  printf 'export GIT_SHORT_HASH=%q\n' "$GIT_SHORT_HASH"
  printf 'export GIT_TAG=%q\n' "${GIT_TAG:-}"
  printf 'export DEPLOY_COMMIT=%q\n' "$DEPLOY_COMMIT"
  printf 'export DEPLOY_BRANCH=%q\n' "$DEPLOY_BRANCH"
  printf 'export GHCR_USER=%q\n' "$GHCR_USER"
  printf 'export GHCR_TOKEN=%q\n' "$GHCR_TOKEN"
  cat "$(dirname "${BASH_SOURCE[0]}")/deploy-vps-remote.sh"
} | ssh -i "$ssh_dir/key" \
  -p "${VPS_PORT:-22}" \
  -o BatchMode=yes \
  -o IdentitiesOnly=yes \
  -o StrictHostKeyChecking=yes \
  -o "UserKnownHostsFile=$ssh_dir/known_hosts" \
  -o ConnectTimeout=30 \
  "$VPS_USER@$VPS_HOST" 'bash -se'
