[Unit]
Description=$USER (podman-compose)

[Service]
Type=simple
WorkingDirectory=$COMPOSE_DIR

ExecStart=/usr/bin/podman-compose -f compose.yaml up
ExecStop=/usr/bin/podman-compose -f compose.yaml down

Restart=on-failure
RestartSec=30

[Install]
WantedBy=default.target
