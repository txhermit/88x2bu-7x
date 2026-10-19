#!/bin/sh
#
# dkms-install.sh — clean, non-interactive DKMS install for the 88x2bu-7x
# driver port (Realtek RTL8812BU / RTL8822BU USB WiFi, Linux 7.x kernels).
#
# Usage:
#   sudo ./dkms-install.sh [options]
#
# Options:
#   --blacklist-rtw88        blacklist the in-kernel rtw88_8812au driver so it
#                            does not claim the adapter before 88x2bu loads
#   --install-modprobe-conf  copy the repo's 88x2bu.conf to /etc/modprobe.d/
#                            (module options; also blacklists rtw88_8822bu)
#   --no-deps                skip automatic dependency installation
#   -h, --help               show this help
#
# What it does:
#   1. Installs dkms, gcc, make, bc and kernel headers (apt/dnf/pacman/zypper).
#   2. Stages a clean source tree (no .git, no build artifacts) in
#      /usr/src/<name>-<version> taken from dkms.conf.
#   3. Runs dkms add / build / install. AUTOINSTALL=yes in dkms.conf means
#      the module rebuilds automatically on kernel upgrades.
#   4. Optionally blacklists the in-kernel rtw88 driver and/or installs
#      the modprobe options file.
#   5. Loads the module and verifies.
#
# Notes:
#   - Run from the repo root (the directory containing dkms.conf).
#   - Re-running is safe: any previous DKMS instance of the same
#     name/version is removed first.
#   - If Secure Boot is enabled the unsigned module will not load; either
#     sign it (see docs) or disable Secure Boot in firmware.
#
# This is the short alternative to the upstream install-driver.sh, which
# supports both dkms and non-dkms installs and is interactive. If you want
# the upstream flow, use install-driver.sh instead.

BLACKLIST_RTW88=0
INSTALL_MODPROBE_CONF=0
INSTALL_DEPS=1

usage() {
	sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
}

for arg in "$@"; do
	case "$arg" in
		--blacklist-rtw88)       BLACKLIST_RTW88=1 ;;
		--install-modprobe-conf) INSTALL_MODPROBE_CONF=1 ;;
		--no-deps)               INSTALL_DEPS=0 ;;
		-h|--help)               usage; exit 0 ;;
		*) echo "Unknown option: $arg" >&2; usage >&2; exit 1 ;;
	esac
done

# --- must run as root -------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
	echo "This script must run as root. Re-running with sudo..." >&2
	exec sudo -E "$0" "$@"
fi

# --- must run from the repo root --------------------------------------------
if [ ! -f dkms.conf ] || [ ! -f dkms-make.sh ]; then
	echo "Error: dkms.conf not found. Run this script from the repo root." >&2
	exit 1
fi

PKG_NAME=$(grep '^PACKAGE_NAME=' dkms.conf | cut -d'"' -f2)
PKG_VER=$(grep '^PACKAGE_VERSION=' dkms.conf | cut -d'"' -f2)
MOD_NAME=$(grep '^BUILT_MODULE_NAME\[0\]=' dkms.conf | cut -d'"' -f2)
SRC_DIR=$(pwd)
DEST_DIR="/usr/src/${PKG_NAME}-${PKG_VER}"
KVER=$(uname -r)

if [ -z "$PKG_NAME" ] || [ -z "$PKG_VER" ] || [ -z "$MOD_NAME" ]; then
	echo "Error: could not parse dkms.conf (name/version/module)." >&2
	exit 1
fi

echo "== 88x2bu-7x DKMS install: ${PKG_NAME}/${PKG_VER} (module ${MOD_NAME}) =="

# --- dependencies ------------------------------------------------------------
if [ "$INSTALL_DEPS" -eq 1 ]; then
	echo "-- Installing build dependencies..."
	if command -v apt-get >/dev/null 2>&1; then
		apt-get update
		apt-get install -y dkms gcc make bc "linux-headers-${KVER}" \
			|| apt-get install -y dkms gcc make bc linux-headers-generic
	elif command -v dnf >/dev/null 2>&1; then
		dnf install -y gcc make bc dkms "kernel-devel-${KVER}" kernel-headers \
			elfutils-libelf-devel
	elif command -v pacman >/dev/null 2>&1; then
		pacman -Sy --noconfirm --needed base-devel dkms bc linux-headers
	elif command -v zypper >/dev/null 2>&1; then
		zypper install -y gcc make bc dkms "kernel-devel=${KVER}" kernel-devel
	else
		echo "Error: no supported package manager found (apt/dnf/pacman/zypper)." >&2
		echo "Install dkms, gcc, make, bc and the kernel headers for ${KVER} manually," >&2
		echo "then re-run with --no-deps." >&2
		exit 1
	fi
fi

if [ ! -d "/lib/modules/${KVER}/build" ]; then
	echo "Error: kernel headers for ${KVER} not found at /lib/modules/${KVER}/build." >&2
	echo "Install them for your distribution, then re-run." >&2
	exit 1
fi

# --- stage a clean source tree ----------------------------------------------
echo "-- Staging clean source in ${DEST_DIR}..."
if [ -d "$DEST_DIR" ]; then
	rm -rf "$DEST_DIR"
fi
mkdir -p "$DEST_DIR"

if [ -d .git ] && command -v git >/dev/null 2>&1; then
	# cleanest: exactly what is committed, no build artifacts
	git archive HEAD | tar -x -C "$DEST_DIR"
else
	# fallback: copy everything except VCS and build artifacts
	tar --exclude='./.git' \
	    --exclude='*.o' --exclude='*.ko' --exclude='*.mod' \
	    --exclude='.*.cmd' --exclude='./modules.order' \
	    --exclude='./Module.symvers' \
	    -cf - . | tar -x -C "$DEST_DIR"
fi

if [ ! -f "${DEST_DIR}/dkms.conf" ]; then
	echo "Error: staging failed, ${DEST_DIR}/dkms.conf missing." >&2
	exit 1
fi

# --- remove any previous DKMS instance of this driver ------------------------
if dkms status -m "$PKG_NAME" -v "$PKG_VER" 2>/dev/null | grep -q .; then
	echo "-- Removing previous DKMS instance ${PKG_NAME}/${PKG_VER}..."
	dkms remove -m "$PKG_NAME" -v "$PKG_VER" --all
fi

# --- dkms add / build / install ----------------------------------------------
echo "-- dkms add..."
dkms add -m "$PKG_NAME" -v "$PKG_VER" || {
	echo "Error: dkms add failed." >&2; exit 1
}

echo "-- dkms build (this takes a few minutes)..."
if ! dkms build -m "$PKG_NAME" -v "$PKG_VER" -k "$KVER"; then
	echo "Error: dkms build failed. Last lines of the build log:" >&2
	tail -n 30 "/var/lib/dkms/${PKG_NAME}/${PKG_VER}/build/make.log" >&2 || true
	exit 1
fi

echo "-- dkms install..."
dkms install -m "$PKG_NAME" -v "$PKG_VER" -k "$KVER" || {
	echo "Error: dkms install failed." >&2; exit 1
}

# --- optional: blacklist the in-kernel rtw88 driver --------------------------
if [ "$BLACKLIST_RTW88" -eq 1 ]; then
	echo "-- Blacklisting in-kernel rtw88_8812au..."
	cat > /etc/modprobe.d/88x2bu-dkms-blacklist.conf <<'EOF'
# Installed by 88x2bu-7x dkms-install.sh --blacklist-rtw88.
# Keeps the in-kernel rtw88 driver from claiming RTL8812AU adapters
# before 88x2bu loads. Remove this file to restore rtw88 behavior.
# (RTL8822BU adapters are covered by the blacklist in 88x2bu.conf.)
blacklist rtw88_8812au
EOF
	update-initramfs -u 2>/dev/null || dracut -f 2>/dev/null || true
fi

# --- optional: install the modprobe options file ------------------------------
if [ "$INSTALL_MODPROBE_CONF" -eq 1 ]; then
	echo "-- Installing /etc/modprobe.d/88x2bu.conf..."
	cp -f "${SRC_DIR}/88x2bu.conf" /etc/modprobe.d/88x2bu.conf
fi

# --- load and verify -----------------------------------------------------------
echo "-- Loading module..."
rmmod rtw88_8812au 2>/dev/null || true
modprobe "$MOD_NAME" || {
	echo "Warning: modprobe ${MOD_NAME} failed." >&2
	if command -v mokutil >/dev/null 2>&1 && mokutil --sb-state 2>/dev/null | grep -qi enabled; then
		echo "Secure Boot is enabled: the module must be signed before it will load." >&2
	fi
}

echo
echo "== Result =="
dkms status -m "$PKG_NAME" -v "$PKG_VER"
if lsmod | grep -q "^${MOD_NAME}"; then
	echo "Module ${MOD_NAME} is loaded."
else
	echo "Module ${MOD_NAME} is installed but not loaded (see warnings above)."
fi
echo "Done."
