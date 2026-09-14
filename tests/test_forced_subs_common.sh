#!/bin/bash
set -uo pipefail
cd "$(dirname "$0")"
source test_helpers.sh

REPO_ROOT="$(cd .. && pwd)"
source "$REPO_ROOT/lib/forced_subs_common.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "== walk_films prunes 'Our Family' and finds video files =="
mkdir -p "$WORK/films/Star Wars" "$WORK/films/Our Family"
touch "$WORK/films/Star Wars/Phantom Menace.mp4"
touch "$WORK/films/Our Family/birthday.mp4"
touch "$WORK/films/Star Wars/notes.txt"
found=$(walk_films "$WORK/films" | sort)
assert_contains "finds the Star Wars mp4" "$found" "Phantom Menace.mp4"
assert_eq "does not descend into Our Family" "no" "$([[ "$found" == *"birthday.mp4"* ]] && echo yes || echo no)"
assert_eq "ignores non-video files" "no" "$([[ "$found" == *"notes.txt"* ]] && echo yes || echo no)"

echo "== extract_year_from_name =="
assert_eq "finds a parenthesized year" "2026" "$(extract_year_from_name "Moana (2026).mp4")"
assert_eq "finds a dashed year" "2026" "$(extract_year_from_name "Moana - 2026.mp4")"
assert_eq "no year present" "" "$(extract_year_from_name "Phantom Menace.mp4")"

echo "== normalize_title_from_path strips tags but the caller controls year handling =="
title=$(normalize_title_from_path "$WORK/films/Star Wars/Phantom.Menace.1080p.BluRay.x264.mp4")
assert_eq "strips extension/dots/quality/codec tags" "Phantom Menace" "$title"

echo "== imdb_tt_to_numeric =="
assert_eq "strips tt and leading zeros" "120915" "$(imdb_tt_to_numeric "tt0120915")"

echo "== yaml_get_2level reads a nested value =="
cat > "$WORK/sample.yaml" <<'EOF'
opensubtitles:
  api_key: "abc123"
  username: "iainbate"
secrets_backup:
  passphrase_hash: "deadbeef"
EOF
assert_eq "reads opensubtitles.api_key" "abc123" "$(yaml_get_2level "$WORK/sample.yaml" opensubtitles api_key)"
assert_eq "reads a different top-level block" "deadbeef" "$(yaml_get_2level "$WORK/sample.yaml" secrets_backup passphrase_hash)"
assert_eq "missing key prints nothing" "" "$(yaml_get_2level "$WORK/sample.yaml" opensubtitles password)"

echo "== file_stat_signature =="
echo "hello" > "$WORK/sig.txt"
sig1=$(file_stat_signature "$WORK/sig.txt")
sig1_again=$(file_stat_signature "$WORK/sig.txt")
assert_eq "signature is stable for an untouched file" "$sig1" "$sig1_again"
sleep 1
echo "hello world, this is longer" > "$WORK/sig.txt"
sig2=$(file_stat_signature "$WORK/sig.txt")
assert_eq "signature changes when the file's content/size changes" "no" "$([[ "$sig1" == "$sig2" ]] && echo yes || echo no)"

echo "== fid_cache round-trips a row =="
export FID_CACHE="$WORK/fid_cache"
fid_cache_set "/mnt/HDD/films/Moana (2016).mp4" "tt3521164" "Moana" "2016" "hash" "" "2026-09-14"
assert_eq "reads back imdb_id" "tt3521164" "$(fid_cache_get_field "/mnt/HDD/films/Moana (2016).mp4" imdb_id)"
assert_eq "reads back confidence" "hash" "$(fid_cache_get_field "/mnt/HDD/films/Moana (2016).mp4" confidence)"
fid_cache_set "/mnt/HDD/films/Moana (2016).mp4" "tt3521164" "Moana" "2016" "manual" "" "2026-09-15"
assert_eq "a later set for the same path replaces the row, not appends" "1" "$(grep -c "Moana (2016)" "$FID_CACHE")"
assert_eq "unknown path exits non-zero" "no" "$(fid_cache_get_field "/no/such/path.mp4" imdb_id >/dev/null 2>&1 && echo yes || echo no)"

test_summary_and_exit
