#!/bin/bash

ABS_PATH=$(dirname "$(realpath "$0")")

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
  cat "$ABS_PATH/usage.txt"
  exit 0
fi

# Accept user as first argument, fallback to SUDO_USER
TARGET_USER="${1:-$SUDO_USER}"

# Safety check: prevent changes when TARGET_USER is root or empty
if [[ -z "$TARGET_USER" || "$TARGET_USER" == "root" ]]; then
  echo "Error: TARGET_USER is root or empty. Refusing to make changes."
  exit 1
fi

RANGE_SIZE=70000
FIRST_USER_START=100000
NEXT_USER_START=$((FIRST_USER_START + RANGE_SIZE))

# Fix the first user's range to 100000:70000 (they typically get 100000:65536 by default)
for file in /etc/subuid /etc/subgid; do
  if [ -f "$file" ] && [ -s "$file" ]; then
    FIRST_USER=$(head -1 "$file" | cut -d: -f1)
    if [ -n "$FIRST_USER" ]; then
      sudo sed -i "1s/.*/$FIRST_USER:$FIRST_USER_START:$RANGE_SIZE/" "$file"
    fi
  fi
done

# Calculate next available range starting from 170000
if [ -s /etc/subuid ]; then
  LAST_END=$(awk -F: '{print $2 + $3}' /etc/subuid | sort -n | tail -1)
  NEXT_START=$((LAST_END > NEXT_USER_START ? LAST_END : NEXT_USER_START))
else
  NEXT_START=$NEXT_USER_START
fi

echo "$NEXT_START:$RANGE_SIZE"
