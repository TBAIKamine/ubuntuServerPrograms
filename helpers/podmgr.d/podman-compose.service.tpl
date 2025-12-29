[Unit]
Description=$USER (podman-compose)

[Service]
Type=simple
WorkingDirectory=$COMPOSE_DIR
Environment=PODMAN_LOG_LEVEL=debug

# Debug: log to user's home directory (they can write there)
ExecStartPre=/bin/bash -c 'LOG="$HOME/podmgr-compose.log"; exec >> "$LOG" 2>&1; echo "=== DEBUG STARTPRE $(date) ==="; echo "User: $(whoami) UID: $(id -u)"; echo "HOME: $HOME"; echo "PWD: $(pwd)"; echo "XDG_RUNTIME_DIR: $XDG_RUNTIME_DIR"; echo "Runtime dir exists: $(test -d $XDG_RUNTIME_DIR && echo yes || echo no)"; ls -la "$XDG_RUNTIME_DIR" 2>&1 || echo "cannot list runtime dir"; echo "Networks:"; podman network ls 2>&1 || echo "network ls failed with exit $?"; echo "Containers:"; podman ps -a 2>&1 || echo "ps failed with exit $?"; echo "Compose dir contents:"; ls -la 2>&1; echo "=== END DEBUG STARTPRE ==="'

# Force network recreation to work around rootless-netns bug where network exists on disk but not in netns
ExecStartPre=/bin/bash -c 'LOG="$HOME/podmgr-compose.log"; exec >> "$LOG" 2>&1; echo "=== NETWORK RECREATION $(date) ==="; COMPOSE_DIR="$(pwd)"; NET_NAME="$(basename "$COMPOSE_DIR")_default"; echo "Removing network: $NET_NAME"; podman network rm "$NET_NAME" 2>&1 || echo "network rm failed (may not exist)"; echo "Creating network: $NET_NAME"; podman network create "$NET_NAME" 2>&1; echo "Network list after recreation:"; podman network ls 2>&1; echo "=== END NETWORK RECREATION ==="'

ExecStart=/bin/bash -c 'LOG="$HOME/podmgr-compose.log"; exec >> "$LOG" 2>&1; set -x; echo "=== EXECSTART $(date) ==="; echo "PWD: $(pwd)"; echo "USER: $(whoami)"; echo "HOME: $HOME"; echo "XDG_RUNTIME_DIR: $XDG_RUNTIME_DIR"; echo "--- Compose file ---"; cat compose.yaml 2>&1; echo "--- End compose file ---"; echo "=== Running podman-compose -f compose.yaml up ==="; /usr/bin/podman-compose -f compose.yaml up; EXIT_CODE=$?; echo "=== podman-compose exited with code $EXIT_CODE at $(date) ==="; exit $EXIT_CODE'
ExecStop=/usr/bin/podman-compose -f compose.yaml down

Restart=on-failure
RestartSec=30
StartLimitIntervalSec=300
StartLimitBurst=3

[Install]
WantedBy=default.target
