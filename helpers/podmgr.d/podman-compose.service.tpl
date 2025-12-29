[Unit]
Description=$USER (podman-compose)

[Service]
Type=simple
WorkingDirectory=$COMPOSE_DIR
Environment=PODMAN_LOG_LEVEL=debug

# Debug: log state before starting
ExecStartPre=/bin/bash -c 'exec >> /var/log/podmgr-compose.log 2>&1; echo "=== DEBUG START $(date) ==="; echo "User: $(whoami) UID: $(id -u)"; echo "XDG_RUNTIME_DIR: $XDG_RUNTIME_DIR"; echo "Runtime dir exists: $(test -d $XDG_RUNTIME_DIR && echo yes || echo no)"; echo "Networks:"; podman network ls 2>&1 || echo "network ls failed"; echo "Containers:"; podman ps -a 2>&1 || echo "ps failed"; echo "=== END DEBUG ==="'

ExecStart=/bin/bash -c 'exec >> /var/log/podmgr-compose.log 2>&1; set -x; echo "=== EXECSTART $(date) ==="; echo "PWD: $(pwd)"; echo "Compose file:"; cat compose.yaml 2>&1 | head -50; echo "=== Running podman-compose up ==="; podman-compose -f compose.yaml up 2>&1; EXIT_CODE=$?; echo "=== podman-compose exited with code $EXIT_CODE ==="; exit $EXIT_CODE'
ExecStop=/usr/bin/podman-compose -f compose.yaml down

Restart=on-failure
RestartSec=30
StartLimitIntervalSec=300
StartLimitBurst=3

[Install]
WantedBy=default.target
