#!/bin/bash
# decrypt_secrets.sh - Restore secrets.yaml from its encrypted git backup.
# Ported from ~/home_automation on the Home Pi4. Run from the repo root.

set -e
cd "$(dirname "$0")/.."
. "scripts/lib/secrets_common.sh"

if [ ! -f "secrets.yaml.enc" ]; then
    echo "ERROR: secrets.yaml.enc not found in $(pwd)" >&2
    exit 1
fi

if [ -f "secrets.yaml" ]; then
    if [ -n "${SECRETS_BACKUP_OVERWRITE:-}" ]; then
        echo "secrets.yaml already exists - overwriting (SECRETS_BACKUP_OVERWRITE set)."
    elif [ ! -t 0 ]; then
        echo "ERROR: secrets.yaml exists and there's no terminal to confirm on. Set SECRETS_BACKUP_OVERWRITE=1." >&2
        exit 1
    else
        read -r -p "secrets.yaml already exists - overwrite it? [y/N] " confirm
        if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
            echo "Aborted. Nothing was changed."
            exit 1
        fi
    fi
fi

if [ -n "${SECRETS_BACKUP_PASSPHRASE:-}" ]; then
    PASSPHRASE_HASH="$(printf '%s' "$SECRETS_BACKUP_PASSPHRASE" | sha256_hex)"
else
    if [ ! -t 0 ]; then
        echo "ERROR: no terminal to prompt on. Set \$SECRETS_BACKUP_PASSPHRASE to run non-interactively." >&2
        exit 1
    fi
    read -r -s -p "Passphrase: " RAW_PASSPHRASE; echo ""
    PASSPHRASE_HASH="$(printf '%s' "$RAW_PASSPHRASE" | sha256_hex)"
    unset RAW_PASSPHRASE
fi

WORK_PLAIN="$(mktemp "${TMPDIR:-/tmp}/secrets.plain.XXXXXX")"
trap 'rm -f "$WORK_PLAIN"' EXIT

export SECRETS_BACKUP_PASSPHRASE_HASH="$PASSPHRASE_HASH"
if ! secrets_openssl -d -in secrets.yaml.enc -out "$WORK_PLAIN" 2>/dev/null; then
    echo "ERROR: could not decrypt secrets.yaml.enc - wrong passphrase? Nothing was changed." >&2
    exit 1
fi
unset SECRETS_BACKUP_PASSPHRASE_HASH

if ! grep -q ":" "$WORK_PLAIN"; then
    echo "ERROR: decrypted output doesn't look like secrets.yaml - refusing to install it." >&2
    exit 1
fi

cp "$WORK_PLAIN" secrets.yaml
chmod 600 secrets.yaml
echo "Restored secrets.yaml"
