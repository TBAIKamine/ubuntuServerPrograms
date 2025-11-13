#!/bin/bash
echo "$SUDO_SECRET" | sha256sum | awk '{print $1}' | tee /etc/sudo_secret.hash
ABS_PATH=$(dirname "$(realpath "$0")")
cp $ABS_PATH/sudo-broker.sh /usr/local/bin/sudo-broker.sh
chmod 550 /usr/local/bin/sudo-broker.sh
chown root:root /usr/local/bin/sudo-broker.sh
chmod 440 /etc/sudo_secret.hash
chown root:root /etc/sudo_secret.hash
SUDOERS_FILE="/etc/sudoers.d/secret_broker"
SUDOERS_CONTENT="user ALL = NOPASSWD: /usr/local/bin/sudo-broker.sh"
echo "$SUDOERS_CONTENT" | tee "$SUDOERS_FILE" > /dev/null
chmod 550 "$SUDOERS_FILE"
chown root:root "$SUDOERS_FILE"
cp $ABS_PATH/passwdls /usr/local/bin/passwdls
chmod +x /usr/local/bin/passwdls
chown root:root /usr/local/bin/passwdls
chmod 550 /usr/local/bin/passwdls