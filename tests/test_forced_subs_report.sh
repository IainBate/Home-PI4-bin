#!/bin/bash
set -uo pipefail
cd "$(dirname "$0")"
source test_helpers.sh

REPO_ROOT="$(cd .. && pwd)"
FORCED_SUBS="$REPO_ROOT/forced_subs"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/lib" "$WORK/films/Star Wars"
cp "$REPO_ROOT/lib/forced_subs_common.sh" "$REPO_ROOT/lib/known_films.py" "$WORK/lib/"
cat > "$WORK/lib/ost.py" <<'PYEOF'
import sys
if sys.argv[1] == "hash":
    print("0000000000000000")
PYEOF

cat > "$WORK/films.yaml" <<'EOF'
films:
  - title: "Star Wars: Episode I - The Phantom Menace"
    aliases: "Phantom Menace"
    year: 1999
    imdb_id: "tt0120915"
    editions: "theatrical:0"
EOF

ffmpeg -y -f lavfi -i testsrc=duration=3:size=320x180:rate=10 -f lavfi -i sine=duration=3 \
    -pix_fmt yuv420p "$WORK/films/Star Wars/Phantom Menace.mp4" -hide_banner -loglevel error
ffmpeg -y -f lavfi -i testsrc=duration=3:size=320x180:rate=10 -f lavfi -i sine=duration=3 \
    -pix_fmt yuv420p "$WORK/films/Star Wars/Unmatched Obscure Film (2015).mp4" -hide_banner -loglevel error

export FORCED_SUBS_LIBDIR="$WORK/lib"
export FORCED_SUBS_KNOWN_FILMS="$WORK/films.yaml"
export FORCED_SUBS_LOCKFILE="$WORK/forced_subs.lock"
export FID_CACHE="$WORK/fid_cache"
export FORCED_SUBS_FILMS_ROOT="$WORK/films"
export FORCED_SUBS_REPORT_FILE="$WORK/logs/forced_subs_report.txt"
export SCAN_LOG="$WORK/scan_log"
export SCAN_CACHE="$WORK/scan_cache"
export APPLY_LOG="$WORK/apply_log"
export UNAVAILABLE_CACHE="$WORK/unavailable_cache"
export OST_API_KEY=test OST_USER_AGENT=test OST_USERNAME=test OST_PASSWORD=test

# Simulate a prior apply run: Phantom Menace was already fixed.
printf '2026-09-14T00:00:00Z\t%s\tsuccess\tremuxed\n' "$WORK/films/Star Wars/Phantom Menace.mp4" > "$APPLY_LOG"

out=$("$FORCED_SUBS" report)

echo "== three sections are present =="
assert_contains "has the already-fine section" "$out" "Already fine"
assert_contains "has the added-by-script section" "$out" "Added by this script"
assert_contains "has the manual-attention section" "$out" "sort these out yourself"

echo "== the previously-applied file appears under added-by-script =="
assert_contains "Phantom Menace listed as added" "$out" "Phantom Menace.mp4"

echo "== the unmatched obscure film appears under manual attention =="
assert_contains "Unmatched Obscure Film listed for manual attention" "$out" "Unmatched Obscure Film"

echo "== the report is also written to REPORT_FILE (a log location, not the films root) =="
assert_file_exists "report file written to REPORT_FILE" "$WORK/logs/forced_subs_report.txt"
assert_eq "file content matches what was printed to stdout" "$out" "$(cat "$WORK/logs/forced_subs_report.txt")"

echo "== nothing is ever written into the films root itself =="
# The films library is the user's media, not this tool's bookkeeping
# space - regression test for an earlier design that wrote the report
# straight into $FILMS_ROOT.
leftover=$(find "$WORK/films" -maxdepth 1 -type f)
assert_eq "no stray files created directly in the films root" "" "$leftover"

test_summary_and_exit
