#!/bin/bash
set -e

USER=dms
HOME_DIR=/var/lib/dms
COMPOSE_DIR=/opt/compose/docker-mailserver
SERVICE_NAME=dms.service
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

setfacl -R -m u:$USER:rx /etc/letsencrypt/live
setfacl -R -m u:$USER:rx /etc/letsencrypt/archive
setfacl -R -d -m u:$USER:rx /etc/letsencrypt/live
setfacl -R -d -m u:$USER:rx /etc/letsencrypt/archive

SUBID_RANGE=$(fsubid)
grep -q "^$USER:" /etc/subuid || usermod --add-subuids "$SUBID_RANGE" "$USER"
grep -q "^$USER:" /etc/subgid || usermod --add-subgids "$SUBID_RANGE" "$USER"
sudo -u "$USER" -H bash -c "podman system migrate"

chown -R "$USER:$USER" "$COMPOSE_DIR"

# Add journald logging driver to compose file
sed -i '/^services:/,/^[^ ]/ { /^  [a-z]/a\    logging:\n      driver: journald
}' "$COMPOSE_DIR/docker-compose.yaml"

TARGET_UNIT="$HOME_DIR/.config/systemd/user/$SERVICE_NAME"
ESC_COMPOSE_DIR=$(printf '%s' "$COMPOSE_DIR" | sed 's/[&/]/\\&/g')
sed "s|\\\$COMPOSE_DIR|$ESC_COMPOSE_DIR|g" "$ABS_PATH/$SERVICE_NAME" > "$TARGET_UNIT"

chown "$USER:$USER" "$TARGET_UNIT"

systemctl start user@$UID_NUM.service

# Wait for user runtime directory to be ready
while [ ! -d "/run/user/$UID_NUM" ]; do
    sleep 1
done

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
