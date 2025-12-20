#!/bin/bash

RANGE_SIZE=5000
START=100000

# Get highest allocated range end from /etc/subuid
if [ -s /etc/subuid ]; then
    LAST_END=$(awk -F: '{print $2 + $3}' /etc/subuid | sort -n | tail -1)
    NEXT_START=$((LAST_END > START ? LAST_END : START))
else
    NEXT_START=$START
fi

NEXT_END=$((NEXT_START + RANGE_SIZE - 1))

echo "$NEXT_START-$NEXT_END"
