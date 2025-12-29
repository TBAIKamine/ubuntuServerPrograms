#!/bin/bash
# Install crun from source (required for podman 5+)
ABS_PATH=$(dirname "$(realpath "$0")")

# Function to create equivs dummy package to satisfy apt dependencies
create_equivs_package() {
    local pkg_name="$1"
    local pkg_version="$2"
    local pkg_desc="$3"
    
    # Install equivs if not present
    if ! command -v equivs-build >/dev/null 2>&1; then
        apt install equivs -y
    fi
    
    local equivs_dir=$(mktemp -d)
    local control_file="$equivs_dir/${pkg_name}-equivs"
    
    cat > "$control_file" <<EOF
Section: misc
Priority: optional
Standards-Version: 3.9.2

Package: ${pkg_name}
Version: ${pkg_version}
Maintainer: Local Admin <root@localhost>
Architecture: all
Description: ${pkg_desc}
 Dummy package to satisfy dependencies.
 The real ${pkg_name} is installed manually from source.
EOF
    
    pushd "$equivs_dir" > /dev/null
    equivs-build "$control_file"
    dpkg -i "${pkg_name}_${pkg_version}_all.deb"
    popd > /dev/null
    rm -rf "$equivs_dir"
    
    # Mark the package as hold to prevent apt from replacing it
    apt-mark hold "$pkg_name"
    echo "Created and installed equivs dummy package for $pkg_name"
}

# Remove apt-installed podman and crun if present (before manual install)
echo "Removing apt-installed podman and crun if present..."
apt-mark unhold podman crun 2>/dev/null || true
apt purge -y podman crun 2>/dev/null || true
apt autoremove -y 2>/dev/null || true

# Check if crun exists and version is >= 1.15
if command -v crun >/dev/null 2>&1; then
    CRUN_VERSION=$(crun --version | awk '{print $2}')
    # Compare versions using sort -V
    if [ "$(printf '%s\n' "1.15" "$CRUN_VERSION" | sort -V | head -n1)" = "1.15" ]; then
        echo "crun $CRUN_VERSION is already installed and >= 1.15"
        SKIP_CRUN_INSTALL=1
    fi
fi

if [ -z "$SKIP_CRUN_INSTALL" ]; then
    bash "$ABS_PATH/crun.sh"
fi

# Create equivs dummy package for crun
CRUN_INSTALLED_VERSION=$(crun --version 2>/dev/null | head -1 | awk '{print $2}' || echo "1.15")
create_equivs_package "crun" "${CRUN_INSTALLED_VERSION}" "crun OCI runtime (manually installed from source)"

# Install podman from source (latest version from GitHub)
bash "$ABS_PATH/podman-5.7.1.sh"

# Create equivs dummy package for podman
PODMAN_INSTALLED_VERSION=$(podman --version 2>/dev/null | awk '{print $3}' || echo "5.7.1")
create_equivs_package "podman" "${PODMAN_INSTALLED_VERSION}" "Podman container engine (manually installed from source)"

# Install podman-compose from apt
apt install podman-compose -y

# Match the key even if indented or preceded by a comment "# ",
# then append "\"docker.io\"" before the closing bracket.
sed -i -E 's/^([[:space:]]*)(# )?unqualified-search-registries[[:space:]]*=[[:space:]]*\[.*\].*/\1unqualified-search-registries = ["docker.io"]/g' /etc/containers/registries.conf
echo "alias docker='podman'" >> /home/$SUDO_USER/.bashrc
echo 'export DOCKER_HOST=unix:///run/user/$UID/podman/podman.sock' >> /home/$SUDO_USER/.bashrc
loginctl enable-linger $SUDO_USER
systemctl --user -M $SUDO_USER@ enable --now podman.socket
systemctl --user -M $SUDO_USER@ start --now podman.socket
mkdir -p /home/$SUDO_USER/.config/containers/
tee /home/$SUDO_USER/.config/containers/containers.conf <<EOF
[containers]
# Maximum size of log files (in bytes)
# Negative numbers indicate no size limit (-1 is the default).
# Example: 50MB = 52428800 bytes
log_size_max = 52428800
EOF
chown -R "$SUDO_USER:$SUDO_USER" /home/$SUDO_USER/.config/containers/containers.conf
chmod 644 /home/$SUDO_USER/.config/containers/containers.conf
sudo -u $SUDO_USER podman system migrate