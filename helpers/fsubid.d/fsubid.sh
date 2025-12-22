#!/bin/bash

ABS_PATH=$(dirname "$(realpath "$0")")

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
  cat "$ABS_PATH/usage.txt"
  exit 0
fi

RANGE_SIZE=70000
SUDO_USER_START=100000
SUDO_USER_END=$((SUDO_USER_START + RANGE_SIZE - 1))
NEXT_USER_START=$((SUDO_USER_END + 1))

# Ensure $SUDO_USER has the correct range in /etc/subuid and /etc/subgid
for file in /etc/subuid /etc/subgid; do
  if [ -f "$file" ]; then
    # Remove any existing entry for $SUDO_USER
    sudo sed -i "/^$SUDO_USER:/d" "$file"
    # Add the correct range for $SUDO_USER
    echo "$SUDO_USER:$SUDO_USER_START:$RANGE_SIZE" | sudo tee -a "$file" > /dev/null
  fi
done

# Calculate next available range starting from 170000
if [ -s /etc/subuid ]; then
  LAST_END=$(awk -F: -v user="$SUDO_USER" '$1 != user {print $2 + $3}' /etc/subuid | sort -n | tail -1)
  NEXT_START=$((LAST_END > NEXT_USER_START ? LAST_END : NEXT_USER_START))
else
  NEXT_START=$NEXT_USER_START
fi

echo "$NEXT_START:$RANGE_SIZE"
