#!/bin/bash
# install-demo-sudoers.sh — One-time setup for passwordless XFS demo commands.
# Run: sudo bash scripts/install-demo-sudoers.sh
set -euo pipefail

SUDOERS_FILE="/etc/sudoers.d/dataplane-demo"
USER="dragonix"

cat > "$SUDOERS_FILE" << EOF
# Passwordless commands for dataplane-emu XFS demo probe
${USER} ALL=(root) NOPASSWD: /usr/sbin/losetup --find --show /tmp/dataplane_xfs_loop.img
${USER} ALL=(root) NOPASSWD: /usr/sbin/losetup -d /dev/loop*
${USER} ALL=(root) NOPASSWD: /usr/sbin/mkfs.xfs -f /dev/loop*
${USER} ALL=(root) NOPASSWD: /usr/bin/mount /dev/loop* /tmp/dataplane_xfs_mnt
${USER} ALL=(root) NOPASSWD: /usr/bin/umount /tmp/dataplane_xfs_mnt
${USER} ALL=(root) NOPASSWD: /usr/bin/chmod 777 /tmp/dataplane_xfs_mnt
${USER} ALL=(root) NOPASSWD: /usr/bin/sh -c echo 3 > /proc/sys/vm/drop_caches
EOF

chmod 0440 "$SUDOERS_FILE"

if visudo -cf "$SUDOERS_FILE"; then
    echo "✓ Installed $SUDOERS_FILE — passwordless XFS demo commands enabled."
else
    rm -f "$SUDOERS_FILE"
    echo "✗ Syntax error — removed $SUDOERS_FILE. Please check and retry."
    exit 1
fi
