#!/bin/bash
apt install podman podman-compose -y
sed -i '/^unqualified-search-registries = \[/ s/\]$/, "docker.io"]/' /etc/containers/registries.conf
echo "alias docker='podman'" >> /home/user/.bashrc
echo 'export DOCKER_HOST=unix:///run/user/$UID/podman/podman.sock' >> /home/user/.bashrc
loginctl enable-linger user
systemctl --user -M user@ enable --now podman.socket
systemctl --user -M user@ start --now podman.socket
mkdir -p /home/user/.config/containers/
touch /home/user/.config/containers/containers.conf
tee -a /home/user/.config/containers/containers.conf <<EOF
[containers]
# Maximum size of log files (in bytes)
# Negative numbers indicate no size limit (-1 is the default).
# Example: 50MB = 52428800 bytes
log_size_max = 52428800
EOF
chown -R user:user /home/user/.config/containers/containers.conf
chmod 644 /home/user/.config/containers/containers.conf
sudo -u user podman system migrate
