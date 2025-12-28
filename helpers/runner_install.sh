#!/bin/bash
# Gitea Act Runner Installation Script
# Installs giteaGetTokens.sh to user's config directory with expanded variables
# Then deploys the Act Runner container to a KVM VM

# Required environment variables:
# - SUDO_USER: The user to install for (auto-set by sudo, falls back to logname)
# - FQDN: (optional) The main domain for constructing gitea URL
# - GITEA_USERNAME: (optional) The Gitea admin username

set -e

ABS_PATH="${ABS_PATH:-$(dirname "$(realpath "$0")")/..}"
SCRIPT_DIR="$(dirname "$(realpath "$0")")"

# Determine target user with fallback chain:
# 1. SUDO_USER (set by sudo)
# 2. logname (original login user)
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
  INSTALL_USER="$SUDO_USER"
elif command -v logname &>/dev/null && logname &>/dev/null; then
  INSTALL_USER=$(logname)
else
  INSTALL_USER=""
fi

# Ensure we're not installing to root
if [ "$INSTALL_USER" = "root" ] || [ -z "$INSTALL_USER" ]; then
  echo "Error: Cannot determine target user. Run with: sudo ./runner_install.sh" >&2
  exit 1
fi

echo "Installing for user: $INSTALL_USER"

# Get user's home directory and SSH key
USER_HOME=$(getent passwd "$INSTALL_USER" | cut -d: -f6)
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
    "$SCRIPT_DIR/giteaGetTokens.sh" > "$GITEA_CONFIG_DIR/giteaGetTokens.sh"

chmod +x "$GITEA_CONFIG_DIR/giteaGetTokens.sh"
chown -R "$INSTALL_USER:$INSTALL_USER" "$GITEA_CONFIG_DIR"

# Create symlink in /usr/local/bin for easy access
ln -sf "$GITEA_CONFIG_DIR/giteaGetTokens.sh" /usr/local/bin/giteaGetToken

echo "Gitea Act Runner token script installed to: $GITEA_CONFIG_DIR/giteaGetTokens.sh"
echo "Symlink created: /usr/local/bin/giteaGetToken"

# Initialize PAT if it doesn't exist (one-time only)
if [ -f "$GITEA_CONFIG_DIR/.pat" ] && [ -s "$GITEA_CONFIG_DIR/.pat" ]; then
  echo "PAT already exists, skipping initialization..."
else
  echo "Initializing Gitea PAT..."
  if ! "$GITEA_CONFIG_DIR/giteaGetTokens.sh" --init; then
    echo "Warning: Failed to initialize PAT. You may need to run 'giteaGetTokens.sh --init' manually later." >&2
  fi
fi

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

# Check if instance runner is already registered
REGISTRY_FILE="$GITEA_CONFIG_DIR/.runners_registry"
if grep -qxF "instance" "$REGISTRY_FILE" 2>/dev/null; then
  echo "Instance runner already registered. Skipping runner deployment."
  echo "Use 'giteaGetTokens.sh --list' to see all registered runners."
  echo "VM setup will still proceed without creating a new runner instance."
  RUNNER_TOKEN=""
else
  # Get a fresh runner token for this deployment
  RUNNER_TOKEN=""
  if [ -f "$GITEA_CONFIG_DIR/.pat" ] && [ -s "$GITEA_CONFIG_DIR/.pat" ]; then
    echo "Fetching runner registration token..."
    RUNNER_TOKEN=$("$GITEA_CONFIG_DIR/giteaGetTokens.sh" --runner-token 2>/dev/null | tail -1)
  fi

  if [ -z "$RUNNER_TOKEN" ]; then
    echo "Warning: Could not get runner token. Run 'giteaGetTokens.sh --init' first, then re-run this script." >&2
  fi
fi

# Use existing .env template and hardcode GITEA_INSTANCE_URL (token and runner name will be set by runnermgr.sh)
sed -e "s|GITEA_INSTANCE_URL=.*|GITEA_INSTANCE_URL=https://$GITEA_URL|" \
    "$SCRIPT_DIR/.env" > "$TEMP_DIR/.env"

# Copy compose file as-is (container_name will be set by runnermgr.sh)
cp "$SCRIPT_DIR/act_runner-compose.yaml" "$TEMP_DIR/compose.yaml"

# Copy runnermgr.sh
cp "$SCRIPT_DIR/runnermgr.sh" "$TEMP_DIR/runnermgr.sh"

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

# Allow unprivileged user namespaces for rootless containers
echo "Configuring kernel for rootless containers..."
sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0
echo "kernel.apparmor_restrict_unprivileged_userns=0" | sudo tee /etc/sysctl.d/99-rootless.conf

echo "VM setup complete!"
SCRIPT_EOF

chmod +x "$TEMP_DIR/setup_runner.sh"

# Copy files to VM
echo "Copying files to VM..."
ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "$VM_USER@$VM_IP" "mkdir -p ~/runners ~/dependencies"
scp -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "$TEMP_DIR/.env" "$VM_USER@$VM_IP:~/dependencies/.env"
scp -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "$TEMP_DIR/compose.yaml" "$VM_USER@$VM_IP:~/dependencies/compose.yaml"
scp -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "$TEMP_DIR/runnermgr.sh" "$VM_USER@$VM_IP:~/runnermgr.sh"
scp -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "$TEMP_DIR/setup_runner.sh" "$VM_USER@$VM_IP:~/setup_runner.sh"

# Make runnermgr.sh executable
ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "$VM_USER@$VM_IP" "chmod +x ~/runnermgr.sh"

# Execute setup script on VM
echo "Running setup script on VM (this may take a few minutes)..."
ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "$VM_USER@$VM_IP" "bash ~/setup_runner.sh"

# Cleanup setup script from VM
ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "$VM_USER@$VM_IP" "rm -f ~/setup_runner.sh"

# Create the main runner instance if we have a token
if [ -n "$RUNNER_TOKEN" ]; then
  echo "Creating main runner instance..."
  ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "$VM_USER@$VM_IP" \
    "~/runnermgr.sh --type repo --token '$RUNNER_TOKEN' --name instance"
  echo "Runner instance created at ~/runners/repo_instance"
else
  echo "Warning: No runner token found. Run giteaGetTokens.sh first, then use runnermgr.sh to create a runner instance."
fi
