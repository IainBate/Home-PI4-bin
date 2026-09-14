# scripts/lib/secrets_common.sh - shared helpers for encrypt_secrets.sh / decrypt_secrets.sh.
# Sourced, never executed. Ported from ~/home_automation on the Home Pi4, with one
# change: read_configured_passphrase_hash uses a small awk reader instead of
# python3+pyyaml, since this repo has no Python dependency and secrets.yaml here
# only ever needs simple two-level key reads.

sha256_hex() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | cut -d' ' -f1
    else
        shasum -a 256 | cut -d' ' -f1
    fi
}

secrets_openssl() {
    openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt "$@" \
        -pass env:SECRETS_BACKUP_PASSPHRASE_HASH
}

# Prints secrets.yaml's secrets_backup.passphrase_hash, or nothing if absent.
# Run from the repo root (same convention as the ported original).
read_configured_passphrase_hash() {
    [ -f "secrets.yaml" ] || return 0
    awk '
        /^secrets_backup:/ { in_block=1; next }
        /^[^ \t]/ { in_block=0 }
        in_block && /^[ \t]*passphrase_hash:/ {
            sub(/^[^:]*:[ \t]*/, "")
            gsub(/^"|"$/, "")
            print
            exit
        }
    ' secrets.yaml
}
