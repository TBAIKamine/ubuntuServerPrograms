#!/bin/bash

# 1. Path to the stored hash
HASH_FILE="/etc/sudo_secret.hash"

# 2. Read the expected hash (trim any CR/newline for consistency)
EXPECTED_HASH=$(tr -d '\r\n' < "$HASH_FILE")

# 3. Read the plain-text secret from the environment variable (DEVICE_ACCESS)
PROVIDED_SECRET="${DEVICE_ACCESS}"

# 4. Hash the provided secret (use printf and trim CR/newline for absolute consistency)
PROVIDED_HASH=$(printf '%s' "$PROVIDED_SECRET" | tr -d '\r\n' | sha256sum | awk '{print $1}')

# 5. Compare the hashes
if [ "$PROVIDED_HASH" == "$EXPECTED_HASH" ] && [ -n "$PROVIDED_SECRET" ]; then
  # Call sudo with all flags/args preserved
  exec /usr/bin/sudo "$@"
else
  # Failure: log the attempt and exit
  logger "Unauthorized sudo attempt on $USER from $SSH_CONNECTION"
  echo "sudo access denied (DEVICE_ACCESS mismatch)."
  exit 1
fi
