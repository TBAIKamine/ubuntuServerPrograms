#!/bin/bash

ABS_PATH=$(dirname "$(realpath "$0")")

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
  cat "$ABS_PATH/usage.txt"
  exit 0
fi

RANGE_SIZE=5000
START=100000

if [ -s /etc/subuid ]; then
  LAST_END=$(awk -F: '{print $2 + $3}' /etc/subuid | sort -n | tail -1)
  NEXT_START=$((LAST_END > START ? LAST_END : START))
else
  NEXT_START=$START
fi

NEXT_END=$((NEXT_START + RANGE_SIZE - 1))

echo "$NEXT_START-$NEXT_END"
