#!/bin/sh

# Create temporary directory for downloads and file creation
TEMP_DIR=$(mktemp -d -t kvm-setup-XXXXXX)
trap "rm -rf $TEMP_DIR" EXIT

# Define static IP for the VM
VM_STATIC_IP="192.168.122.100"

# Update and install required packages
sudo apt update
sudo apt install -y qemu-kvm libvirt-daemon-system libvirt-clients bridge-utils virtinst cloud-image-utils openssh-client

# Enable libvirt service and add user to groups
sudo systemctl enable --now libvirtd
sudo usermod -aG libvirt,kvm $SUDO_USER

# Get actual user's home directory
USER_HOME=$(getent passwd $SUDO_USER | cut -d: -f6)

# Generate SSH key for VM access (as the actual user)
sudo -u $SUDO_USER ssh-keygen -t ed25519 -f $USER_HOME/.ssh/id_ed25519 -N ""

PUBKEY=$(cat $USER_HOME/.ssh/id_ed25519.pub)

# Download Ubuntu 24.04 cloud image to temp directory
cd $TEMP_DIR
wget https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img

# Resize image to 100G
qemu-img resize ubuntu-24.04-server-cloudimg-amd64.img 100G

# Create cloud-init config
cat > user-data <<EOF
#cloud-config
users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: sudo
    shell: /bin/bash
    ssh_authorized_keys:
      - $PUBKEY
EOF

cat > meta-data <<EOF
instance-id: ubuntu-vm
local-hostname: ubuntu-vm
EOF

cat > network-config <<EOF
version: 2
ethernets:
  main:
    match:
      driver: virtio_net
    addresses:
      - $VM_STATIC_IP/24
    routes:
      - to: default
        via: 192.168.122.1
    nameservers:
      addresses:
        - 8.8.8.8
        - 8.8.4.4
EOF

cloud-localds --network-config=network-config seed.img user-data meta-data

# Create permanent storage directory
sudo mkdir -p /var/lib/libvirt/images/ubuntu-vm

# Move images from temp to permanent location
sudo mv $TEMP_DIR/ubuntu-24.04-server-cloudimg-amd64.img /var/lib/libvirt/images/ubuntu-vm/
sudo mv $TEMP_DIR/seed.img /var/lib/libvirt/images/ubuntu-vm/

# Set proper permissions
sudo chown -R libvirt-qemu:kvm /var/lib/libvirt/images/ubuntu-vm
sudo chmod -R 750 /var/lib/libvirt/images/ubuntu-vm

# Install VM with dynamic allocations (ballooning enabled)
virt-install \
  --name ubuntu-vm \
  --memory 4096,maxmemory=16384 \
  --vcpus 6 \
  --disk path=/var/lib/libvirt/images/ubuntu-vm/ubuntu-24.04-server-cloudimg-amd64.img,format=qcow2 \
  --disk path=/var/lib/libvirt/images/ubuntu-vm/seed.img,device=cdrom \
  --os-variant ubuntu24.04 \
  --virt-type kvm \
  --graphics none \
  --network network=default \
  --import \
  --noautoconsole

# Wait for VM to boot up
sleep 10
echo "to connect, run:"
echo "sudo ssh ubuntu@$VM_STATIC_IP"
