#!/usr/bin/env bash
# Install the omacool daemon. The Omarchy plugin itself needs no installation —
# `omarchy plugin add` handles that — but writing pwm* needs root, so the
# control loop runs as a system service and the panel talks to it over a socket.
#
# No unix group is created and no user is granted anything permanently: who may
# change a fan is decided per command by polkit, and the shipped policy grants
# it to whoever holds the active local session.
set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR=/usr/local/lib/omacool
BIN_LINK=/usr/local/bin/omacool
UNIT=/etc/systemd/system/omacool.service
POLICY_DIR=/usr/share/polkit-1/actions
POLICY=io.github.giovesch.omacool.policy

fail() { echo "install.sh: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || fail "run this with sudo or pkexec: sudo ./install.sh"
command -v systemctl >/dev/null || fail "systemd is required"
command -v python3 >/dev/null || fail "python3 is required"
command -v pkcheck >/dev/null || fail "polkit is required (pkcheck not found)"

echo "==> installing omacool to $LIB_DIR"
install -d -m 0755 "$LIB_DIR"
install -m 0755 "$SOURCE_DIR/bin/omacool" "$LIB_DIR/omacool"
ln -sf "$LIB_DIR/omacool" "$BIN_LINK"

echo "==> installing the polkit policy"
install -d -m 0755 "$POLICY_DIR"
install -m 0644 "$SOURCE_DIR/polkit/$POLICY" "$POLICY_DIR/$POLICY"

echo "==> installing the service"
install -d -m 0755 /etc/omacool
install -m 0644 "$SOURCE_DIR/systemd/omacool.service" "$UNIT"
systemctl daemon-reload
systemctl enable --now omacool.service

sleep 1
if systemctl is-active --quiet omacool.service; then
  echo "==> omacool is running"
else
  echo "==> omacool failed to start; see: journalctl -u omacool -n 40" >&2
fi

echo
echo "Detected hardware:"
"$LIB_DIR/omacool" list || true
echo
echo "If no fans are listed, your board's sensor modules are probably not loaded."
echo "On most desktops:  sudo sensors-detect  then reboot."
echo
echo "Fan control is now available to the active local session — no password, no"
echo "logout, and nothing granted to SSH or background jobs. To require a password"
echo "instead, set allow_active to auth_admin_keep in:"
echo "  $POLICY_DIR/$POLICY"
