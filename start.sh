#!/usr/bin/env bash
set -euo pipefail

: "${REPO:?Missing REPO}"
: "${ACCESS_TOKEN:?Missing ACCESS_TOKEN}"

# Defaults
SERVICE_NAME="${SERVICE_NAME:-github-runner}"
ENVIRONMENT="${ENVIRONMENT:-prod}"
SLOT="${SLOT:-01}"
TIMESTAMP="$(date +%Y%m%dT%H%M%S)"
RUNNER_NAME="${RUNNER_NAME:-runner-${SERVICE_NAME}-${ENVIRONMENT}-${SLOT}-${TIMESTAMP}}"
RUNNER_WORKDIR="${RUNNER_WORKDIR:-_work}"
RUNNER_GROUP="${RUNNER_GROUP:-Default}"
RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,${SERVICE_NAME},${ENVIRONMENT},slot-${SLOT}}"

cd /home/docker/actions-runner

# Check GitHub connectivity
echo "[debug] Checking connectivity to GitHub..."
if ! curl -sf https://api.github.com/zen > /dev/null; then
  echo "[error] Cannot reach GitHub API. Please check network connectivity." >&2
  exit 1
fi

# Validate that either REPO or ORG is set
if [[ -z "${REPO:-}" && -z "${ORG:-}" ]]; then
  echo "[error] Missing REPO or ORG" >&2
  exit 1
fi

# Determine target API path and GitHub URL based on scope
if [[ -n "${ORG:-}" ]]; then
  TARGET_PATH="orgs/${ORG}"
  GH_URL="https://github.com/${ORG}"
else
  TARGET_PATH="repos/${REPO}"
  GH_URL="https://github.com/${REPO}"
fi

# Get registration token
echo "[debug] Getting registration token..."
REG_TOKEN=$(curl -s -X POST -H "Authorization: token ${ACCESS_TOKEN}" \
    "https://api.github.com/${TARGET_PATH}/actions/runners/registration-token" \
    | jq -r .token)

if [ -z "${REG_TOKEN}" ] || [ "${REG_TOKEN}" = "null" ]; then
    echo "[error] Failed to get registration token" >&2
    exit 1
fi

# Increase default connection timeouts
export VSS_AGENT_CONNECT_TIMEOUT=180
export VSS_AGENT_DOWNLOAD_TIMEOUT=180

# Configure Actions cache and runtime URLs
export ACTIONS_CACHE_URL="${ACTIONS_CACHE_URL:-${ACTIONS_RESULTS_URL}}"
export ACTIONS_RUNTIME_URL="${ACTIONS_RESULTS_URL}"

# Configure runner in unattended mode
echo "[debug] Configuring runner (non-interactive)..."
set -x # Enable command tracing
./config.sh --unattended \
  --url "${GH_URL}" \
  --token "${REG_TOKEN}" \
  --name "${RUNNER_NAME}" \
  --work "${RUNNER_WORKDIR}" \
  --runnergroup "${RUNNER_GROUP}" \
  --labels "${RUNNER_LABELS}" \
  --replace
set +x # Disable command tracing
exit_code=$?

# ▶ dump the newest diagnostic log if configure failed or hung
latest_diag="$(ls -1t _diag | head -n1)"
echo "[debug] ----- _diag/${latest_diag} -----"
tail -n +1 "_diag/${latest_diag}" | sed 's/^/    /'
echo "[debug] ----- end diag -----"

if [[ $exit_code -ne 0 ]]; then
  echo "[error] config.sh exited with $exit_code – see diagnostic above"
  exit $exit_code
fi

echo "[debug] Runner configured"

# Cleanup logic on exit
cleanup() {
  echo "[debug] Cleaning up runner..."
  # Get a removal token
  REMOVE_TOKEN=$(curl -s -X POST -H "Authorization: token ${ACCESS_TOKEN}" \
      "https://api.github.com/${TARGET_PATH}/actions/runners/remove-token" \
      | jq -r .token)
  
  if [ -n "${REMOVE_TOKEN}" ] && [ "${REMOVE_TOKEN}" != "null" ]; then
    ./config.sh remove --unattended --token "${REMOVE_TOKEN}" || echo "[warning] Failed to remove runner automatically."
  else
    echo "[warning] Failed to get removal token"
  fi
}
trap 'cleanup; exit 130' INT TERM
trap 'cleanup; exit 0' EXIT

# Launch the long-lived runner process
echo "[debug] Starting runner..."
exec ./run.sh
