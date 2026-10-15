#!/bin/sh
#
# Installs the Insomnia privileged helper and the passwordless sudo rule.
#
#   sudo ./install_helper.sh            # used by ./build_app.sh --install
#   install_helper.sh <username>        # used by the app's one-time setup button
#
# After this runs once, Insomnia toggles the sleep setting with no password.
# Everything it installs is removed again by ./uninstall_helper.sh.

set -eu

HELPER_DEST=/usr/local/libexec/insomnia-helper
SUDOERS_DEST=/etc/sudoers.d/insomnia
TARGET_USER="${1:-${SUDO_USER:-}}"

if [ "$(id -u)" -ne 0 ]; then
    echo "install_helper.sh: must run as root" >&2
    exit 1
fi

if [ -z "$TARGET_USER" ]; then
    echo "install_helper.sh: could not work out which user to authorize" >&2
    echo "                  (pass the user name as the first argument)" >&2
    exit 1
fi

case "$TARGET_USER" in
    *[!A-Za-z0-9._-]*) echo "install_helper.sh: invalid user name: $TARGET_USER" >&2; exit 1 ;;
esac

if ! id -u "$TARGET_USER" >/dev/null 2>&1; then
    echo "install_helper.sh: no such user: $TARGET_USER" >&2
    exit 1
fi

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
SRC="$SCRIPT_DIR/insomnia-helper"
if [ ! -f "$SRC" ]; then
    echo "install_helper.sh: insomnia-helper not found next to this script" >&2
    exit 1
fi

mkdir -p /usr/local/libexec
chown root:wheel /usr/local/libexec 2>/dev/null || true
chmod 755 /usr/local/libexec

install -o root -g wheel -m 0755 "$SRC" "$HELPER_DEST"

printf '%s\n' \
    "# Installed by Insomnia; delete this file to revoke passwordless access." \
    "# It grants only the fixed Insomnia helper, which validates its arguments." \
    "${TARGET_USER} ALL=(root) NOPASSWD: ${HELPER_DEST}" \
    > "$SUDOERS_DEST"
chown root:wheel "$SUDOERS_DEST"
chmod 0440 "$SUDOERS_DEST"

# Never leave a malformed sudoers file behind — that would break sudo entirely.
if ! /usr/sbin/visudo -cf "$SUDOERS_DEST" >/dev/null 2>&1; then
    rm -f "$SUDOERS_DEST"
    echo "install_helper.sh: sudoers rule failed validation and was removed" >&2
    exit 1
fi

if ! "$HELPER_DEST" ping >/dev/null 2>&1; then
    echo "install_helper.sh: helper failed its self-test" >&2
    exit 1
fi

echo "helper:      $HELPER_DEST"
echo "passwordless: ${TARGET_USER} ALL=(root) NOPASSWD: ${HELPER_DEST}"
