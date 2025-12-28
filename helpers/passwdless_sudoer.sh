#!/bin/bash

# Validate SUDO_USER is not root
if [ -z "$SUDO_USER" ] || [ "$SUDO_USER" = "root" ]; then
	echo "Error: SUDO_USER must be set to a non-root user" >&2
	exit 1
fi

# -- add conditional alias AND function to .bashrc and .profile --
# The alias works in interactive shells, the exported function works in scripts
# IMPORTANT: alias/function calls "sudo broker" so broker runs as root and can exec directly
{
	ALIAS_BLOCK=$'if [[ -n "$DEVICE_ACCESS" ]]; then\n    alias sudo=\'/usr/bin/sudo /usr/local/bin/sudo-broker.sh\'\nfi'
	# Function for non-interactive shells (scripts) - exported so subshells inherit it
	FUNC_BLOCK=$'# sudo wrapper function for non-interactive shells\nfunction sudo() {\n    if [[ -n "$DEVICE_ACCESS" ]]; then\n        /usr/bin/sudo /usr/local/bin/sudo-broker.sh "$@"\n    else\n        /usr/bin/sudo "$@"\n    fi\n}\nexport -f sudo'
	
	for RC_FILE in "/home/$SUDO_USER/.bashrc" "/home/$SUDO_USER/.profile"; do
		if [ -f "$RC_FILE" ]; then
			# Remove any existing DEVICE_ACCESS alias blocks (clean slate for reinstalls)
			sed -i '/if \[\[ -n "\$DEVICE_ACCESS" \]\]; then/,/^fi$/d' "$RC_FILE"
			# Remove any existing sudo wrapper function blocks
			sed -i '/# sudo wrapper function for non-interactive shells/,/^export -f sudo$/d' "$RC_FILE"
			# Remove any standalone broken sudo-broker aliases
			sed -i '/alias sudo=.*sudo-broker/d' "$RC_FILE"
			# Add the correct alias block (for interactive shells)
			echo "$ALIAS_BLOCK" >> "$RC_FILE"
			# Add the function block (for non-interactive shells/scripts)
			echo "$FUNC_BLOCK" >> "$RC_FILE"
		else
			echo "$ALIAS_BLOCK" > "$RC_FILE"
			echo "$FUNC_BLOCK" >> "$RC_FILE"
			chown "$SUDO_USER:$SUDO_USER" "$RC_FILE"
		fi
	done
}

# -- allow the broker command and passwdls to be executed without password from sudo --
{
	SUDOERS_FILE="/etc/sudoers.d/secret_broker"
	# env_keep preserves these variables through sudo calls
	# NOPASSWD allows broker and passwdls to run without password
	# Note: broker needs "*" to allow any arguments (the actual commands to run)
	SUDOERS_CONTENT="Defaults env_keep += \"DEVICE_ACCESS\"
Defaults env_keep += \"BASH_ENV\"
Defaults env_keep += \"SOURCE_DIR\"
Defaults env_keep += \"SUDO_USER\"
$SUDO_USER ALL = NOPASSWD: /usr/local/bin/sudo-broker.sh *
$SUDO_USER ALL = NOPASSWD: /usr/local/bin/passwdls"
	echo "$SUDOERS_CONTENT" > "$SUDOERS_FILE"
	chmod 440 "$SUDOERS_FILE"
	chown root:root "$SUDOERS_FILE"
}

# -- creating the broker --
{
	ABS_PATH=$(dirname "$(realpath "$0")")
	cp $ABS_PATH/sudo-broker.sh /usr/local/bin/sudo-broker.sh
	chmod 555 /usr/local/bin/sudo-broker.sh
	chown root:root /usr/local/bin/sudo-broker.sh
}

# -- storing the hash of the secret --
{
	printf '%s' "$SUDO_SECRET" | tr -d '\r\n' | sha256sum | awk '{print $1}' | tee /etc/sudo_secret.hash
	chmod 440 /etc/sudo_secret.hash
	chown root:$SUDO_USER /etc/sudo_secret.hash
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