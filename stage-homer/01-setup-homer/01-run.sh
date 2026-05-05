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
usermod -a -G video,input,render,tty,plugdev ${FIRST_USER_NAME}
EOF

# ── Allow user to set system clock via timedatectl (no sudo required) ─────────
# The homer application syncs the OS clock from the sensor's EEPROM RTC.
# Instead of granting broad sudo rights, we install a targeted polkit rule that
# allows only the application user to invoke the two timedate1 D-Bus actions
# (set-time / set-ntp) without an authentication prompt.
mkdir -p "${ROOTFS_DIR}/etc/polkit-1/rules.d"
cat > "${ROOTFS_DIR}/etc/polkit-1/rules.d/10-timedate.rules" << POLKIT_EOF
polkit.addRule(function(action, subject) {
    if ((action.id === "org.freedesktop.timedate1.set-time" ||
         action.id === "org.freedesktop.timedate1.set-ntp") &&
        subject.user === "${FIRST_USER_NAME}") {
        return polkit.Result.YES;
    }
});
POLKIT_EOF

# ── Allow user to mount/unmount USB drives via udisksctl (no sudo required) ───
# The homer application exports CSV measurements to a USB stick.  udisksctl
# goes through the UDisks2 D-Bus service which enforces polkit.  When the
# process has no controlling terminal (systemd service) udisksctl cannot create
# a polkit authentication agent, so the mount is rejected with
# NotAuthorizedCanObtain.  The rule below grants the two relevant actions
# unconditionally for the application user so polkit returns YES before any
# agent is attempted.
cat > "${ROOTFS_DIR}/etc/polkit-1/rules.d/11-udisks2.rules" << POLKIT_EOF
polkit.addRule(function(action, subject) {
    if ((action.id === "org.freedesktop.udisks2.filesystem-mount" ||
         action.id === "org.freedesktop.udisks2.filesystem-mount-other-seat" ||
         action.id === "org.freedesktop.udisks2.filesystem-mount-system" ||
         action.id === "org.freedesktop.udisks2.filesystem-mount-fstab" ||
         action.id === "org.freedesktop.udisks2.filesystem-unmount" ||
         action.id === "org.freedesktop.udisks2.filesystem-unmount-others") &&
        subject.user === "${FIRST_USER_NAME}") {
        return polkit.Result.YES;
    }
});
POLKIT_EOF

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
# Do NOT specify a Device/Screen section with a hardcoded kmsdev path.
# On Pi 4 the display DRM device is card0; on Pi 5 it is also card0 (the rp1
# southbridge), so card1 never exists as a display node.  Letting modesetting
# auto-detect the KMS device avoids "no screens found" across board revisions.
#
# Rotation is applied at runtime via xrandr in the homer.service ExecStart
# command.  The connected output is detected dynamically at runtime because
# on Pi 4 it is DSI-1 and on Pi 5 it is DSI-2, and xrandr exits 0 (with only
# a warning) when a non-existent output name is specified, making || fallbacks
# unreliable.
mkdir -p "${ROOTFS_DIR}/etc/X11/xorg.conf.d"
cat > "${ROOTFS_DIR}/etc/X11/xorg.conf.d/99-vc4.conf" << 'XORG_EOF'
# No coordinate transformation needed – the panel is natively portrait (800x1280)
# and no xrandr rotation is applied.
Section "InputClass"
    Identifier "Touchscreen"
    MatchIsTouchscreen "on"
EndSection
XORG_EOF

# ── System-level dconf defaults for onboard on-screen keyboard ────────────────
mkdir -p "${ROOTFS_DIR}/etc/dconf/db/local.d"
cat > "${ROOTFS_DIR}/etc/dconf/db/local.d/00-homerpi" << 'DCONF_EOF'
[org/onboard]
layout='Phone'
theme='Droid'
start-minimized=true
show-status-icon=false

[org/onboard/auto-show]
enabled=false

[org/onboard/window]
docking-enabled=false
force-to-top=true
docking-shrink-workarea=false

[org/onboard/window/portrait]
x=0
y=1080
width=800
height=200
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

# ── Waveshare 8inch DSI LCD v2 – boot firmware configuration ─────────────────
# The display (vc4-kms-dsi-waveshare-panel-v2, 8_0_inch_a) is natively portrait
# (800×1280).  No xrandr rotation is applied; the app runs at native resolution.
# The dsi0 overlay param routes I2C to i2c_csi_dsi0 (the DISP 0 bus) and
# causes the kernel to name the output DSI-1.  Without dsi0 the backlight
# controller (I2C 0x45) ends up on the wrong bus and all sysfs writes fail.
# display_auto_detect is disabled so the firmware does not override our overlay.
CONFIG="${ROOTFS_DIR}/boot/firmware/config.txt"
CMDLINE="${ROOTFS_DIR}/boot/firmware/cmdline.txt"

# Disable auto-detect so our explicit overlay is not overridden
sed -i 's/^display_auto_detect=1/display_auto_detect=0/' "${CONFIG}"

# Append the DSI overlay under [all] if not already present
if ! grep -q 'vc4-kms-dsi-waveshare-panel' "${CONFIG}"; then
	printf '\n# Waveshare 8inch DSI LCD v2 – native portrait 800x1280\ndtoverlay=vc4-kms-dsi-waveshare-panel-v2,8_0_inch_a,dsi0\n' >> "${CONFIG}"
fi

# Prepend display resolution hint to cmdline.txt if not already present.
# Panel native resolution is 800x1280 (portrait).  No kernel-level rotation.
# With dsi0 param the kernel names this output DSI-1 (Pi 5 DISP 0 = rp1 dsi@118000).
if ! grep -q 'video=DSI-1' "${CMDLINE}"; then
	sed -i 's/^/video=DSI-1:800x1280M@60 /' "${CMDLINE}"
fi
