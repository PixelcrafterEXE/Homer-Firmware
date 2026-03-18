#!/bin/bash -e

SOFTWARE_SRC="${BASE_DIR}/../Software"
SOFTWARE_DEST="${ROOTFS_DIR}/home/${FIRST_USER_NAME}/Software"
SERVICE_FILE="${ROOTFS_DIR}/etc/systemd/system/homer.service"
AUTOLOGIN_DIR="${ROOTFS_DIR}/etc/systemd/system/getty@tty1.service.d"

# ── Copy application files ────────────────────────────────────────────────────
mkdir -p "${SOFTWARE_DEST}"
rsync -a \
	--exclude='venv/' \
	--exclude='*.egg-info/' \
	--exclude='__pycache__/' \
	"${SOFTWARE_SRC}/" \
	"${SOFTWARE_DEST}/"

on_chroot << EOF
chown -R ${FIRST_USER_NAME}:${FIRST_USER_NAME} /home/${FIRST_USER_NAME}/Software
usermod -a -G video,input,render,tty ${FIRST_USER_NAME}
EOF

# ── Configure X11 for Systemd ─────────────────────────────────────────────────
# Allow non-console users (like systemd services) to start the X server
mkdir -p "${ROOTFS_DIR}/etc/X11"
echo "allowed_users=anybody" > "${ROOTFS_DIR}/etc/X11/Xwrapper.config"
echo "needs_root_rights=yes" >> "${ROOTFS_DIR}/etc/X11/Xwrapper.config"

# ── Systemd service ───────────────────────────────────────────────────────────
# copy a pre-defined unit file and substitute the user name
SERVICE_TEMPLATE="${BASE_DIR}/stage-homer/01-setup-homer/homer.service"
mkdir -p "$(dirname "${SERVICE_FILE}")"
cp "${SERVICE_TEMPLATE}" "${SERVICE_FILE}"
# perform variable substitution in-place
sed -i "s|\${FIRST_USER_NAME}|${FIRST_USER_NAME}|g" "${SERVICE_FILE}"

on_chroot << EOF
systemctl enable homer.service
EOF

# ── Autologin on tty1 ─────────────────────────────────────────────────────────
# The first ExecStart= clears the inherited value from getty@.service.
# %I is the systemd unit instance specifier (tty name); $TERM is expanded by
# systemd at runtime – it must appear literally in the file, hence the \$.
mkdir -p "${AUTOLOGIN_DIR}"
{
	echo '[Service]'
	echo 'ExecStart='
	echo "ExecStart=-/sbin/agetty --autologin ${FIRST_USER_NAME} --noclear %I \$TERM"
} > "${AUTOLOGIN_DIR}/autologin.conf"
