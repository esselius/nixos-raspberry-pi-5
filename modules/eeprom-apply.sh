#!/bin/sh
# Apply the declared Raspberry Pi 5 bootloader EEPROM configuration.
#
# On BCM2712 boards rpi-eeprom-update defaults to an immediate flashrom update,
# so `rpi-eeprom-config --apply` writes the SPI EEPROM directly instead of
# staging files for the next reboot. Only call it when a declared key actually
# differs from the running configuration: re-flashing on every boot would be
# slow, wears the flash, and leaves a window where a power cut needs a
# bootloader-recovery SD card.
set -eu

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <eeprom.conf>" >&2
  exit 2
fi

config=$1

if ! current=$(rpi-eeprom-config); then
  echo "pi5-eeprom: cannot read the current EEPROM configuration" >&2
  exit 1
fi

if [ -z "$current" ]; then
  echo "pi5-eeprom: the current EEPROM configuration is empty; refusing to apply" >&2
  exit 1
fi

# Bootloader values are hexadecimal or numeric and case does not matter to the
# firmware, so compare case-insensitively. Otherwise "0xF416" would look like a
# change on every boot.
normalize() {
  tr '[:upper:]' '[:lower:]'
}

current_normalized=$(printf '%s\n' "$current" | tr -d '\r' | normalize)
changed=0

while IFS= read -r line || [ -n "$line" ]; do
  line=$(printf '%s' "$line" | tr -d '\r')

  case "$line" in
    '' | '#'*) continue ;;
    '['*) continue ;;
    *=*) ;;
    *)
      echo "pi5-eeprom: ignoring malformed configuration line: $line" >&2
      continue
      ;;
  esac

  if ! printf '%s\n' "$current_normalized" | grep -qxF -- "$(printf '%s' "$line" | normalize)"; then
    echo "pi5-eeprom: ${line%%=*} does not match the declared value" >&2
    changed=1
  fi
done <"$config"

if [ "$changed" -eq 0 ]; then
  echo "pi5-eeprom: EEPROM configuration already matches $config"
  exit 0
fi

echo "pi5-eeprom: applying $config"
# --apply merges the config into the package's newest bootloader image and
# schedules it. A downgrade is refused by rpi-eeprom-update, which is the safe
# outcome: bump nixpkgs (pi5.eeprom.package) instead of forcing it.
rpi-eeprom-config --apply "$config"
