#!/usr/bin/env bash
set -euo pipefail

# Prompt for vault password
echo -n "Vault password: "
read -s VAULT_PASS
echo

# Decrypt .env.enc to temporary .env
echo "[debug] Decrypting environment variables..."
ansible-vault decrypt .env.enc --output .env --vault-password-file=<(echo "$VAULT_PASS")

# Load variables
source .env

# Get removal token from GitHub API
echo "[debug] Getting removal token..."
REMOVE_TOKEN=$(curl -s -X POST -H "Authorization: token ${ACCESS_TOKEN}" \
  "https://api.github.com/repos/${REPO}/actions/runners/remove-token" \
  | jq -r .token)

if [[ -z "$REMOVE_TOKEN" || "$REMOVE_TOKEN" == "null" ]]; then
  echo "[error] Failed to get removal token" >&2
  exit 1
fi

echo "[debug] Removing runners..."
# Find runner containers by name and remove runners
for cid in $(docker ps --filter "name=runner" -q); do
  echo "[debug] Removing runner in container $cid"
  docker exec "$cid" /home/docker/actions-runner/config.sh remove --unattended --token "$REMOVE_TOKEN" || \
    echo "[warning] Failed to remove runner in $cid"
done

# Bring down compose environment
echo "[debug] Bringing down Docker Compose environment..."
docker compose down

echo "[info] Teardown complete."
