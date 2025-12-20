#!/bin/bash
set -e

USER=n8n
HOME_DIR=/var/lib/n8n
COMPOSE_DIR=/opt/compose/n8n
SERVICE_NAME=n8n.service
id "$USER" >/dev/null 2>&1 || useradd -r -d "$HOME_DIR" -s /usr/sbin/nologin "$USER"
UID_NUM=$(id -u "$USER")
ABS_PATH=$(dirname "$(realpath "$0")")

mkdir -p "$HOME_DIR/.config/systemd/user"
mkdir -p "$HOME_DIR/.config/environment.d"
mkdir -p "$HOME_DIR/.local/share"

ENV_FILE="$HOME_DIR/.config/environment.d/podman.conf"
ENV_LINE='DOCKER_HOST=unix:///run/user/%U/podman/podman.sock'
touch "$ENV_FILE"
grep -qxF "$ENV_LINE" "$ENV_FILE" 2>/dev/null || echo "$ENV_LINE" >>"$ENV_FILE"
chown -R "$USER:$USER" "$HOME_DIR"

loginctl enable-linger "$USER"

grep -q "^$USER:" /etc/subuid || usermod --add-subuids 65536 "$USER"
grep -q "^$USER:" /etc/subgid || usermod --add-subgids 65536 "$USER"

# Create the n8n_data volume as the n8n user
sudo -u "$USER" -H bash -c "
export XDG_RUNTIME_DIR=/run/user/$UID_NUM
podman volume create n8n_data
"

chown -R "$USER:$USER" "$COMPOSE_DIR"

TARGET_UNIT="$HOME_DIR/.config/systemd/user/$SERVICE_NAME"
ESC_COMPOSE_DIR=$(printf '%s' "$COMPOSE_DIR" | sed 's/[&/]/\\&/g')
sed "s|\\\$COMPOSE_DIR|$ESC_COMPOSE_DIR|g" "$ABS_PATH/$SERVICE_NAME" > "$TARGET_UNIT"

chown "$USER:$USER" "$TARGET_UNIT"

systemctl start user@$UID_NUM.service

sudo -u "$USER" -H bash -c "
cd '$HOME_DIR' || exit 1
XDG_RUNTIME_DIR='/run/user/$UID_NUM' systemctl --user daemon-reload
"

sudo -u "$USER" -H bash -c "
cd '$HOME_DIR' || exit 1
XDG_RUNTIME_DIR='/run/user/$UID_NUM' systemctl --user enable --now '$SERVICE_NAME'
"

sudo -u "$USER" -H bash -c "
export XDG_RUNTIME_DIR=/run/user/$UID_NUM
systemctl --user enable --now podman.socket
"
