#!/bin/bash

# Progress indicator with moving columns animation
# Usage: 
#   Method 1 - Run with command: progress.sh [columns] command [args...]
#   Method 2 - Run with PID: progress.sh <pid> [columns]
#
# Examples:
#   progress.sh sleep 20         # Monitor 'sleep 20' with default ::
#   progress.sh 3 sleep 20       # Monitor 'sleep 20' with :::
#   progress.sh 12345 2          # Monitor process 12345 with ::

# Parse arguments
TARGET_PID=""
COL_COUNT=2
COMMAND=()

# Check if first arg is a column count (single digit 2-5)
if [[ $1 =~ ^[2-5]$ ]]; then
    COL_COUNT=$1
    shift
fi

# Check if first remaining arg is a PID (number > 100)
if [[ $1 =~ ^[0-9]+$ ]] && [ $1 -gt 100 ]; then
    TARGET_PID=$1
    shift
    # Check if next arg is column count
    if [[ $1 =~ ^[2-5]$ ]]; then
        COL_COUNT=$1
    fi
else
    # Remaining args are the command to run
    COMMAND=("$@")
fi

# Build the column string
COL_STR=""
for ((i=0; i<COL_COUNT; i++)); do
    COL_STR="${COL_STR}:"
done

# Start the command in background if provided
if [ ${#COMMAND[@]} -gt 0 ]; then
    "${COMMAND[@]}" &
    TARGET_PID=$!
fi

# Width of the progress bar (excluding brackets)
WIDTH=20
DELAY=0.1  # Animation speed

# Color codes
GREY='\033[90m'      # Light grey for background
WHITE='\033[97m'     # Bright white for dancing columns
RESET='\033[0m'      # Reset color

# Build background string (all light grey colons)
BG_STR=""
for ((i=0; i<COL_COUNT; i++)); do
    BG_STR="${BG_STR}:"
done

# Function to display progress bar
show_progress() {
    local pos=$1
    
    # Save cursor position, move to where bar should be, print bar, restore cursor
    printf "\033[s["
    
    # Print background colons or dancing colons based on position
    for ((i=0; i<WIDTH; i++)); do
        if [ $i -eq $pos ]; then
            printf "${WHITE}%s${RESET}" "$COL_STR"
        else
            printf "${GREY}%s${RESET}" "$BG_STR"
        fi
    done
    
    printf "]\033[u"
}

# Function to check if process is still running
is_running() {
    if [ -n "$TARGET_PID" ]; then
        kill -0 "$TARGET_PID" 2>/dev/null
        return $?
    else
        # If no PID provided, run indefinitely until killed
        return 0
    fi
}

# Trap to clean up on exit
cleanup() {
    # Print final bar state, clear to end of line, and newline
    printf "\033[s["
    for ((i=0; i<WIDTH; i++)); do
        printf "="
    done
    printf "]\033[K\n"
    exit 0
}

trap cleanup EXIT INT TERM

# Main animation loop
pos=0
direction=1
max_pos=$((WIDTH - 1))

while is_running; do
    show_progress $pos
    sleep "$DELAY"
    
    # Update position
    pos=$((pos + direction))
    
    # Reverse direction at boundaries
    if [ $pos -ge $max_pos ]; then
        pos=$max_pos
        direction=-1
    elif [ $pos -le 0 ]; then
        pos=0
        direction=1
    fi
done
