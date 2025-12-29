#!/bin/bash
# Runner Manager Script
# Creates and manages Gitea Act Runner instances
# Usage: ./runnermgr.sh [--type repo|org] --token <token> --name <name>

set -e

SCRIPT_DIR="$(dirname "$(realpath "$0")")"
DEPS_DIR="$SCRIPT_DIR/dependencies"
RUNNERS_DIR="$HOME/runners"

# Default values
TYPE="repo"
TOKEN=""
NAME=""

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Create a new Gitea Act Runner instance.

Options:
  --name <name>           Name for the runner instance (required for repo/org types)
                          (lowercase alphanumeric and hyphens only, must start with a letter, max 50 chars)
  --type <instance|repo|org>  Type of runner (default: repo)
                              - instance: Global instance runner (name is ignored, always 'instance')
                              - org: Organization-level runner (creates org_<name>)
                              - repo: Repository-level runner (creates repo_<name>)
  --token <token>         Gitea runner registration token (required)
  -h, --help              Show this help message

Examples:
  $(basename "$0") --type instance --token abc123
  $(basename "$0") --token abc123 --name myrepo
  $(basename "$0") --type org --token abc123 --name myorg

EOF
  exit "${1:-0}"
}

validate_name() {
  local name="$1"
  
  if [ -z "$name" ]; then
    echo "Error: Name is required" >&2
    usage 1
  fi
  
  # Check length (1-50 characters, leaving room for "repo-" or "org-" prefix)
  if [ ${#name} -lt 1 ] || [ ${#name} -gt 50 ]; then
    echo "Error: Name must be between 1 and 50 characters" >&2
    exit 1
  fi
  
  # Check for valid characters (lowercase alphanumeric and hyphens only - Docker container naming)
  if ! [[ "$name" =~ ^[a-z][a-z0-9-]*$ ]]; then
    echo "Error: Name must start with a lowercase letter and contain only lowercase letters, numbers, and hyphens" >&2
    exit 1
  fi
  
  # Check it doesn't end with a hyphen
  if [[ "$name" =~ -$ ]]; then
    echo "Error: Name cannot end with a hyphen" >&2
    exit 1
  fi
}

validate_type() {
  local type="$1"
  
  if [ "$type" != "instance" ] && [ "$type" != "repo" ] && [ "$type" != "org" ]; then
    echo "Error: Type must be 'instance', 'repo', or 'org'" >&2
    exit 1
  fi
}

# Parse arguments
while [ $# -gt 0 ]; do
  case "$1" in
    --type)
      TYPE="$2"
      shift 2
      ;;
    --token)
      TOKEN="$2"
      shift 2
      ;;
    --name)
      NAME="$2"
      shift 2
      ;;
    -h|--help)
      usage 0
      ;;
    -*)
      echo "Error: Unknown option: $1" >&2
      usage 1
      ;;
    *)
      echo "Error: Unexpected argument: $1" >&2
      usage 1
      shift
      ;;
  esac
done

# Validate required parameters
if [ -z "$TOKEN" ]; then
  echo "Error: --token is required" >&2
  usage 1
fi

validate_type "$TYPE"

# Name is required for repo/org types, ignored for instance type
if [ "$TYPE" != "instance" ]; then
  if [ -z "$NAME" ]; then
    echo "Error: --name is required for $TYPE type" >&2
    usage 1
  fi
  validate_name "$NAME"
fi

# Check dependencies directory exists
if [ ! -d "$DEPS_DIR" ]; then
  echo "Error: Dependencies directory not found: $DEPS_DIR" >&2
  exit 1
fi

if [ ! -f "$DEPS_DIR/compose.yaml" ]; then
  echo "Error: Template compose.yaml not found in $DEPS_DIR" >&2
  exit 1
fi

if [ ! -f "$DEPS_DIR/.env" ]; then
  echo "Error: Template .env not found in $DEPS_DIR" >&2
  exit 1
fi

# Generate instance directory and runner/container name based on type
if [ "$TYPE" = "instance" ]; then
  INSTANCE_DIR="$RUNNERS_DIR/instance"
  RUNNER_NAME="instance"
else
  INSTANCE_DIR="$RUNNERS_DIR/${TYPE}_${NAME}"
  RUNNER_NAME="${TYPE}-${NAME}"
fi

if [ -d "$INSTANCE_DIR" ]; then
  echo "Error: Instance already exists: $INSTANCE_DIR" >&2
  echo "To recreate, first remove the existing instance directory" >&2
  exit 1
fi

if [ "$TYPE" = "instance" ]; then
  echo "Creating global instance runner"
else
  echo "Creating runner instance: ${TYPE}_${NAME}"
fi
echo "Runner/Container name: $RUNNER_NAME"
mkdir -p "$INSTANCE_DIR"

# Copy and configure compose.yaml (expand container_name)
sed "s|container_name:.*|container_name: $RUNNER_NAME|" \
    "$DEPS_DIR/compose.yaml" > "$INSTANCE_DIR/compose.yaml"

# Substitute token and runner name in .env
sed -e "s|GITEA_RUNNER_REGISTRATION_TOKEN=.*|GITEA_RUNNER_REGISTRATION_TOKEN=$TOKEN|" \
    -e "s|GITEA_RUNNER_NAME=.*|GITEA_RUNNER_NAME=$RUNNER_NAME|" \
    "$DEPS_DIR/.env" > "$INSTANCE_DIR/.env"

# Start the runner container
echo "Starting runner container..."
cd "$INSTANCE_DIR"
docker compose up -d

echo "Runner '$RUNNER_NAME' is now running."
echo "To check status: docker ps | grep $RUNNER_NAME"
echo "To view logs: docker logs -f $RUNNER_NAME"
