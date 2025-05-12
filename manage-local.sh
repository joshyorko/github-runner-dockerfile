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

#######################################
# Prompt for a variable if it's not already set.
# Globals:
#   Environment variables from shell and .env
# Arguments:
#   $1 - Variable name (e.g., "REPO")
#   $2 - Prompt message
#######################################
prompt_if_unset() {
  local var_name="$1"
  local prompt_msg="$2"

  # Indirect expansion to get current value of $var_name
  local current_val="${!var_name:-}"

  # If empty, prompt user
  if [[ -z "$current_val" ]]; then
    read -rp "$prompt_msg" user_input
    if [[ -z "$user_input" ]]; then
      log "error" "Value for $var_name cannot be empty."
      exit 1
    fi
    # Export so subsequent commands in the script see it
    export "$var_name"="$user_input"
    log "info" "$var_name set to '$user_input'"
  else
    log "info" "$var_name already set (value: $current_val)"
  fi
}

# Attempt to load .env if present (this won't error if .env is missing).
# This allows partial usage of .env and partial usage of prompts.
if [[ -f .env ]]; then
  source .env
fi

#######################################
# Required environment variables: REPO, ACCESS_TOKEN, SERVICE_NAME, ENVIRONMENT
# We will prompt for them if unset.
#######################################
prompt_if_unset "REPO" "Enter your GitHub repository (e.g. owner/repo): "
prompt_if_unset "ACCESS_TOKEN" "Enter your GitHub Personal Access Token: "
prompt_if_unset "SERVICE_NAME" "Enter the SERVICE_NAME (e.g. recoup-runner): "
prompt_if_unset "ENVIRONMENT" "Enter the ENVIRONMENT name (e.g. dev, prod): "

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
#######################################
install_package_if_missing() {
  local cmd_name="$1"
  local pkg_name="${2:-$1}"

  if command -v "$cmd_name" &> /dev/null; then
    return
  fi

  log "info" "$cmd_name not found, attempting to install..."

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
# Start N runners by launching containers
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

  # Ensure cache container is up
  log "info" "Bringing up cache container (and dependencies) via compose..."
  ${COMPOSE_CMD} up -d cache

  # Count existing runner containers
  local existing_count
  existing_count=$(list_runner_containers | wc -l | tr -d ' ')

  if (( existing_count >= desired_total )); then
    log "info" "Already have $existing_count runners; nothing to add."
    return
  fi

  local to_add=$((desired_total - existing_count))

  # Build the runner image via docker compose to ensure it's available locally
  log "info" "Building runner image (${SERVICE_NAME}-runner:latest)..."
  ${COMPOSE_CMD} build runner

  # Launch new runners via compose run to ensure proper networking and links
  for ((i=1; i<=to_add; i++)); do
    local slot=$((existing_count + i))
    local slot_str
    slot_str=$(printf '%02d' "$slot")
    local ts
    ts=$(date -u +%Y%m%dT%H%M%S)
    local instance_name="runner-${SERVICE_NAME}-${ENVIRONMENT}-slot${slot_str}-${ts}"

    log "info" "Starting runner container via compose run: $instance_name"
    ${COMPOSE_CMD} run -d --no-deps --name "${instance_name}" \
      -e RUNNER_SLOT="${slot_str}" \
      -e RUNNER_TIMESTAMP="${ts}" \
      -e RUNNER_NAME="${instance_name}" \
      -e RUNNER_LABELS="self-hosted,${SERVICE_NAME},${ENVIRONMENT},slot-${slot_str}" \
      runner
  done

  log "info" "Started $to_add new runner(s); total now $desired_total."
  return
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

  log "info" "Fetching removal token..."
  local token
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
      local choices
      # Add an "ALL" option
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
# Main logic: if no args, run interactive menu.
# If 1 numeric arg, start that many runners.
# Otherwise, print usage.
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
