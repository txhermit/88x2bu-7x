#!/bin/sh
#
# dkms-uninstall.sh — clean removal of the 88x2bu-7x DKMS installation.
#
# Usage:
#   sudo ./dkms-uninstall.sh
#
# Removes:
#   - the DKMS module instance (all kernels)
#   - /usr/src/<name>-<version>
#   - the rtw88 blacklist file this installer creates (only that file)
#
# It does NOT remove /etc/modprobe.d/88x2bu.conf if you installed it with
# --install-modprobe-conf; delete that by hand if you no longer want it.

if [ "$(id -u)" -ne 0 ]; then
	echo "This script must run as root. Re-running with sudo..." >&2
	exec sudo -E "$0" "$@"
fi

if [ ! -f dkms.conf ]; then
	echo "Error: dkms.conf not found. Run this script from the repo root." >&2
	exit 1
fi

PKG_NAME=$(grep '^PACKAGE_NAME=' dkms.conf | cut -d'"' -f2)
PKG_VER=$(grep '^PACKAGE_VERSION=' dkms.conf | cut -d'"' -f2)
MOD_NAME=$(grep '^BUILT_MODULE_NAME\[0\]=' dkms.conf | cut -d'"' -f2)
DEST_DIR="/usr/src/${PKG_NAME}-${PKG_VER}"

echo "== Removing ${PKG_NAME}/${PKG_VER} =="

if command -v dkms >/dev/null 2>&1 && \
   dkms status -m "$PKG_NAME" -v "$PKG_VER" 2>/dev/null | grep -q .; then
	echo "-- dkms remove..."
	dkms remove -m "$PKG_NAME" -v "$PKG_VER" --all || {
		echo "Warning: dkms remove reported an error." >&2
	}
fi

if [ -d "$DEST_DIR" ]; then
	echo "-- Removing ${DEST_DIR}..."
	rm -rf "$DEST_DIR"
fi

if [ -f /etc/modprobe.d/88x2bu-dkms-blacklist.conf ]; then
	echo "-- Removing rtw88 blacklist file..."
	rm -f /etc/modprobe.d/88x2bu-dkms-blacklist.conf
	update-initramfs -u 2>/dev/null || dracut -f 2>/dev/null || true
fi

modprobe -r "$MOD_NAME" 2>/dev/null || true

echo "Done. The in-kernel rtw88 driver will claim the adapter again on next plug-in."
