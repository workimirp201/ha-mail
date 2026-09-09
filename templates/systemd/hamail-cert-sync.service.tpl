[Unit]
Description=ha-mail certificate synchronisation (pull from ACME leader)
Documentation=file:///opt/ha-mail/docs/AUDIT.md
After=network-online.target wg-quick@${WG_INTERFACE}.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/hamail-cert-sync.sh
User=root

# A sync that cannot finish in five minutes is stuck on a dead tunnel, not
# working. Killing it lets the timer retry cleanly instead of accumulating
# hung processes.
TimeoutStartSec=300

Nice=10
IOSchedulingClass=idle

# Hardening. The script needs to read ${CERT_ROOT}, write it, and run ssh.
PrivateTmp=true
ProtectSystem=full
ProtectHome=read-only
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
