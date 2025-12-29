#!/bin/bash

# KVM Setup Script
# Installs KVM/QEMU virtualization and the virt-install-ubuntu helper command

set -e

ABS_PATH=$(dirname "$(realpath "$0")")

echo "Installing KVM/QEMU virtualization packages..."

# Update and install required packages
apt update
apt install -y qemu-kvm libvirt-daemon-system libvirt-clients bridge-utils virtinst cloud-image-utils openssh-client

# Enable libvirt service
systemctl enable --now libvirtd

# Add user to virtualization groups
if [ -n "$SUDO_USER" ]; then
    usermod -aG libvirt,kvm $SUDO_USER
    echo "Added $SUDO_USER to libvirt and kvm groups"
fi

# Create images directory if it doesn't exist
mkdir -p /var/lib/libvirt/images
chown libvirt-qemu:kvm /var/lib/libvirt/images
chmod 755 /var/lib/libvirt/images

# Install the virt-install-ubuntu command
echo "Installing virt-install-ubuntu command..."
mkdir -p /usr/local/bin/kvm.d
cp "$ABS_PATH/kvm.d/virt-install-ubuntu.sh" /usr/local/bin/kvm.d/
cp "$ABS_PATH/kvm.d/usage.txt" /usr/local/bin/kvm.d/
chmod +x /usr/local/bin/kvm.d/virt-install-ubuntu.sh
ln -sf /usr/local/bin/kvm.d/virt-install-ubuntu.sh /usr/local/bin/virt-install-ubuntu
virt-install-ubuntu --name ubuntu-vm

# Create SSH config for ubuntu-vm (overwritten on each reinstall)
echo "Setting up SSH config for ubuntu-vm..."
if [ -n "$SUDO_USER" ]; then
    SUDO_USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    SSH_DIR="$SUDO_USER_HOME/.ssh"
    SSH_CONFIG_D="$SSH_DIR/config.d"
    SSH_CONFIG="$SSH_DIR/config"
    
    # Create .ssh and config.d directories if needed
    mkdir -p "$SSH_CONFIG_D"
    chown "$SUDO_USER:$SUDO_USER" "$SSH_DIR" "$SSH_CONFIG_D"
    chmod 700 "$SSH_DIR"
    chmod 755 "$SSH_CONFIG_D"
    
    # Create/overwrite the ubuntu-vm config file
    cat > "$SSH_CONFIG_D/ubuntu-vm.conf" << 'EOF'
Host ubuntu-vm
    HostName 192.168.122.2
    User ubuntu
    IdentityFile ~/.ssh/id_ed25519
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    LogLevel ERROR
EOF
    chown "$SUDO_USER:$SUDO_USER" "$SSH_CONFIG_D/ubuntu-vm.conf"
    chmod 600 "$SSH_CONFIG_D/ubuntu-vm.conf"
    
    # Ensure main config includes config.d directory
    if [ ! -f "$SSH_CONFIG" ]; then
        echo "Include config.d/*.conf" > "$SSH_CONFIG"
        chown "$SUDO_USER:$SUDO_USER" "$SSH_CONFIG"
        chmod 600 "$SSH_CONFIG"
    elif ! grep -q "Include config.d/\*.conf" "$SSH_CONFIG" 2>/dev/null; then
        # Prepend Include directive to existing config
        sed -i '1i Include config.d/*.conf' "$SSH_CONFIG"
    fi
    
    echo "SSH config created: ssh ubuntu-vm"
fi