#!/usr/bin/env bash
set -euo pipefail

#######################################
# Logging utility for consistent styling.
# Arguments:
#   $1 Log level (info, error, warning, debug)
#   $2 Message
#######################################
log() {
  local level="$1"
  local msg="$2"
  echo "[$level] $msg"
}

# Load env and validate variables
source .env
: "${REPO:?Missing REPO in .env}"
: "${ACCESS_TOKEN:?Missing ACCESS_TOKEN in .env}"
: "${SERVICE_NAME:?Missing SERVICE_NAME in .env}"
: "${ENVIRONMENT:?Missing ENVIRONMENT in .env}"

#######################################
# Determine Docker Compose command (supports v1 and v2)
#######################################
if command -v docker-compose &> /dev/null; then
  COMPOSE_CMD="docker-compose"
elif docker compose version &> /dev/null; then
  COMPOSE_CMD="docker compose"
else
  log "error" "docker-compose or 'docker compose' is required."
  exit 1
fi

#######################################
# Ensure Docker is running (basic check)
#######################################
if ! docker info &> /dev/null; then
  log "error" "Docker does not appear to be running or accessible."
  exit 1
fi

#######################################
# Generic function to install a package if missing.
# Supported package managers: apt-get, yum, dnf, apk, brew
# Globals:
#   EUID, SUDO
# Arguments:
#   $1 - The command name to check (e.g. jq, fzf)
#   $2 - The package name for the manager if different (optional)
#######################################
install_package_if_missing() {
  local cmd_name="$1"
  local pkg_name="${2:-$1}"

  if command -v "$cmd_name" &> /dev/null; then
    return
  fi

  log "info" "$cmd_name not found, attempting to install..."

  # Determine sudo usage
  if [[ "$EUID" -ne 0 && -n "$(command -v sudo || true)" ]]; then
    SUDO="sudo"
  else
    SUDO=""
  fi

  # Try common package managers
  if command -v apt-get &> /dev/null; then
    $SUDO apt-get update && $SUDO apt-get install -y "$pkg_name"
  elif command -v yum &> /dev/null; then
    $SUDO yum install -y epel-release && $SUDO yum install -y "$pkg_name"
  elif command -v dnf &> /dev/null; then
    $SUDO dnf install -y "$pkg_name"
  elif command -v apk &> /dev/null; then
    $SUDO apk add "$pkg_name"
  elif command -v brew &> /dev/null; then
    brew install "$pkg_name"
  else
    log "error" "Could not auto-install $cmd_name. Please install it manually."
    exit 1
  fi
}

#######################################
# Obtain GitHub removal token for removing self-hosted runners
#######################################
get_remove_token() {
  curl -s -X POST -H "Authorization: token ${ACCESS_TOKEN}" \
    "https://api.github.com/repos/${REPO}/actions/runners/remove-token" \
    | jq -r .token
}

#######################################
# List runner containers. Output format: "<id>\t<name>"
#######################################
list_runner_containers() {
  docker ps --filter "name=runner" --format "{{.ID}}\t{{.Names}}"
}

#######################################
# Start N runners by launching individual containers
# Arguments:
#   $1 - Desired total number of runners
#######################################
start_runners() {
  local desired_total="$1"

  # Validate numeric input
  if ! [[ "$desired_total" =~ ^[0-9]+$ ]]; then
    log "error" "Invalid number of runners: $desired_total"
    exit 1
  fi

  # Count existing runner containers
  local existing_count
  existing_count=$(list_runner_containers | wc -l | tr -d ' ')

  if (( existing_count >= desired_total )); then
    log "info" "Already have $existing_count runners; nothing to add."
    return
  fi

  local to_add=$((desired_total - existing_count))
  log "info" "Building runner image..."
  ${COMPOSE_CMD} build runner

  # Ensure network exists
  if ! docker network ls --format '{{.Name}}' | grep -q '^backend$'; then
    log "info" "Creating Docker network 'backend'..."
    docker network create backend
  fi

  # Launch new runners
  for ((i=1; i<=to_add; i++)); do
    local slot=$((existing_count + i))
    local slot_str
    slot_str=$(printf '%02d' "$slot")
    local ts
    ts=$(date -u +%Y%m%dT%H%M%S)
    local instance_name="runner-${SERVICE_NAME}-${ENVIRONMENT}-slot${slot_str}-${ts}"

    log "info" "Starting runner container $instance_name..."
    docker run -d \
      --name "${instance_name}" \
      --hostname "${instance_name}" \
      --network backend \
      -v /var/run/docker.sock:/var/run/docker.sock \
      --env-file .env \
      -e RUNNER_SLOT="${slot_str}" \
      -e RUNNER_TIMESTAMP="${ts}" \
      -e RUNNER_NAME="${instance_name}" \
      -e RUNNER_LABELS="self-hosted,${SERVICE_NAME},${ENVIRONMENT},slot-${slot_str}" \
      "${SERVICE_NAME}-runner:latest"
  done

  log "info" "Started $to_add new runner(s); total now $desired_total."
}

#######################################
# Tear down given container IDs
# Arguments:
#   All arguments are container IDs
#######################################
teardown_runners() {
  install_package_if_missing "jq"
  if [[ $# -eq 0 ]]; then
    log "info" "No runners selected for teardown."
    return
  fi

  local token
  log "info" "Fetching removal token..."
  token=$(get_remove_token)

  if [[ -z "$token" || "$token" == "null" ]]; then
    log "error" "Failed to get removal token."
    exit 1
  fi

  log "info" "Removing runners: $*"
  for cid in "$@"; do
    log "debug" "Removing runner in container $cid..."
    docker exec -w /home/docker/actions-runner "$cid" ./config.sh remove --unattended --token "$token" \
      || log "warning" "Failed to remove runner in $cid"
    docker rm -f "$cid" >/dev/null 2>&1 || true
  done

  # If no runners remain, bring down compose services
  if [[ -z "$(list_runner_containers)" ]]; then
    log "info" "No active runners remain; bringing down compose services..."
    ${COMPOSE_CMD} down
  fi
}

#######################################
# Interactive menu using fzf
#######################################
interactive_menu() {
  install_package_if_missing "fzf"

  local action
  # Show two main options
  action=$(printf "Start runners\nTear down runners" | fzf --height=10 --border --prompt="Action> ")

  case "$action" in
    "Start runners")
      local num
      read -rp "Enter number of runners to start: " num
      if [[ ! "$num" =~ ^[0-9]+$ ]]; then
        log "error" "Invalid number."
        exit 1
      fi
      start_runners "$num"
      ;;
    "Tear down runners")
      # Add an "ALL" option
      local choices
      choices=$( { echo -e "ALL\n"; list_runner_containers; } | fzf --multi --height=20 --border --prompt="Select runners> " )
      local ids=()

      while read -r line; do
        [[ -z "$line" ]] && continue
        if [[ "$line" == "ALL" ]]; then
          ids=( $(list_runner_containers | cut -f1) )
          break
        fi
        ids+=( "$(echo "$line" | cut -f1)" )
      done <<< "$choices"

      teardown_runners "${ids[@]}"
      ;;
    *)
      log "error" "No action selected."
      exit 1
      ;;
  esac
}

#######################################
# Main: interpret command line arguments
#######################################
if [[ $# -eq 0 ]]; then
  interactive_menu
elif [[ $# -eq 1 ]]; then
  if [[ "$1" =~ ^[0-9]+$ ]]; then
    start_runners "$1"
  else
    log "error" "Usage: $0 [number]"
    exit 1
  fi
else
  log "error" "Usage: $0 [number]"
  exit 1
fi
