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