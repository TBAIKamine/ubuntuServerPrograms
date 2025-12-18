#!/bin/bash
apt install podman podman-compose -y
# Match the key even if indented or preceded by a comment "# ",
# then append "\"docker.io\"" before the closing bracket.
sed -i -E 's/^([[:space:]]*)(# )?unqualified-search-registries[[:space:]]*=[[:space:]]*\[.*\].*/\1unqualified-search-registries = ["docker.io"]/g' /etc/containers/registries.conf
echo "alias docker='podman'" >> /home/$SUDO_USER/.bashrc
echo 'export DOCKER_HOST=unix:///run/user/$UID/podman/podman.sock' >> /home/$SUDO_USER/.bashrc
loginctl enable-linger $SUDO_USER
systemctl --user -M $SUDO_USER@ enable --now podman.socket
systemctl --user -M $SUDO_USER@ start --now podman.socket
mkdir -p /home/$SUDO_USER/.config/containers/
touch /home/$SUDO_USER/.config/containers/containers.conf
tee -a /home/$SUDO_USER/.config/containers/containers.conf <<EOF
[containers]
# Maximum size of log files (in bytes)
# Negative numbers indicate no size limit (-1 is the default).
# Example: 50MB = 52428800 bytes
log_size_max = 52428800
EOF
chown -R "$SUDO_USER:$SUDO_USER" /home/$SUDO_USER/.config/containers/containers.conf
chmod 644 /home/$SUDO_USER/.config/containers/containers.conf
sudo -u $SUDO_USER podman system migrate
