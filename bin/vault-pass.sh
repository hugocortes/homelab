#!/bin/sh
# ansible-vault password provider.
#
# Reads the vault passphrase from the macOS Keychain so it is never stored in
# the repo, in a dotfile, or in shell history. Referenced by ansible.cfg via
# vault_password_file.
#
# One-time setup on a new control node:
#   security add-generic-password -a "$USER" -s ansible-vault-homelab -w '<passphrase>'
#
# This script contains no secret and is safe to commit.
set -eu

SERVICE="ansible-vault-homelab"

if ! command -v security >/dev/null 2>&1; then
    echo "vault-pass.sh: 'security' not found; this provider is macOS-only." >&2
    exit 1
fi

if ! security find-generic-password -a "$USER" -s "$SERVICE" -w 2>/dev/null; then
    echo "vault-pass.sh: no Keychain entry for service '$SERVICE' (account '$USER')." >&2
    echo "vault-pass.sh: create it with:" >&2
    echo "  security add-generic-password -a \"\$USER\" -s $SERVICE -w '<passphrase>'" >&2
    exit 1
fi
