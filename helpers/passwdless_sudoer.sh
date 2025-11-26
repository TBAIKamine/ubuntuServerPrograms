#!/bin/bash
echo "$SUDO_SECRET" | sha256sum | awk '{print $1}' | tee /etc/sudo_secret.hash
ABS_PATH=$(dirname "$(realpath "$0")")
cp $ABS_PATH/sudo-broker.sh /usr/local/bin/sudo-broker.sh
chmod 550 /usr/local/bin/sudo-broker.sh
chown root:root /usr/local/bin/sudo-broker.sh
chmod 440 /etc/sudo_secret.hash
chown root:root /etc/sudo_secret.hash
SUDOERS_FILE="/etc/sudoers.d/secret_broker"
SUDOERS_CONTENT="Defaults env_keep += \"DEVICE_ACCESS\"\nuser ALL = NOPASSWD: /usr/local/bin/sudo-broker.sh"
echo -e "$SUDOERS_CONTENT" | tee "$SUDOERS_FILE" > /dev/null
chmod 550 "$SUDOERS_FILE"
chown root:root "$SUDOERS_FILE"
cp $ABS_PATH/passwdls /usr/local/bin/passwdls
chmod +x /usr/local/bin/passwdls
chown root:root /usr/local/bin/passwdls
chmod 550 /usr/local/bin/passwdls

SSHD_CONFIG="/etc/ssh/sshd_config"
MATCH_LINE="Match User user"
ACCEPT_ENV_LINE="  AcceptEnv DEVICE_ACCESS"

if [ -f "$SSHD_CONFIG" ]; then
	if grep -q "^$MATCH_LINE" "$SSHD_CONFIG"; then
		if ! awk "
			BEGIN {found_match=0; found_accept=0}
			/^Match[[:space:]]+User[[:space:]]+user[[:space:]]*$/ {
				if (found_match == 0) {found_match=1; next}
			}
			found_match && /^[[:space:]]*AcceptEnv[[:space:]]+DEVICE_ACCESS[[:space:]]*$/ {
				found_accept=1
			}
			found_match && /^Match[[:space:]]/ {
				exit
			}
			END { if (found_match && found_accept) exit 0; else exit 1 }
		" "$SSHD_CONFIG"; then
			tmpfile=$(mktemp)
			awk -v ml="$MATCH_LINE" -v al="$ACCEPT_ENV_LINE" '
				BEGIN {in_block=0}
				/^Match[[:space:]]+User[[:space:]]+user[[:space:]]*$/ {
					print
					in_block=1
					next
				}
				in_block && /^Match[[:space:]]/ {
					print al
					in_block=0
				}
				{print}
				END {
					if (in_block) {
						print al
					}
				}
			' "$SSHD_CONFIG" > "$tmpfile" && mv "$tmpfile" "$SSHD_CONFIG"
		fi
	fi
fi