#!/bin/bash -e

# ── Static IP on eth0 (LAN port) ─────────────────────────────────────────────
# Assigns 192.168.10.10/24 with gateway 192.168.10.1 so the Pi is reachable
# at a predictable address over a direct (crossover) Ethernet cable.
# NetworkManager picks up keyfiles from /etc/NetworkManager/system-connections/
# on startup; mode 0600 is required or NM will refuse to load the file.
NM_CONN_DIR="${ROOTFS_DIR}/etc/NetworkManager/system-connections"
mkdir -p "${NM_CONN_DIR}"

cat > "${NM_CONN_DIR}/eth0-static.nmconnection" << 'NM_EOF'
[connection]
id=eth0-static
type=ethernet
interface-name=eth0
autoconnect=true

[ethernet]

[ipv4]
method=manual
addresses=192.168.10.10/24
gateway=192.168.10.1

[ipv6]
method=disabled
NM_EOF

chmod 0600 "${NM_CONN_DIR}/eth0-static.nmconnection"

# ── Enable SSH ────────────────────────────────────────────────────────────────
on_chroot << EOF
systemctl enable ssh
EOF
