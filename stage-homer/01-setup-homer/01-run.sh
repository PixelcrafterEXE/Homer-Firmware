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


# ── Configure X11 for VC4 GPU ─────────────────────────────────────────────────
# NOTE: modesetting does not honour Option "Rotate"; rotation is applied at
# runtime via 'xrandr --rotate right' in the homer.service ExecStart command.
mkdir -p "${ROOTFS_DIR}/etc/X11/xorg.conf.d"
cat > "${ROOTFS_DIR}/etc/X11/xorg.conf.d/99-vc4.conf" << 'XORG_EOF'
Section "Device"
    Identifier "Raspberry Pi VC4"
    Driver "modesetting"
    Option "kmsdev" "/dev/dri/card1"
EndSection

Section "Screen"
    Identifier "Default Screen"
    Device "Raspberry Pi VC4"
EndSection

# Rotate libinput touch/pointer coordinates to match the portrait display.
# Transformation matrix for 90 ° CW:
#   x_new =  y_old
#   y_new = -x_old + 1
Section "InputClass"
    Identifier "Touchscreen portrait"
    MatchIsTouchscreen "on"
    Option "TransformationMatrix" "0 1 0 -1 0 1 0 0 1"
EndSection
XORG_EOF

# ── System-level dconf defaults for onboard on-screen keyboard ────────────────
mkdir -p "${ROOTFS_DIR}/etc/dconf/db/local.d"
cat > "${ROOTFS_DIR}/etc/dconf/db/local.d/00-homerpi" << 'DCONF_EOF'
[org/onboard]
layout='Phone'
start-minimized=true
show-status-icon=false

[org/onboard/window]
docking=true
docking-edge='bottom'
keep-docking=true
DCONF_EOF

# Provide a dconf profile that includes the system-level database.
# Only write the file if it does not already exist so we don't clobber a
# profile written by an earlier stage.
if [ ! -f "${ROOTFS_DIR}/etc/dconf/profile/user" ]; then
	mkdir -p "${ROOTFS_DIR}/etc/dconf/profile"
	printf 'user-db:user\nsystem-db:local\n' > "${ROOTFS_DIR}/etc/dconf/profile/user"
fi

on_chroot << EOF
dconf update
EOF
