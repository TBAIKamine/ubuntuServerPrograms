#!/bin/bash
ABS_PATH=$(dirname "$(realpath "$0")")
N8N_DIR="/opt/compose/n8n"

mkdir -p $N8N_DIR
cp $ABS_PATH/n8n-compose.yaml $N8N_DIR/compose.yaml

n8n_volume_hook() {
  local uid_num=$(id -u n8n)
  sudo -u n8n -H bash -c "XDG_RUNTIME_DIR='/run/user/$uid_num' podman volume create n8n_data" 2>/dev/null || true
}
export -f n8n_volume_hook

if [ "${N8N_SYS_USER:-false}" = "true" ]; then
  N8N_OWNER="n8n"
  apt install -y acl
  podmgr setup --user n8n --hook n8n_volume_hook
else
  N8N_OWNER="$SUDO_USER"
  podman volume create n8n_data
fi

chown -R "$N8N_OWNER:$N8N_OWNER" $N8N_DIR

if [ -n "$FQDN" ]; then
  a2sitemgr -d "n8n.$FQDN" --mode proxypass -p 5678
fi
