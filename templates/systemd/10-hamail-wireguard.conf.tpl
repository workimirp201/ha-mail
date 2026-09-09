# ha-mail :: systemd drop-in
#
# Installed as:
#   /etc/systemd/system/mariadb.service.d/10-hamail-wireguard.conf
#   /etc/systemd/system/dovecot.service.d/10-hamail-wireguard.conf
#   /etc/systemd/system/nginx.service.d/10-hamail-wireguard.conf
#
# THE BUG THIS PREVENTS
# Three services bind a socket to ${SELF_WG_IP}:
#   MariaDB  ${SELF_WG_IP}:3306        (replication)
#   Dovecot  ${SELF_WG_IP}:${DOVEADM_PORT}   (dsync)
#   nginx    ${SELF_WG_IP}:8080        (ACME peer endpoint)
#
# That address does not exist until wg-quick has created the interface. At
# boot, systemd starts these in parallel with networking, so roughly one boot
# in N the bind fails with EADDRNOTAVAIL and the unit dies. The failure is
# intermittent, survives a manual restart (because by then the tunnel is up),
# and therefore looks like anything except what it is.
#
# Two independent defences:
#   1. this ordering dependency
#   2. net.ipv4.ip_nonlocal_bind=1 in /etc/sysctl.d/99-hamail.conf, which lets
#      the bind succeed even if the interface is a fraction of a second late
#
# Wants= rather than Requires=: if the tunnel genuinely cannot come up, these
# services must still start and serve local users. A dead tunnel degrades
# replication; it must never take mail service down with it.

[Unit]
Wants=wg-quick@${WG_INTERFACE}.service
After=wg-quick@${WG_INTERFACE}.service network-online.target
