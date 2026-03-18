#!/bin/bash -e

on_chroot << 'EOF'
EEPROM_CONF=$(mktemp)
# Get the most recent EEPROM update firmware
LATEST_EEPROM=$(ls -1 /lib/firmware/raspberrypi/bootloader/default/pieeprom-*.bin | tail -n 1)

rpi-eeprom-config "${LATEST_EEPROM}" > "${EEPROM_CONF}"

# Update WAKE_ON_GPIO
if grep -q "^WAKE_ON_GPIO=" "${EEPROM_CONF}"; then
    sed -i 's/^WAKE_ON_GPIO=.*/WAKE_ON_GPIO=0/' "${EEPROM_CONF}"
else
    echo "WAKE_ON_GPIO=0" >> "${EEPROM_CONF}"
fi

# Update POWER_OFF_ON_HALT
if grep -q "^POWER_OFF_ON_HALT=" "${EEPROM_CONF}"; then
    sed -i 's/^POWER_OFF_ON_HALT=.*/POWER_OFF_ON_HALT=1/' "${EEPROM_CONF}"
else
    echo "POWER_OFF_ON_HALT=1" >> "${EEPROM_CONF}"
fi

# Update BOOT_UART
if grep -q "^BOOT_UART=" "${EEPROM_CONF}"; then
    sed -i 's/^BOOT_UART=.*/BOOT_UART=1/' "${EEPROM_CONF}"
else
    echo "BOOT_UART=1" >> "${EEPROM_CONF}"
fi

BOOT_DIR="/boot/firmware"
if [ ! -d "${BOOT_DIR}" ]; then
    BOOT_DIR="/boot"
fi

rpi-eeprom-config --out "${BOOT_DIR}/pieeprom.upd" --config "${EEPROM_CONF}" "${LATEST_EEPROM}"
sha256sum "${BOOT_DIR}/pieeprom.upd" | awk '{print $1}' > "${BOOT_DIR}/pieeprom.sig"

rm -f "${EEPROM_CONF}"
EOF
