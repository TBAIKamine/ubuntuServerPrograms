#!/bin/bash
DMS_DIR="/opt/compose/docker-mailserver"
mkdir -p $DMS_DIR

# Determine owner early - needed for chown calls below
if [ "${DMS_SYS_USER:-false}" = "true" ]; then
  DMS_OWNER="dms"
else
  DMS_OWNER="$SUDO_USER"
fi

DMS_GITHUB_URL="https://raw.githubusercontent.com/docker-mailserver/docker-mailserver/master"
wget "${DMS_GITHUB_URL}/compose.yaml" -O $DMS_DIR/compose.yaml
wget "${DMS_GITHUB_URL}/mailserver.env" -O $DMS_DIR/mailserver.env
unset DMS_GITHUB_URL

# Apply DMS_FQDN to compose file as mail.${DMS_FQDN}
if [[ -n "${DMS_FQDN:-}" ]]; then
  sed -i -E "s/^([[:space:]]*hostname:[[:space:]]*)mail\.example\.com([[:space:]]*)$/\1mail.${DMS_FQDN}\2/" "$DMS_DIR/compose.yaml"
fi

# Determine notification email: use DMS_EMAIL if set, otherwise fallback to noemail@DMS_FQDN
if [[ -n "${DMS_EMAIL:-}" ]]; then
  NOTIFICATION_EMAIL="$DMS_EMAIL"
elif [[ -n "${DMS_FQDN:-}" ]]; then
  NOTIFICATION_EMAIL="noemail@${DMS_FQDN}"
fi

sed -i '/container_name:/a\
    dns:\
      - 1.1.1.1\
      - 8.8.8.8' "$DMS_DIR/compose.yaml"
sed -i "/env_file: mailserver.env/a\\
    environment:\\
      - SPOOF_PROTECTION=1\\
      - ENABLE_POP3=1\\
      - ENABLE_POLICYD_SPF=0\\
      - ENABLE_CLAMAV=1\\
      - ENABLE_RSPAMD=1\\
      - ENABLE_RSPAMD_REDIS=1\\
      - RSPAMD_LEARN=1\\
      - RSPAMD_GREYLISTING=1\\
      - ENABLE_AMAVIS=0\\
      - ENABLE_OPENDKIM=0\\
      - ENABLE_OPENDMARC=0\\
      - SSL_TYPE=letsencrypt\\
      - POSTFIX_MESSAGE_SIZE_LIMIT=0\\
      - PFLOGSUMM_TRIGGER=logrotate\\
      - PFLOGSUMM_RECIPIENT=${NOTIFICATION_EMAIL}\\
      - LOGWATCH_INTERVAL=weekly\\
      - LOGWATCH_RECIPIENT=${NOTIFICATION_EMAIL}\\
      - REPORT_SENDER=${NOTIFICATION_EMAIL}\\
      - ENABLE_MTA_STS=1" $DMS_DIR/compose.yaml
sed -i '/^[[:space:]]*healthcheck:/,/^[[:space:]]*retries:/d' $DMS_DIR/compose.yaml
awk -i inplace '{if ($0 ~ /^[[:space:]]*- "[0-9]+:[0-9]+"/) {match($0, /^([[:space:]]*- ")([0-9]+):([0-9]+)"/, arr); print arr[1] arr[2]+1000 ":" arr[3] "\""} else print}' $DMS_DIR/compose.yaml
sed -i '/^  mailserver:/,/^  [A-Za-z0-9_-]\+:/ { /^[[:space:]]*volumes:[[:space:]]*$/a\
      - /etc/letsencrypt/live:/etc/letsencrypt/live:ro\
      - /etc/letsencrypt/archive:/etc/letsencrypt/archive:ro
}' "$DMS_DIR/compose.yaml"

mkdir -p $DMS_DIR/docker-data/dms/{mail-data,mail-state,mail-logs,config}

ABS_PATH=$(dirname "$(realpath "$0")")
chown -R "$DMS_OWNER:$DMS_OWNER" $DMS_DIR

cp $ABS_PATH/postfix-main.cf $DMS_DIR/docker-data/dms/config/postfix-main.cf
cp $ABS_PATH/user-patches.sh $DMS_DIR/docker-data/dms/config/user-patches.sh

chown -R "$DMS_OWNER:$DMS_OWNER" $DMS_DIR/docker-data/dms/config/{postfix-main.cf,user-patches.sh}
chmod -R 555 $DMS_DIR/docker-data/dms/config/{postfix-main.cf,user-patches.sh}

dms_acl_hook() {
  if [ -d /etc/letsencrypt/live ]; then
    setfacl -R -m u:dms:rx /etc/letsencrypt/live
    setfacl -R -d -m u:dms:rx /etc/letsencrypt/live
  fi
  if [ -d /etc/letsencrypt/archive ]; then
    setfacl -R -m u:dms:rx /etc/letsencrypt/archive
    setfacl -R -d -m u:dms:rx /etc/letsencrypt/archive
  fi
}

export -f dms_acl_hook

echo "=== DMS Container Setup ==="
echo "DMS_SYS_USER: ${DMS_SYS_USER:-false}"
echo "DMS_OWNER: $DMS_OWNER"
echo "DMS_DIR: $DMS_DIR"
echo "SUDO_USER: ${SUDO_USER:-not set}"

if [ "${DMS_SYS_USER:-false}" = "true" ]; then
  echo "Starting container as system user 'dms' via podmgr..."
  apt install -y acl
  echo "Running: podmgr setup --user dms --compose-dir $DMS_DIR --hook dms_acl_hook"
  podmgr setup --user dms --compose-dir "$DMS_DIR" --hook dms_acl_hook 2>&1
  echo "podmgr exit code: $?"
else
  echo "Starting container as user '$SUDO_USER' via podman-compose..."
  echo "Running: cd '$DMS_DIR' && podman-compose up -d"
  sudo -u "$SUDO_USER" -H bash -c "cd '$DMS_DIR' && podman-compose up -d" 2>&1
  echo "podman-compose exit code: $?"
fi

# Check container status right after start attempt
echo "=== Checking container status after start ==="
if [ "${DMS_SYS_USER:-false}" = "true" ]; then
  sudo -u dms -H bash -c "cd '$DMS_DIR' && source /var/lib/dms/.config/environment.d/podman.conf 2>/dev/null; podman ps -a" 2>&1 || echo "Failed to check container status for dms user"
else
  sudo -u "$SUDO_USER" -H bash -c "cd '$DMS_DIR' && podman ps -a" 2>&1 || echo "Failed to check container status for $SUDO_USER"
fi
echo "=== End container status check ==="

# Add email account if email and password were provided
if [ -n "${DMS_EMAIL:-}" ] && [ -n "${DMS_EMAIL_PASSWORD:-}" ]; then
  echo "Adding email account $DMS_EMAIL to mailserver..."
  # Determine which user owns the container
  if [ "${DMS_SYS_USER:-false}" = "true" ]; then
    DMS_EXEC_USER="dms"
    DMS_UID=$(id -u dms 2>/dev/null)
    DMS_ENV_FILE="/var/lib/dms/.config/environment.d/podman.conf"
  else
    DMS_EXEC_USER="$SUDO_USER"
    DMS_UID=$(id -u "$SUDO_USER" 2>/dev/null)
    DMS_ENV_FILE=""
  fi
  
  # Wait for mailserver container to be running (dynamic wait with timeout)
  MAX_WAIT=300  # 5 minutes max (image pull + container start + service init)
  WAIT_COUNT=0
  echo "Waiting for mailserver container to be ready..."
  while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
    if [ -n "$DMS_ENV_FILE" ] && [ -f "$DMS_ENV_FILE" ]; then
      # System user with env file
      CONTAINER_RUNNING=$(sudo -u "$DMS_EXEC_USER" -H bash -c "cd '$DMS_DIR' && source '$DMS_ENV_FILE' && podman ps --filter 'name=mailserver' --filter 'status=running' -q" 2>/dev/null)
    else
      # Regular user
      CONTAINER_RUNNING=$(sudo -u "$DMS_EXEC_USER" -H bash -c "cd '$DMS_DIR' && podman ps --filter 'name=mailserver' --filter 'status=running' -q" 2>/dev/null)
    fi
    
    if [ -n "$CONTAINER_RUNNING" ]; then
      echo "Container is running. Waiting 30s for internal services to initialize..."
      sleep 30
      break
    fi
    
    # Show progress every 30 seconds
    if [ $((WAIT_COUNT % 30)) -eq 0 ] && [ $WAIT_COUNT -gt 0 ]; then
      echo "Still waiting... ($WAIT_COUNT seconds elapsed)"
    fi
    
    sleep 5
    WAIT_COUNT=$((WAIT_COUNT + 5))
  done
  
  if [ $WAIT_COUNT -ge $MAX_WAIT ]; then
    echo "Warning: Timed out waiting for mailserver container after ${MAX_WAIT}s."
  fi
  
  # Get the target user's home directory
  DMS_USER_HOME=$(getent passwd "$DMS_EXEC_USER" | cut -d: -f6)
  
  # Try to add email account, handle container not running gracefully
  if [ -n "$DMS_ENV_FILE" ] && [ -f "$DMS_ENV_FILE" ]; then
    # System user with env file
    if ! sudo -u "$DMS_EXEC_USER" -H bash -c "cd '$DMS_DIR' && source '$DMS_ENV_FILE' && podman exec mailserver setup email add '$DMS_EMAIL' '$DMS_EMAIL_PASSWORD'"; then
      # debug
      echo "Debug: Checking container status" >> ./log 2>&1
      sudo -u "$DMS_EXEC_USER" -H bash -c "cd '$DMS_DIR' && source '$DMS_ENV_FILE' && podman ps -a" >> ./log 2>&1
      echo "Debug: Finished checking container status" >> ./log 2>&1
      journalctl _UID=$(id -u $DMS_EXEC_USER) >> ./log 2>&1
      echo "Debug: End log" >> ./log 2>&1
      echo "Warning: email $DMS_EMAIL failed adding - container may not be running yet. Add manually with: podmgr exec dms, then: setup email add $DMS_EMAIL <password>"
    else
      echo "Done"
    fi
  else
    # Regular user
    if ! sudo -u "$DMS_EXEC_USER" -H bash -c "cd '$DMS_DIR' && podman exec mailserver setup email add '$DMS_EMAIL' '$DMS_EMAIL_PASSWORD'"; then
      # debug
      echo "Debug: Checking container status" >> ./log 2>&1
      sudo -u "$DMS_EXEC_USER" -H bash -c "cd '$DMS_DIR' && source '$DMS_ENV_FILE' && podman ps -a" >> ./log 2>&1
      echo "Debug: Finished checking container status" >> ./log 2>&1
      journalctl _UID=$(id -u $DMS_EXEC_USER) >> ./log 2>&1
      echo "Debug: End log" >> ./log 2>&1
      echo "Warning: email $DMS_EMAIL failed adding - container may not be running yet. Add manually with: podman exec -it mailserver setup email add $DMS_EMAIL <password>"
    else
      echo "Done"
    fi
  fi
  # Clear password from memory
  unset DMS_EMAIL_PASSWORD
fi
