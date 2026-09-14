#!/bin/bash
set -uo pipefail
cd "$(dirname "$0")"
source test_helpers.sh

REPO_ROOT="$(cd .. && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cp "$REPO_ROOT/scripts/encrypt_secrets.sh" "$REPO_ROOT/scripts/decrypt_secrets.sh" "$WORK/"
mkdir -p "$WORK/lib"
cp "$REPO_ROOT/scripts/lib/secrets_common.sh" "$WORK/lib/"
mkdir -p "$WORK/scripts/lib"
cp "$REPO_ROOT/scripts/lib/secrets_common.sh" "$WORK/scripts/lib/"
mv "$WORK/encrypt_secrets.sh" "$WORK/decrypt_secrets.sh" "$WORK/scripts/" 2>/dev/null || {
    mkdir -p "$WORK/scripts"
    cp "$REPO_ROOT/scripts/encrypt_secrets.sh" "$REPO_ROOT/scripts/decrypt_secrets.sh" "$WORK/scripts/"
}

cd "$WORK"
cat > secrets.yaml <<'EOF'
opensubtitles:
  api_key: "test-key-123"
  username: "tester"
  password: "hunter2"
secrets_backup:
  passphrase_hash: ""
EOF

echo "== encrypt with an explicit passphrase (non-interactive) =="
SECRETS_BACKUP_PASSPHRASE="correct-horse-battery-staple" bash scripts/encrypt_secrets.sh --quiet >/dev/null 2>&1 || true
# --quiet requires a configured hash OR the env var; env var path should succeed and write the .enc file.
assert_file_exists "secrets.yaml.enc was written" "secrets.yaml.enc"

echo "== decrypting into a fresh copy reproduces the original =="
mv secrets.yaml secrets.yaml.original
SECRETS_BACKUP_PASSPHRASE="correct-horse-battery-staple" SECRETS_BACKUP_OVERWRITE=1 bash scripts/decrypt_secrets.sh >/dev/null 2>&1
assert_eq "decrypted secrets.yaml matches the original byte-for-byte" \
    "$(cat secrets.yaml.original)" "$(cat secrets.yaml)"

echo "== wrong passphrase is refused =="
rm -f secrets.yaml
SECRETS_BACKUP_PASSPHRASE="wrong-passphrase" SECRETS_BACKUP_OVERWRITE=1 bash scripts/decrypt_secrets.sh >/dev/null 2>&1
exit_code=$?
assert_eq "wrong passphrase exits non-zero" "no" "$([[ $exit_code -eq 0 ]] && echo yes || echo no)"
assert_file_missing "wrong passphrase does not write secrets.yaml" "secrets.yaml"

test_summary_and_exit
