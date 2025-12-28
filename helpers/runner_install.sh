#!/bin/bash
# Gitea Act Runner Installation Script
# Installs giteaGetTokens.sh to user's config directory with expanded variables
# Then deploys the Act Runner container to a KVM VM

# Required environment variables:
# - SUDO_USER: The user to install for
# - FQDN: (optional) The main domain for constructing gitea URL
# - GITEA_USERNAME: (optional) The Gitea admin username

set -e

ABS_PATH="${ABS_PATH:-$(dirname "$(realpath "$0")")/..}"
SCRIPT_DIR="$(dirname "$(realpath "$0")")"

if [ -z "${SUDO_USER:-}" ]; then
  echo "Error: SUDO_USER must be set" >&2
  exit 1
fi

# Get user's home directory and SSH key
USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
SSH_KEY_PATH="$USER_HOME/.ssh/id_ed25519"

# Install giteaGetTokens.sh to user's config directory
GITEA_CONFIG_DIR="$USER_HOME/.config/gitea"
mkdir -p "$GITEA_CONFIG_DIR"

# Construct Gitea URL from FQDN
if [ -n "${FQDN:-}" ]; then
  GITEA_URL="gitea.$FQDN"
else
  GITEA_URL=""
fi

# Copy and expand variables in the script
sed -e "s|__GITEA_USERNAME__|${GITEA_USERNAME:-}|g" \
    -e "s|__GITEA_URL__|${GITEA_URL:-}|g" \
    -e "s|__CONFIG_DIR__|$GITEA_CONFIG_DIR|g" \
    "$ABS_PATH/helpers/giteaGetTokens.sh" > "$GITEA_CONFIG_DIR/giteaGetTokens.sh"

chmod +x "$GITEA_CONFIG_DIR/giteaGetTokens.sh"
chown -R "$SUDO_USER:$SUDO_USER" "$GITEA_CONFIG_DIR"

echo "Gitea Act Runner token script installed to: $GITEA_CONFIG_DIR/giteaGetTokens.sh"

# ============================================================
# Deploy Act Runner to KVM VM
# ============================================================

VM_NAME="ubuntu-vm"
VM_USER="ubuntu"
VM_IP="192.168.122.2"

echo "Deploying Act Runner to VM: $VM_NAME ($VM_IP)"

# Check if VM is running, start if not
if ! virsh domstate "$VM_NAME" 2>/dev/null | grep -q "running"; then
  echo "Starting VM $VM_NAME..."
  virsh start "$VM_NAME"
  sleep 10
fi

# Wait for SSH to be available
echo "Waiting for VM to be accessible via SSH..."
MAX_RETRIES=30
RETRY_COUNT=0
while ! ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$VM_USER@$VM_IP" "echo 'SSH ready'" &>/dev/null; do
  RETRY_COUNT=$((RETRY_COUNT + 1))
  if [ $RETRY_COUNT -ge $MAX_RETRIES ]; then
    echo "Error: Timeout waiting for VM SSH access" >&2
    exit 1
  fi
  echo "  Waiting for SSH... (attempt $RETRY_COUNT/$MAX_RETRIES)"
  sleep 5
done

echo "VM is accessible. Deploying Act Runner..."

# Create temp directory for prepared files
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

# Prepare .env file with expanded variables
# Read runner token from .runner_token file (JSON response)
RUNNER_TOKEN=""
if [ -f "$GITEA_CONFIG_DIR/.runner_token" ]; then
  # Extract token from JSON response if jq is available, otherwise try basic parsing
  if command -v jq &>/dev/null; then
    RUNNER_TOKEN=$(jq -r '.token // empty' "$GITEA_CONFIG_DIR/.runner_token" 2>/dev/null || true)
  fi
  if [ -z "$RUNNER_TOKEN" ]; then
    # Fallback: try to extract token with grep
    RUNNER_TOKEN=$(grep -oP '"token"\s*:\s*"\K[^"]+' "$GITEA_CONFIG_DIR/.runner_token" 2>/dev/null || true)
  fi
fi

cat > "$TEMP_DIR/.env" <<EOF
GITEA_INSTANCE_URL=https://$GITEA_URL
GITEA_RUNNER_REGISTRATION_TOKEN=$RUNNER_TOKEN
GITEA_RUNNER_NAME=act-runner-1
EOF

# Prepare compose file with expanded URL
sed "s|http://gitea.example.com|https://$GITEA_URL|g" \
    "$SCRIPT_DIR/act_runner-compose.yaml" > "$TEMP_DIR/compose.yaml"

# Create setup script to run on the VM
cat > "$TEMP_DIR/setup_runner.sh" <<'SCRIPT_EOF'
#!/bin/bash
set -e

echo "Updating system packages..."
sudo apt update -y
sudo apt upgrade -y

echo "Installing Docker..."
sudo apt install -y docker.io docker-compose-v2

echo "Adding user to docker group..."
sudo usermod -aG docker $USER

echo "Starting Act Runner container..."
cd ~/act-runner
sudo docker compose up -d

echo "Act Runner deployment complete!"
SCRIPT_EOF

chmod +x "$TEMP_DIR/setup_runner.sh"

# Copy files to VM
echo "Copying files to VM..."
ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "$VM_USER@$VM_IP" "mkdir -p ~/act-runner"
scp -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "$TEMP_DIR/.env" "$VM_USER@$VM_IP:~/act-runner/.env"
scp -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "$TEMP_DIR/compose.yaml" "$VM_USER@$VM_IP:~/act-runner/compose.yaml"
scp -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "$TEMP_DIR/setup_runner.sh" "$VM_USER@$VM_IP:~/setup_runner.sh"

# Execute setup script on VM
echo "Running setup script on VM (this may take a few minutes)..."
ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "$VM_USER@$VM_IP" "bash ~/setup_runner.sh"

echo ""
echo "============================================================"
echo "Gitea Act Runner deployment complete!"
echo "VM: $VM_NAME ($VM_IP)"
echo "Runner files: ~/act-runner/"
echo "============================================================"
