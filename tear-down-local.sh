#!/usr/bin/env bash
set -euo pipefail

# Load variables directly from .env
if [[ ! -f .env ]]; then
  echo "[error] .env file not found. Please create it before running this script." >&2
  exit 1
fi

echo "[debug] Loading environment variables from .env..."
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
