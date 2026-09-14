#!/bin/bash
# encrypt_secrets.sh - Encrypt secrets.yaml into secrets.yaml.enc for backup in git.
# Ported from ~/home_automation on the Home Pi4 (see git history for the original's
# full design rationale). Passphrase: recommended is the Home Pi4's own login
# password - hashed with SHA-256 before use, never used raw as the openssl key.
#
# Passphrase source, checked in this order:
#   1. $SECRETS_BACKUP_PASSPHRASE, if set.
#   2. secrets_backup.passphrase_hash in secrets.yaml, if set.
#   3. Otherwise, prompts interactively (twice, must match).
#
# --quiet: for cron. Requires option 1 or 2 above.

set -e
cd "$(dirname "$0")/.."
. "scripts/lib/secrets_common.sh"

QUIET=false
[ "${1:-}" = "--quiet" ] && QUIET=true
log() { [ "$QUIET" = true ] || echo "$@"; }

if [ ! -f "secrets.yaml" ]; then
    echo "ERROR: secrets.yaml not found in $(pwd)" >&2
    exit 1
fi

WORK_ENC="$(mktemp "${TMPDIR:-/tmp}/secrets.enc.XXXXXX")"
WORK_PLAIN="$(mktemp "${TMPDIR:-/tmp}/secrets.plain.XXXXXX")"
cleanup() { rm -f "$WORK_ENC" "$WORK_PLAIN"; }
trap cleanup EXIT

PASSPHRASE_HASH=""
if [ -n "${SECRETS_BACKUP_PASSPHRASE:-}" ]; then
    PASSPHRASE_HASH="$(printf '%s' "$SECRETS_BACKUP_PASSPHRASE" | sha256_hex)"
else
    PASSPHRASE_HASH="$(read_configured_passphrase_hash)"
fi

if [ -z "$PASSPHRASE_HASH" ]; then
    if [ "$QUIET" = true ]; then
        echo "ERROR: --quiet needs secrets_backup.passphrase_hash in secrets.yaml, or \$SECRETS_BACKUP_PASSPHRASE." >&2
        exit 1
    fi
    if [ ! -t 0 ]; then
        echo "ERROR: no passphrase configured and no terminal to prompt on." >&2
        exit 1
    fi
    read -r -s -p "Passphrase: " RAW_PASSPHRASE; echo ""
    read -r -s -p "Passphrase (again): " RAW_PASSPHRASE_CONFIRM; echo ""
    if [ "$RAW_PASSPHRASE" != "$RAW_PASSPHRASE_CONFIRM" ] || [ -z "$RAW_PASSPHRASE" ]; then
        echo "ERROR: passphrases didn't match (or were empty) - nothing was changed." >&2
        exit 1
    fi
    PASSPHRASE_HASH="$(printf '%s' "$RAW_PASSPHRASE" | sha256_hex)"
    unset RAW_PASSPHRASE RAW_PASSPHRASE_CONFIRM
    echo "Computed hash (paste into secrets_backup.passphrase_hash for unattended runs):"
    echo "  $PASSPHRASE_HASH"
fi

export SECRETS_BACKUP_PASSPHRASE_HASH="$PASSPHRASE_HASH"

UNCHANGED=false
if [ -f "secrets.yaml.enc" ]; then
    if secrets_openssl -d -in secrets.yaml.enc -out "$WORK_PLAIN" 2>/dev/null &&
       cmp -s "$WORK_PLAIN" "secrets.yaml"; then
        UNCHANGED=true
    fi
fi
if [ "$UNCHANGED" = true ]; then
    log "secrets.yaml is unchanged since the last backup - nothing to do."
    exit 0
fi

secrets_openssl -e -in secrets.yaml -out "$WORK_ENC"
if ! secrets_openssl -d -in "$WORK_ENC" -out "$WORK_PLAIN" 2>/dev/null ||
   ! cmp -s "$WORK_PLAIN" "secrets.yaml"; then
    echo "ERROR: the new backup did not decrypt back to secrets.yaml - refusing to replace secrets.yaml.enc." >&2
    exit 1
fi

cp "$WORK_ENC" secrets.yaml.enc
chmod 644 secrets.yaml.enc
log "Wrote secrets.yaml.enc (verified it decrypts back to secrets.yaml)."
