#!/bin/bash

# virt-install-ubuntu: Create Ubuntu 24.04 VMs with auto-incrementing index
# Usage: virt-install-ubuntu [--name NAME] [--ip IP] [--uninstall NAME]

set -e

# Base values
BASE_NAME="ubuntu-vm"
BASE_IP_PREFIX="192.168.122."
NETWORK="default"
SCRIPT_DIR="$(dirname "$(realpath "$0")")"

# Get actual user's home directory
if [ -n "$SUDO_USER" ]; then
    USER_HOME=$(getent passwd $SUDO_USER | cut -d: -f6)
    RUN_USER=$SUDO_USER
else
    USER_HOME=$HOME
    RUN_USER=$USER
fi

show_help() {
    if [ -f "$SCRIPT_DIR/kvm.d/usage.txt" ]; then
        cat "$SCRIPT_DIR/kvm.d/usage.txt"
    else
        echo "virt-install-ubuntu - Create Ubuntu 24.04 VMs"
        echo ""
        echo "Usage: virt-install-ubuntu [--name NAME] [--ip IP] [--uninstall NAME] [-h|--help]"
        echo ""
        echo "Run 'virt-install-ubuntu --help' after proper installation for full documentation."
    fi
}

uninstall_vm() {
    local vm_name="$1"
    
    if [ -z "$vm_name" ]; then
        echo "Error: VM name required for --uninstall" >&2
        exit 1
    fi
    
    # Check if VM exists
    if ! virsh dominfo "$vm_name" &>/dev/null; then
        echo "Error: VM '$vm_name' does not exist." >&2
        echo "" >&2
        echo "Available VMs:" >&2
        virsh list --all --name | grep -v '^$' | sed 's/^/  /' >&2
        exit 1
    fi
    
    echo "Uninstalling VM: $vm_name"
    
    # Stop VM if running
    if virsh domstate "$vm_name" 2>/dev/null | grep -q "running"; then
        echo "  Stopping VM..."
        virsh destroy "$vm_name" 2>/dev/null || true
    fi
    
    # Get storage paths before undefining
    VM_DIR="/var/lib/libvirt/images/$vm_name"
    
    # Remove SSH known_hosts entry for this VM's IP (to prevent host key conflicts on reinstall)
    if [ -f "$VM_DIR/network-config.yaml" ]; then
        local vm_ip=$(grep -oP '(?<=- )\d+\.\d+\.\d+\.\d+(?=/24)' "$VM_DIR/network-config.yaml" 2>/dev/null | head -1)
        if [ -n "$vm_ip" ]; then
            echo "  Removing SSH known_hosts entry for $vm_ip..."
            ssh-keygen -R "$vm_ip" -f /root/.ssh/known_hosts 2>/dev/null || true
        fi
    fi
    
    # Undefine VM and remove storage
    echo "  Removing VM definition and storage..."
    virsh undefine "$vm_name" --remove-all-storage 2>/dev/null || virsh undefine "$vm_name" 2>/dev/null || true
    
    # Clean up directory if it still exists
    if [ -d "$VM_DIR" ]; then
        echo "  Cleaning up directory: $VM_DIR"
        rm -rf "$VM_DIR"
    fi
    
    echo ""
    echo "VM '$vm_name' has been completely removed."
}

# Parse arguments
VM_NAME=""
VM_IP=""
UNINSTALL_VM=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --name)
            VM_NAME="$2"
            shift 2
            ;;
        --ip)
            VM_IP="$2"
            shift 2
            ;;
        --uninstall)
            UNINSTALL_VM="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Use --help for usage information" >&2
            exit 1
            ;;
    esac
done

# Handle uninstall
if [ -n "$UNINSTALL_VM" ]; then
    uninstall_vm "$UNINSTALL_VM"
    exit 0
fi

# Function to get all used IPs by our VMs
get_used_ips() {
    local used_ips=()
    for vm in $(virsh list --all --name 2>/dev/null | grep "^${BASE_NAME}-"); do
        local vm_dir="/var/lib/libvirt/images/$vm"
        if [ -f "$vm_dir/network-config.yaml" ]; then
            local ip=$(grep -oP '(?<=- )\d+\.\d+\.\d+\.\d+(?=/24)' "$vm_dir/network-config.yaml" 2>/dev/null | head -1)
            [ -n "$ip" ] && used_ips+=("$ip")
        fi
    done
    echo "${used_ips[@]}"
}

# Function to check if a VM name exists
vm_exists() {
    virsh dominfo "$1" &>/dev/null
}

# Function to get next available IP (2-254, skipping gateway .1)
# Also checks that the derived VM name is available
get_next_ip() {
    local used_ips=($(get_used_ips))
    
    for i in $(seq 2 254); do
        local test_ip="${BASE_IP_PREFIX}${i}"
        local is_used=false
        
        # Check if IP is already used
        for used in "${used_ips[@]}"; do
            if [ "$used" = "$test_ip" ]; then
                is_used=true
                break
            fi
        done
        
        # Also check if the derived VM name would conflict
        if [ "$is_used" = false ]; then
            local derived_name=$(printf "${BASE_NAME}-%03d" $i)
            if vm_exists "$derived_name"; then
                is_used=true
            fi
        fi
        
        if [ "$is_used" = false ]; then
            echo "$test_ip"
            return
        fi
    done
    
    echo ""
}

# Auto-generate IP first (if not provided)
if [ -z "$VM_IP" ]; then
    VM_IP=$(get_next_ip)
    if [ -z "$VM_IP" ]; then
        echo "Error: No available IPs in the 192.168.122.0/24 subnet." >&2
        exit 1
    fi
    echo "Auto-generated IP: $VM_IP"
fi

# Validate IP is in correct subnet
if [[ ! "$VM_IP" =~ ^192\.168\.122\.[0-9]+$ ]]; then
    echo "Error: IP must be in the 192.168.122.0/24 subnet" >&2
    exit 1
fi

# Extract last octet and validate range
LAST_OCTET="${VM_IP##*.}"
if [ "$LAST_OCTET" -lt 2 ] || [ "$LAST_OCTET" -gt 254 ]; then
    echo "Error: IP last octet must be between 2 and 254 (got $LAST_OCTET)" >&2
    exit 1
fi

# Auto-generate VM name from IP's last octet if not provided
if [ -z "$VM_NAME" ]; then
    VM_NAME=$(printf "${BASE_NAME}-%03d" $LAST_OCTET)
    echo "Auto-generated VM name: $VM_NAME"
fi

# Check if VM already exists
if vm_exists "$VM_NAME"; then
    echo "Error: VM '$VM_NAME' already exists." >&2
    echo "Use 'virt-install-ubuntu --uninstall $VM_NAME' to remove it first." >&2
    exit 1
fi

# Check if IP is already in use by another VM
for existing_vm in $(virsh list --all --name 2>/dev/null); do
    local_vm_dir="/var/lib/libvirt/images/$existing_vm"
    if [ -f "$local_vm_dir/network-config.yaml" ]; then
        existing_ip=$(grep -oP '(?<=- )\d+\.\d+\.\d+\.\d+(?=/24)' "$local_vm_dir/network-config.yaml" 2>/dev/null | head -1)
        if [ "$existing_ip" = "$VM_IP" ]; then
            echo "Error: IP '$VM_IP' is already in use by VM '$existing_vm'." >&2
            exit 1
        fi
    fi
done

# Check for SSH key
SSH_KEY_PATH="$USER_HOME/.ssh/id_ed25519"
if [ ! -f "$SSH_KEY_PATH" ]; then
    echo "Generating SSH key for VM access..."
    sudo -u $RUN_USER ssh-keygen -t ed25519 -f "$SSH_KEY_PATH" -N ""
fi
PUBKEY=$(cat "${SSH_KEY_PATH}.pub")

# Create temporary directory for downloads and file creation
TEMP_DIR=$(mktemp -d -t kvm-setup-XXXXXX)
trap "rm -rf $TEMP_DIR" EXIT

echo "Setting up VM: $VM_NAME with IP: $VM_IP"

# Download Ubuntu 24.04 cloud image if not cached
IMAGES_DIR="/var/lib/libvirt/images"
CLOUD_IMG="$IMAGES_DIR/ubuntu-24.04-server-cloudimg-amd64.img"

if [ ! -f "$CLOUD_IMG" ]; then
    echo "Downloading Ubuntu 24.04 cloud image..."
    wget -q --show-progress -O "$CLOUD_IMG" \
        https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img
fi

# Create VM-specific directory
VM_DIR="$IMAGES_DIR/$VM_NAME"
mkdir -p "$VM_DIR"

# Create a copy of the base image for this VM
echo "Creating VM disk..."
cp "$CLOUD_IMG" "$VM_DIR/disk.qcow2"
qemu-img resize "$VM_DIR/disk.qcow2" 100G

# Create cloud-init config
cat > "$TEMP_DIR/user-data" <<EOF
#cloud-config
users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: sudo
    shell: /bin/bash
    ssh_authorized_keys:
      - $PUBKEY
EOF

cat > "$TEMP_DIR/meta-data" <<EOF
instance-id: $VM_NAME
local-hostname: $VM_NAME
EOF

cat > "$TEMP_DIR/network-config" <<EOF
version: 2
ethernets:
  main:
    match:
      driver: virtio_net
    addresses:
      - $VM_IP/24
    routes:
      - to: default
        via: 192.168.122.1
    nameservers:
      addresses:
        - 8.8.8.8
        - 8.8.4.4
EOF

# Create cloud-init seed image
cloud-localds --network-config="$TEMP_DIR/network-config" "$VM_DIR/seed.img" "$TEMP_DIR/user-data" "$TEMP_DIR/meta-data"

# Save network config for later reference (to track used IPs)
cp "$TEMP_DIR/network-config" "$VM_DIR/network-config.yaml"

# Set proper permissions
chown -R libvirt-qemu:kvm "$VM_DIR"
chmod -R 750 "$VM_DIR"

# Install VM with dynamic allocations
echo "Creating VM..."
virt-install \
    --name "$VM_NAME" \
    --memory 4096,maxmemory=16384 \
    --vcpus 6 \
    --disk path="$VM_DIR/disk.qcow2",format=qcow2 \
    --disk path="$VM_DIR/seed.img",device=cdrom \
    --os-variant ubuntu24.04 \
    --virt-type kvm \
    --graphics none \
    --network network=$NETWORK \
    --import \
    --noautoconsole
