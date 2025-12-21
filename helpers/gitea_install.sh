#!/bin/bash
ABS_PATH=$(dirname "$(realpath "$0")")
GITEA_DIR="/opt/compose/gitea"

mkdir -p $GITEA_DIR/{data,config}
cp $ABS_PATH/gitea-compose.yaml $GITEA_DIR/compose.yaml

if [ "${GITEA_SYS_USER:-false}" = "true" ]; then
  GITEA_OWNER="gitea"
  apt install -y acl
  podmgr setup --user gitea
else
  GITEA_OWNER="$SUDO_USER"
fi

chown -R "$GITEA_OWNER:$GITEA_OWNER" $GITEA_DIR

if [ -n "$FQDN" ]; then
  a2sitemgr -d "gitea.$FQDN" --mode proxypass -p 3000
fi
