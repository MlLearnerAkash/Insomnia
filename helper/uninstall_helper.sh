#!/bin/sh
#
# Removes everything install_helper.sh installed:
#   sudo ./uninstall_helper.sh
#
# Insomnia keeps working afterwards — it just asks for an admin password on
# each toggle again, the way it does before the helper is set up.

set -eu

if [ "$(id -u)" -ne 0 ]; then
    echo "uninstall_helper.sh: must run as root" >&2
    exit 1
fi

rm -f /etc/sudoers.d/insomnia
rm -f /usr/local/libexec/insomnia-helper

echo "Insomnia helper and passwordless rule removed."
