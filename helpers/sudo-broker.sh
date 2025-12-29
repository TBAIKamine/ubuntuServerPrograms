#!/bin/bash

# sudo-broker.sh - Passwordless sudo via DEVICE_ACCESS secret validation
# This script is called VIA sudo (from the alias) and runs as root.
# It validates the DEVICE_ACCESS environment variable against a stored hash.
# If valid, it executes the command using the real sudo binary (to handle -u, -H, etc.).
# If invalid, access is denied.

# Path to the real sudo binary (avoid alias recursion)
REAL_SUDO="/usr/bin/sudo"

# 1. Path to the stored hash
HASH_FILE="/etc/sudo_secret.hash"

# 2. Check if hash file exists
if [ ! -f "$HASH_FILE" ]; then
  echo "sudo-broker: Hash file not found. System not configured." >&2
  exit 1
fi

# 3. Read the expected hash (trim any CR/newline for consistency)
EXPECTED_HASH=$(tr -d '\r\n' < "$HASH_FILE")

# 4. Read the plain-text secret from the environment variable (DEVICE_ACCESS)
PROVIDED_SECRET="${DEVICE_ACCESS}"

# 5. Hash the provided secret (use printf and trim CR/newline for absolute consistency)
PROVIDED_HASH=$(printf '%s' "$PROVIDED_SECRET" | tr -d '\r\n' | sha256sum | awk '{print $1}')

# 6. Compare the hashes
if [ "$PROVIDED_HASH" == "$EXPECTED_HASH" ] && [ -n "$PROVIDED_SECRET" ]; then
  # Secret validated - use the real sudo binary to execute with all original arguments
  # This handles sudo flags like -u, -H, -i, -E, etc.
  exec "$REAL_SUDO" "$@"
else
  # Failure: log the attempt and exit
  logger "Unauthorized sudo attempt by ${SUDO_USER:-$USER} from ${SSH_CONNECTION:-local}"
  echo "sudo access denied (DEVICE_ACCESS mismatch)." >&2
  exit 1
fi
