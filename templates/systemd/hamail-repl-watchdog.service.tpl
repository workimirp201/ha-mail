[Unit]
Description=ha-mail replication watchdog (MariaDB + Dovecot)
After=mariadb.service dovecot.service wg-quick@${WG_INTERFACE}.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/hamail-repl-watchdog.sh
User=root
TimeoutStartSec=180
Environment=HAMAIL_ALERT_EMAIL=${ALERT_EMAIL}

[Install]
WantedBy=multi-user.target
