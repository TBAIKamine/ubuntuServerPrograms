#!/bin/bash
ABS_PATH=$(dirname "$(realpath "$0")")
GITEA_DIR="/opt/compose/gitea"

mkdir -p $GITEA_DIR/{data,config}
cp $ABS_PATH/gitea-compose.yaml $GITEA_DIR/compose.yaml

# Determine ownership based on GITEA_SYS_USER setting
if [ "${GITEA_SYS_USER:-false}" = "true" ]; then
  GITEA_OWNER="gitea"
  # Source gitea.sh to create the gitea system user and install the service
  source "$ABS_PATH/gitea.sh"
else
  GITEA_OWNER="$SUDO_USER"
fi

chown -R "$GITEA_OWNER:$GITEA_OWNER" $GITEA_DIR
chmod 755 -R $GITEA_DIR/gitea

if [ -n "$FQDN" ]; then
    a2sitemgr -d "gitea.$FQDN" --mode proxypass -p 3000
fi
