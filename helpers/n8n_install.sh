#!/bin/bash
ABS_PATH=$(dirname "$(realpath "$0")")
N8N_DIR="/opt/compose/n8n"

mkdir -p $N8N_DIR
cp $ABS_PATH/n8n-compose.yaml $N8N_DIR/compose.yaml

# Determine ownership based on N8N_SYS_USER setting
if [ "${N8N_SYS_USER:-false}" = "true" ]; then
  N8N_OWNER="n8n"
  apt install -y acl
  source "$ABS_PATH/n8n.sh"
else
  N8N_OWNER="$SUDO_USER"
  # Create volume as regular user
  podman volume create n8n_data
fi

chown -R "$N8N_OWNER:$N8N_OWNER" $N8N_DIR

if [ -n "$FQDN" ]; then
    a2sitemgr -d "n8n.$FQDN" --mode proxypass -p 5678
fi
