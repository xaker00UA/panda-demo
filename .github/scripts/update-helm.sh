#!/usr/bin/env bash
set -euo pipefail

: "${HELM_REPO_URL:?Set HELM_REPO_URL}"
: "${HELM_REPO_TOKEN:?Set HELM_REPO_TOKEN}"
: "${SERVICE:?Set SERVICE}"
: "${APP_IMAGE:?Set APP_IMAGE}"
: "${SHORT_COMMIT:?Set SHORT_COMMIT}"

export DEPLOYMENT_NAME="${DEPLOYMENT_NAME:-$SERVICE}"
export CONTAINER_NAME="${CONTAINER_NAME:-$SERVICE}"
export APP_IMAGE SHORT_COMMIT
export GIT_TAG="${GIT_TAG:-}"

if [[ "$HELM_REPO_URL" != https://github.com/* ]]; then
  echo "HELM_REPO_URL must be an HTTPS GitHub repository URL" >&2
  exit 1
fi
if [[ ! "$SERVICE" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  echo "SERVICE must be a directory name inside apps/" >&2
  exit 1
fi

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# Keep the token out of the remote URL, Git config, and command arguments.
cat > "$TMP_DIR/askpass" <<'ASKPASS'
#!/usr/bin/env bash
case "$1" in
  *Username*) printf '%s\n' 'x-access-token' ;;
  *Password*) printf '%s\n' "$HELM_REPO_TOKEN" ;;
esac
ASKPASS
chmod 700 "$TMP_DIR/askpass"
export GIT_ASKPASS="$TMP_DIR/askpass"
export GIT_TERMINAL_PROMPT=0

git clone --depth 1 --branch main "$HELM_REPO_URL" "$TMP_DIR/repo"
cd "$TMP_DIR/repo"

deployment_file="apps/$SERVICE/deployment.yaml"
if [[ ! -f "$deployment_file" ]]; then
  echo "Missing $deployment_file in the Helm repository" >&2
  exit 1
fi

# The file can contain Service and HTTPRoute documents as well as Deployment.
matches=$(yq eval-all '
  [select(.kind == "Deployment" and .metadata.name == strenv(DEPLOYMENT_NAME)) |
    .spec.template.spec.containers[] |
    select(.name == strenv(CONTAINER_NAME))] | length
' "$deployment_file")
if [[ "$matches" != 1 ]]; then
  echo "Expected one container $CONTAINER_NAME in Deployment $DEPLOYMENT_NAME; found $matches" >&2
  exit 1
fi

yq eval '
  (select(.kind == "Deployment" and .metadata.name == strenv(DEPLOYMENT_NAME)) |
    .spec.template.spec.containers[] |
    select(.name == strenv(CONTAINER_NAME))) |= (
      .image = strenv(APP_IMAGE) |
      .env = (
        ((.env // []) | map(select(.name != "GIT_SHORT_HASH" and .name != "GIT_TAG"))) +
        [{"name": "GIT_SHORT_HASH", "value": strenv(SHORT_COMMIT)},
         {"name": "GIT_TAG", "value": strenv(GIT_TAG)}]
      )
    )
' -i "$deployment_file"
git add -- "$deployment_file"
if git diff --cached --quiet; then
  echo "Nothing to commit"
  exit 0
fi

git config user.name 'github-actions[bot]'
git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
git commit -m "chore(deps): update app tag to $SHORT_COMMIT"
git push origin HEAD:main
