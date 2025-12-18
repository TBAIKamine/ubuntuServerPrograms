#!/bin/bash
DMS_DIR="/opt/compose/docker-mailserver"
mkdir -p $DMS_DIR
DMS_GITHUB_URL="https://raw.githubusercontent.com/docker-mailserver/docker-mailserver/master"
wget "${DMS_GITHUB_URL}/compose.yaml" -O $DMS_DIR/compose.yaml
wget "${DMS_GITHUB_URL}/mailserver.env" -O $DMS_DIR/mailserver.env
# Initial ownership set temporarily; will be updated after DMS_OWNER is determined
unset DMS_GITHUB_URL

# compose.yaml edits with sed.
if [[ -n "${FQDN:-}" ]]; then
      sed -i -E "s/^([[:space:]]*hostname:[[:space:]]*)mail\.example\.com([[:space:]]*)$/\1mail.${FQDN}\2/" "$DMS_DIR/compose.yaml"
fi
sed -i '/env_file: mailserver.env/a\
    environment:\
      - SPOOF_PROTECTION=1\
      - ENABLE_POP3=1\
      - ENABLE_POLICYD_SPF=0\
      - ENABLE_CLAMAV=1\
      - ENABLE_RSPAMD=1\
      - ENABLE_RSPAMD_REDIS=1\
      - RSPAMD_LEARN=1\
      - RSPAMD_GREYLISTING=1\
      - ENABLE_AMAVIS=0\
      - ENABLE_OPENDKIM=0\
      - ENABLE_OPENDMARC=0\
      - SSL_TYPE=letsencrypt\
      - POSTFIX_MESSAGE_SIZE_LIMIT=0\
      - PFLOGSUMM_TRIGGER=logrotate\
      - PFLOGSUMM_RECIPIENT=$DMS_EMAIL\
      - LOGWATCH_INTERVAL=weekly\
      - LOGWATCH_RECIPIENT=$DMS_EMAIL\
      - REPORT_SENDER=$DMS_EMAIL\
      - ENABLE_MTA_STS=1' $DMS_DIR/compose.yaml
sed -i '/^[[:space:]]*healthcheck:/,/^[[:space:]]*retries:/d' $DMS_DIR/compose.yaml
awk -i inplace '{if ($0 ~ /^[[:space:]]*- "[0-9]+:[0-9]+"/) {match($0, /^([[:space:]]*- ")([0-9]+):([0-9]+)"/, arr); print arr[1] arr[2]+1000 ":" arr[3] "\""} else print}' $DMS_DIR/compose.yaml
sed -i '/^  mailserver:/,/^  [A-Za-z0-9_-]\+:/ { /^[[:space:]]*volumes:[[:space:]]*$/a\
      - /etc/letsencrypt/live:/etc/letsencrypt/live:ro\
      - /etc/letsencrypt/archive:/etc/letsencrypt/archive:ro
}' "$DMS_DIR/compose.yaml"

mkdir -p $DMS_DIR/docker-data/dms/{mail-data,mail-state,mail-logs,config}

ABS_PATH=$(dirname "$(realpath "$0")")

# Determine ownership based on DMS_SYS_USER setting
if [ "${DMS_SYS_USER:-false}" = "true" ]; then
  DMS_OWNER="dms"
  # Source dms.sh to create the dms system user and install the service
  source "$ABS_PATH/dms.sh"
else
  DMS_OWNER="$SUDO_USER"
fi

chown -R "$DMS_OWNER:$DMS_OWNER" $DMS_DIR
chown -R "$DMS_OWNER:$DMS_OWNER" $DMS_DIR/docker-data

# custom config overrides
cp $ABS_PATH/postfix-main.cf $DMS_DIR/docker-data/dms/config/postfix-main.cf
cp $ABS_PATH/user-patches.sh $DMS_DIR/docker-data/dms/config/user-patches.sh

chown -R "$DMS_OWNER:$DMS_OWNER" $DMS_DIR/docker-data/dms/config/{postfix-main.cf,user-patches.sh}
chmod -R 555 $DMS_DIR/docker-data/dms/config/{postfix-main.cf,user-patches.sh}