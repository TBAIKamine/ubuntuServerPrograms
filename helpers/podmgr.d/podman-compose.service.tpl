[Unit]
Description=$USER (podman-compose)

[Service]
Type=simple
WorkingDirectory=$COMPOSE_DIR
ExecStartPre=/bin/bash -c 'PROJECT=$(basename "$COMPOSE_DIR"); /usr/bin/podman network create ${PROJECT}_default 2>/dev/null || true; until /usr/bin/podman network exists ${PROJECT}_default; do sleep 1; done'
ExecStart=/usr/bin/podman-compose -f compose.yaml up
ExecStop=/usr/bin/podman-compose -f compose.yaml down
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
