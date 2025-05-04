#!/usr/bin/env bash
set -euo pipefail

: "${REPO:?Missing REPO}"
: "${ACCESS_TOKEN:?Missing ACCESS_TOKEN}"

# Defaults
RUNNER_NAME="${RUNNER_NAME:-$(hostname)}"
RUNNER_WORKDIR="${RUNNER_WORKDIR:-_work}"
RUNNER_GROUP="${RUNNER_GROUP:-Default}"
RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,Linux,X64}"

cd /home/docker/actions-runner

# Check GitHub connectivity
echo "[debug] Checking connectivity to GitHub..."
if ! curl -sf https://api.github.com/zen > /dev/null; then
  echo "[error] Cannot reach GitHub API. Please check network connectivity." >&2
  exit 1
fi

# Get registration token
echo "[debug] Getting registration token..."
REG_TOKEN=$(curl -s -X POST -H "Authorization: token ${ACCESS_TOKEN}" \
    "https://api.github.com/repos/${REPO}/actions/runners/registration-token" \
    | jq -r .token)

if [ -z "${REG_TOKEN}" ] || [ "${REG_TOKEN}" = "null" ]; then
    echo "[error] Failed to get registration token" >&2
    exit 1
fi

# Increase default connection timeouts
export VSS_AGENT_CONNECT_TIMEOUT=180
export VSS_AGENT_DOWNLOAD_TIMEOUT=180

# Configure runner in unattended mode
echo "[debug] Configuring runner (non-interactive)..."
set -x # Enable command tracing
./config.sh --unattended \
  --url "https://github.com/${REPO}" \
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
      "https://api.github.com/repos/${REPO}/actions/runners/remove-token" \
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
