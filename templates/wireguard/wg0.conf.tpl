# ###########################################################################
# ha-mail :: /etc/wireguard/${WG_INTERFACE}.conf
# Node ${SELF_ROLE} - ${SELF_HOSTNAME} (${SELF_IP})
#
# GENERATED FILE. Edit templates/wireguard/wg0.conf.tpl instead.
#
# This tunnel carries THREE things and nothing else:
#   1. MariaDB replication  (3306, bound to ${SELF_WG_IP} only)
#   2. Dovecot dsync/doveadm (${DOVEADM_PORT}, bound to ${SELF_WG_IP} only)
#   3. SSH for certificate sync and operator jumps (${SSH_PORT})
#
# Everything above is therefore encrypted twice (WireGuard + the protocol's own
# TLS) and, more importantly, is unreachable from the public internet even if a
# UFW rule is later edited by mistake, because the services do not bind a
# public address at all.
# ###########################################################################

[Interface]
Address     = ${SELF_WG_IP}/24
ListenPort  = ${WG_PORT}
PrivateKey  = ${WG_PRIVKEY}

# 1420 = 1500 (Linode MTU) - 80 (WireGuard IPv4/UDP overhead).
# Leaving this at the default invites silent black-holing of large replication
# packets on paths that drop ICMP "fragmentation needed", which presents as
# "replication works until someone creates a domain with a long description".
MTU         = 1420

# Do not let systemd-resolved rewrite resolv.conf for this interface.
Table       = auto
SaveConfig  = false

[Peer]
# ${PEER_ROLE} - ${PEER_HOSTNAME} (${PEER_IP}, ${PEER_REGION})
PublicKey           = ${WG_PEER_PUBKEY}
Endpoint            = ${PEER_IP}:${WG_PORT}

# Strictly the peer's single tunnel address. Do NOT widen this to
# ${WG_SUBNET} - a /32 means a compromised peer key cannot be used to route
# arbitrary traffic through this node.
AllowedIPs          = ${PEER_WG_IP}/32

# Mandatory. WireGuard is silent by design; without a keepalive a dead tunnel
# is only discovered when the next replication event fails, which on a mail
# system means "when a user complains". 25s also keeps stateful middleboxes
# from expiring the UDP flow.
PersistentKeepalive = ${WG_KEEPALIVE}
