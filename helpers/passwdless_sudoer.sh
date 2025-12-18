#!/bin/bash
# -- add conditional alias to .bashrc --
{
	BASHRC="/home/$SUDO_USER/.bashrc"
	ALIAS_BLOCK=$'if [[ -n "$DEVICE_ACCESS" ]]; then\n    alias sudo=\'sudo /usr/local/bin/sudo-broker.sh\'\nfi'
	if [ -f "$BASHRC" ]; then
		if ! grep -Fxq "alias sudo='sudo /usr/local/bin/sudo-broker.sh'" "$BASHRC"; then
			echo "$ALIAS_BLOCK" >> "$BASHRC"
		fi
	else
		echo "$ALIAS_BLOCK" > "$BASHRC"
	fi
}

# -- allow the broker command to be executed without password from sudo --
{
	SUDOERS_FILE="/etc/sudoers.d/secret_broker"
	SUDOERS_CONTENT="Defaults env_keep += \"DEVICE_ACCESS\"\nDefaults env_keep += \"BASH_ENV\"\nDefaults env_keep += \"SOURCE_DIR\"\n$SUDO_USER ALL = NOPASSWD: /usr/local/bin/sudo-broker.sh"
	echo -e "$SUDOERS_CONTENT" | tee "$SUDOERS_FILE" > /dev/null
	chmod 550 "$SUDOERS_FILE"
	chown root:root "$SUDOERS_FILE"
}

# -- creating the broker --
{
	ABS_PATH=$(dirname "$(realpath "$0")")
	cp $ABS_PATH/sudo-broker.sh /usr/local/bin/sudo-broker.sh
	chmod 550 /usr/local/bin/sudo-broker.sh
	chmod +x /usr/local/bin/sudo-broker.sh
	chown root:root /usr/local/bin/sudo-broker.sh
}

# -- storing the hash of the secret --
{
	printf '%s' "$SUDO_SECRET" | tr -d '\r\n' | sha256sum | awk '{print $1}' | tee /etc/sudo_secret.hash
	chmod 440 /etc/sudo_secret.hash
	chown root:root /etc/sudo_secret.hash
}

# -- creating the passwdls helper script --
{
	mkdir -p /usr/local/lib/scripts
	chown "$SUDO_USER:$SUDO_USER" /usr/local/lib/scripts
	chmod 550 /usr/local/lib/scripts
	cp $ABS_PATH/getinput.sh /usr/local/lib/scripts/getinput.sh
	chmod 555 /usr/local/lib/scripts/getinput.sh
	sed "s/__USER__/$SUDO_USER/g" "$ABS_PATH/passwdls" > /usr/local/bin/passwdls
	chmod 550 /usr/local/bin/passwdls
	chmod +x /usr/local/bin/passwdls
	chown root:root /usr/local/bin/passwdls
}

# -- doing all this over ssh --
{
	SSHD_CONFIG="/etc/ssh/sshd_config"
	MATCH_LINE="Match User $SUDO_USER"
	if [ -f "$SSHD_CONFIG" ]; then
		if grep -q "^$MATCH_LINE" "$SSHD_CONFIG"; then
			# Match block exists: ensure AcceptEnv DEVICE_ACCESS is present
			if ! awk -v u="$SUDO_USER" '
				BEGIN {found_match=0; found_accept=0}
				$0 ~ "^Match[[:space:]]+User[[:space:]]+" u "[[:space:]]*$" { if (found_match == 0) {found_match=1; next} }
				found_match && /^[[:space:]]*AcceptEnv[[:space:]]+DEVICE_ACCESS[[:space:]]*$/ { found_accept=1 }
				found_match && /^Match[[:space:]]/ { exit }
				END { if (found_match && found_accept) exit 0; else exit 1 }
			' "$SSHD_CONFIG"; then
				tmpfile=$(mktemp)
				# use consistent 3-space indentation when inserting AcceptEnv
				awk -v ind="   " -v al="AcceptEnv DEVICE_ACCESS" -v u="$SUDO_USER" '
					BEGIN {in_block=0}
					$0 ~ "^Match[[:space:]]+User[[:space:]]+" u "[[:space:]]*$" { print; in_block=1; printed_accept=0; next }
					in_block && /^[[:space:]]*AcceptEnv[[:space:]]+DEVICE_ACCESS[[:space:]]*$/ { printed_accept=1 }
				in_block && /^Match[[:space:]]/ { if (!printed_accept) print ind al; in_block=0 }
					{ print }
					END { if (in_block && !printed_accept) print ind al }
				' "$SSHD_CONFIG" > "$tmpfile" && mv "$tmpfile" "$SSHD_CONFIG"
			fi
		else
			# Match block missing: append full block with AcceptEnv line (3-space indent)
			printf "\nMatch User %s\n   AcceptEnv DEVICE_ACCESS\n" "$SUDO_USER" | tee -a "$SSHD_CONFIG"
		fi
	fi
}