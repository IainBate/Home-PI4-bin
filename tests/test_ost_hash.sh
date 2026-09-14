#!/bin/bash
set -uo pipefail
cd "$(dirname "$0")"
source test_helpers.sh

REPO_ROOT="$(cd .. && pwd)"
OST_PY="$REPO_ROOT/lib/ost.py"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

dd if=/dev/zero bs=1024 count=200 2>/dev/null | tr '\0' 'A' > "$WORK/a.bin"
cp "$WORK/a.bin" "$WORK/a_copy.bin"
dd if=/dev/zero bs=1024 count=200 2>/dev/null | tr '\0' 'B' > "$WORK/b.bin"

h1=$(python3 "$OST_PY" hash "$WORK/a.bin")
h1_again=$(python3 "$OST_PY" hash "$WORK/a.bin")
h_copy=$(python3 "$OST_PY" hash "$WORK/a_copy.bin")
h_b=$(python3 "$OST_PY" hash "$WORK/b.bin")

echo "== format =="
assert_eq "hash is 16 lowercase hex chars" "yes" "$(printf '%s' "$h1" | grep -qE '^[0-9a-f]{16}$' && echo yes || echo no)"

echo "== deterministic =="
assert_eq "same file hashed twice matches" "$h1" "$h1_again"

echo "== identical content produces identical hash =="
assert_eq "copy matches original" "$h1" "$h_copy"

echo "== different content produces different hash =="
assert_eq "different content differs" "no" "$([[ "$h1" == "$h_b" ]] && echo yes || echo no)"

echo "== only head+tail 64KB are sampled: a middle-only edit doesn't change the hash =="
cp "$WORK/a.bin" "$WORK/a_middle_changed.bin"
dd if=/dev/zero bs=1 count=10 conv=notrunc of="$WORK/a_middle_changed.bin" seek=100000 2>/dev/null
h_middle=$(python3 "$OST_PY" hash "$WORK/a_middle_changed.bin")
assert_eq "middle-only edit leaves hash unchanged" "$h1" "$h_middle"

test_summary_and_exit
