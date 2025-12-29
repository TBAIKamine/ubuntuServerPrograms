#!/bin/bash
# Gitea Token Manager
# Usage: 
#   ./giteaGetTokens.sh --init                              # First-time PAT generation (one-time only)
#   ./giteaGetTokens.sh --runner-token                      # Get instance runner token (only 1 ever)
#   ./giteaGetTokens.sh --runner-token --org <name>         # Get org-level runner token (1 per org)
#   ./giteaGetTokens.sh --runner-token --repo <owner/repo>  # Get repo-level runner token (1 per repo)
#   ./giteaGetTokens.sh --list                              # List all registered runners
#
# Each runner token can only be obtained ONCE. The registry tracks created runners.

# Must run as root/sudo
if [ "$EUID" -ne 0 ]; then
  echo "Error: This script must be run with sudo" >&2
  exit 1
fi

set -e

GITEA_USERNAME="__GITEA_USERNAME__"
GITEA_URL="__GITEA_URL__"
CONFIG_DIR="__CONFIG_DIR__"

# Load from .env if variables are not configured (allows retry after failed --init)
ENV_FILE="/home/${SUDO_USER:-$USER}/.config/gitea/.env"
if [ -f "$ENV_FILE" ]; then
  source "$ENV_FILE"
fi

REGISTRY_FILE="$CONFIG_DIR/.runners_registry"

# Parse arguments
ACTION=""
SCOPE_TYPE=""
SCOPE_VALUE=""
FORCE=false

while [ $# -gt 0 ]; do
  case "$1" in
    --init)
      ACTION="init"
      shift
      ;;
    --runner-token)
      ACTION="runner-token"
      shift
      ;;
    --org)
      SCOPE_TYPE="org"
      SCOPE_VALUE="$2"
      shift 2
      ;;
    --repo)
      SCOPE_TYPE="repo"
      SCOPE_VALUE="$2"
      shift 2
      ;;
    --list)
      ACTION="list"
      shift
      ;;
    --force)
      FORCE=true
      shift
      ;;
    -h|--help)
      cat <<EOF
Usage:
  $(basename "$0") --init                              # First-time PAT generation
  $(basename "$0") --runner-token                      # Get instance runner token (only 1 ever)
  $(basename "$0") --runner-token --org <name>         # Get org-level runner token (1 per org)
  $(basename "$0") --runner-token --repo <owner/repo>  # Get repo-level runner token (1 per repo)
  $(basename "$0") --list                              # List all registered runners
  $(basename "$0") --runner-token [--org|--repo] --force  # Force new token (use with caution!)

Note: Each runner token can only be obtained ONCE per scope. 
      The registry at $REGISTRY_FILE tracks created runners.
EOF
      exit 0
      ;;
    *)
      echo "Error: Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

if [ -z "$ACTION" ]; then
  echo "Error: No action specified. Use --init, --runner-token, or --list" >&2
  exit 1
fi

if [ -z "$GITEA_USERNAME" ] || [[ "$GITEA_USERNAME" == __*__ ]]; then
  echo "Error: GITEA_USERNAME not configured. Please edit this script or re-run installation."
  exit 1
fi

if [ -z "$GITEA_URL" ] || [[ "$GITEA_URL" == __*__ ]]; then
  echo "Error: GITEA_URL not configured. Please edit this script or re-run installation."
  exit 1
fi

# Initialize registry file if it doesn't exist
touch "$REGISTRY_FILE" 2>/dev/null || true

# Helper: Get runner registry key based on scope
get_registry_key() {
  if [ -z "$SCOPE_TYPE" ]; then
    echo "instance"
  elif [ "$SCOPE_TYPE" = "org" ]; then
    echo "org:$SCOPE_VALUE"
  elif [ "$SCOPE_TYPE" = "repo" ]; then
    echo "repo:$SCOPE_VALUE"
  fi
}

# Helper: Check if runner is already registered
is_registered() {
  local key="$1"
  grep -qxF "$key" "$REGISTRY_FILE" 2>/dev/null
}

# Helper: Register a runner
register_runner() {
  local key="$1"
  echo "$key" >> "$REGISTRY_FILE"
}

# ============================================================
# --list: Show all registered runners
# ============================================================
if [ "$ACTION" = "list" ]; then
  if [ ! -s "$REGISTRY_FILE" ]; then
    echo "No runners registered yet."
    exit 0
  fi
  echo "Registered runners:"
  echo "-------------------"
  while IFS= read -r line; do
    case "$line" in
      instance)
        echo "  [instance] Global instance runner"
        ;;
      org:*)
        echo "  [org]      ${line#org:}"
        ;;
      repo:*)
        echo "  [repo]     ${line#repo:}"
        ;;
      *)
        echo "  [?]        $line"
        ;;
    esac
  done < "$REGISTRY_FILE"
  exit 0
fi

# ============================================================
# --init: Generate PAT (one-time only)
# ============================================================
if [ "$ACTION" = "init" ]; then
  if [ -f "$CONFIG_DIR/.pat" ] && [ -s "$CONFIG_DIR/.pat" ]; then
    echo "PAT already exists at $CONFIG_DIR/.pat"
    echo "This token can only be generated once. Delete the file if you need to regenerate."
    exit 0
  fi

  echo "Generating Personal Access Token for user: $GITEA_USERNAME"

  # podmgr exec only opens an interactive shell, so we need to run podman directly as the gitea user
  PAT=$(timeout 30s sudo -u gitea -H bash -c "
    cd /opt/compose/gitea
    source /var/lib/gitea/.config/environment.d/podman.conf
    CONTAINER_NAME=$(grep 'container_name:' compose.yaml 2>/dev/null || grep 'container_name:' docker-compose.yaml 2>/dev/null | head -1 | awk '{print $2}')
    podman exec "$CONTAINER_NAME" gitea admin user generate-access-token \
      --username '$GITEA_USERNAME' \
      --token-name 'automation-token' \
      --scopes all \
      --raw
  " 2>/dev/null || true)

  if [ -z "$PAT" ]; then
    # Save config for retry
    ENV_DIR="/home/${SUDO_USER:-$USER}/.config/gitea"
    mkdir -p "$ENV_DIR"
    cat > "$ENV_DIR/.env" <<ENVEOF
GITEA_USERNAME="$GITEA_USERNAME"
GITEA_URL="$GITEA_URL"
CONFIG_DIR="$CONFIG_DIR"
ENVEOF
    chown -R "${SUDO_USER:-$USER}:${SUDO_USER:-$USER}" "$ENV_DIR"
    chmod 600 "$ENV_DIR/.env"
    echo "Error: Failed to generate PAT or timed out. if you haven't installed Gitea from the web interface, you must do it first."
    echo "Config saved to $ENV_DIR/.env for retry."
    echo "then execute: giteaGetTokens --init"
    exit 1
  fi

  # Save PAT securely
  echo "$PAT" > "$CONFIG_DIR/.pat"
  chmod 600 "$CONFIG_DIR/.pat"
  echo "PAT saved to $CONFIG_DIR/.pat"
  exit 0
fi

# ============================================================
# --runner-token: Get runner registration token
# ============================================================
if [ "$ACTION" = "runner-token" ]; then
  # Check PAT exists
  if [ ! -f "$CONFIG_DIR/.pat" ] || [ ! -s "$CONFIG_DIR/.pat" ]; then
    echo "Error: PAT not found. Run --init first." >&2
    exit 1
  fi

  # Check if this runner is already registered
  REGISTRY_KEY=$(get_registry_key)
  
  if is_registered "$REGISTRY_KEY" && [ "$FORCE" != true ]; then
    echo "Error: Runner '$REGISTRY_KEY' is already registered." >&2
    echo "Each runner token can only be obtained once." >&2
    echo "Use --list to see all registered runners." >&2
    echo "Use --force to override (use with caution - old runner will be orphaned)." >&2
    exit 1
  fi

  PAT=$(cat "$CONFIG_DIR/.pat")

  # Determine API endpoint based on scope
  if [ -z "$SCOPE_TYPE" ]; then
    # Global/instance level runner token
    API_URL="https://$GITEA_URL/api/v1/admin/runners/registration-token"
    echo "Fetching instance runner registration token..." >&2
  elif [ "$SCOPE_TYPE" = "org" ]; then
    # Organization level runner token
    API_URL="https://$GITEA_URL/api/v1/orgs/$SCOPE_VALUE/actions/runners/registration-token"
    echo "Fetching runner registration token for org: $SCOPE_VALUE" >&2
  elif [ "$SCOPE_TYPE" = "repo" ]; then
    # Repository level runner token
    API_URL="https://$GITEA_URL/api/v1/repos/$SCOPE_VALUE/actions/runners/registration-token"
    echo "Fetching runner registration token for repo: $SCOPE_VALUE" >&2
  fi

  RUNNER_TOKEN_RESPONSE=$(curl -s -X GET "$API_URL" \
       -H "Authorization: token $PAT" \
       -H "accept: application/json")

  if [ -z "$RUNNER_TOKEN_RESPONSE" ]; then
    echo "Error: Failed to fetch runner registration token." >&2
    exit 1
  fi

  # Check for error in response
  if echo "$RUNNER_TOKEN_RESPONSE" | grep -q '"message"'; then
    echo "Error from Gitea API: $RUNNER_TOKEN_RESPONSE" >&2
    exit 1
  fi

  # Extract token
  if command -v jq &>/dev/null; then
    TOKEN=$(echo "$RUNNER_TOKEN_RESPONSE" | jq -r '.token // empty')
  else
    TOKEN=$(echo "$RUNNER_TOKEN_RESPONSE" | grep -oP '"token"\s*:\s*"\K[^"]+' || true)
  fi

  if [ -z "$TOKEN" ]; then
    echo "Error: Could not extract token from response: $RUNNER_TOKEN_RESPONSE" >&2
    exit 1
  fi

  # Register this runner (token is one-time use)
  register_runner "$REGISTRY_KEY"
  echo "Runner '$REGISTRY_KEY' registered." >&2

  # Output token to stdout (for capture by caller)
  echo "$TOKEN"
fi
