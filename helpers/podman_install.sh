#!/bin/bash
apt install podman podman-compose -y
sed -i '/^unqualified-search-registries = \[/ s/\]$/, "docker.io"]/' /etc/containers/registries.conf
alias docker='podman'
echo "alias docker='podman'" >> ~/.bashrc
systemctl --user -M user@ enable --now podman.socket
systemctl --user -M user@ start --now podman.socket
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
podman system migrate
