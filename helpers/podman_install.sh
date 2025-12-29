#!/bin/bash
# Install crun from source (required for podman 5+)
ABS_PATH=$(dirname "$(realpath "$0")")
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
bash "$ABS_PATH/crun.sh"

# Install podman from source (latest version from GitHub)
bash "$ABS_PATH/podman-5.7.1.sh"

# Install podman-compose from apt
apt install podman-compose -y

# Match the key even if indented or preceded by a comment "# ",
# then append "\"docker.io\"" before the closing bracket.
sed -i -E 's/^([[:space:]]*)(# )?unqualified-search-registries[[:space:]]*=[[:space:]]*\[.*\].*/\1unqualified-search-registries = ["docker.io"]/g' /etc/containers/registries.conf
echo "alias docker='podman'" >> /home/$SUDO_USER/.bashrc
echo 'export DOCKER_HOST=unix:///run/user/$UID/podman/podman.sock' >> /home/$SUDO_USER/.bashrc
loginctl enable-linger $SUDO_USER
# Start the user session service (required on fresh install - enable-linger alone doesn't start it)
SUDO_UID=$(id -u "$SUDO_USER")
systemctl start "user@$SUDO_UID.service" 2>/dev/null || true

# Wait for runtime directory to be created
for i in {1..30}; do
  [ -d "/run/user/$SUDO_UID" ] && break
  sleep 1
done

# Now enable the podman socket for the user
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