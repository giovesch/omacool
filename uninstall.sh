#!/usr/bin/env bash
# Remove the omacool daemon. Stopping the service hands every fan back to the
# firmware first, so this is safe to run at any time.
set -euo pipefail

LIB_DIR=/usr/local/lib/omacool
BIN_LINK=/usr/local/bin/omacool
UNIT=/etc/systemd/system/omacool.service
POLICY=/usr/share/polkit-1/actions/io.github.giovesch.omacool.policy

fail() { echo "uninstall.sh: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || fail "run this with sudo: sudo ./uninstall.sh"

echo "==> stopping the service"
systemctl disable --now omacool.service 2>/dev/null || true
rm -f "$UNIT"
systemctl daemon-reload

echo "==> removing files"
rm -f "$BIN_LINK" "$POLICY"
rm -rf "$LIB_DIR"

if [[ ${1:-} == --purge ]]; then
  echo "==> removing configuration"
  rm -rf /etc/omacool
else
  echo "==> keeping /etc/omacool (pass --purge to remove it)"
fi

echo "Remove the panel separately with:"
echo "  omarchy plugin remove io.github.giovesch.omacool"
