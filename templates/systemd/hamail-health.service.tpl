[Unit]
Description=ha-mail cluster health check
After=network-online.target mariadb.service dovecot.service postfix.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/hamail-health.sh --quiet
User=root
TimeoutStartSec=120
Environment=HAMAIL_ALERT_EMAIL=${ALERT_EMAIL}

[Install]
WantedBy=multi-user.target
