#!/bin/bash
set -uo pipefail
cd "$(dirname "$0")"
source test_helpers.sh

REPO_ROOT="$(cd .. && pwd)"
FORCED_SUBS="$REPO_ROOT/forced_subs"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/lib" "$WORK/films/Star Wars" "$WORK/films/Unmatched"
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

# has_forced.mkv: real forced English subtitle, high coverage -> HAS_FORCED
# needs_known.mp4: on the curated list, no subs at all -> NEEDS_FORCED_KNOWN
# needs_unknown.mp4: not on the curated list -> NEEDS_FORCED_UNKNOWN
ffmpeg -y -f lavfi -i testsrc=duration=10:size=320x180:rate=10 -f lavfi -i sine=duration=10 \
    -pix_fmt yuv420p "$WORK/base.mp4" -hide_banner -loglevel error
cat > "$WORK/high.srt" <<'EOF'
1
00:00:00,000 --> 00:00:05,000
Hola
EOF
ffmpeg -y -i "$WORK/base.mp4" -i "$WORK/high.srt" -map 0:v -map 0:a -map 1:s -c:v copy -c:a copy -c:s srt \
    -metadata:s:s:0 language=eng -disposition:s:0 forced "$WORK/films/Star Wars/has_forced.mkv" -hide_banner -loglevel error
ffmpeg -y -i "$WORK/base.mp4" -map 0:v -map 0:a -c copy "$WORK/films/Star Wars/Phantom Menace.mp4" -hide_banner -loglevel error
ffmpeg -y -i "$WORK/base.mp4" -map 0:v -map 0:a -c copy "$WORK/films/Unmatched/Some Random Film (2015).mp4" -hide_banner -loglevel error

export FORCED_SUBS_LIBDIR="$WORK/lib"
export FORCED_SUBS_KNOWN_FILMS="$WORK/films.yaml"
export FORCED_SUBS_LOCKFILE="$WORK/forced_subs.lock"
export FID_CACHE="$WORK/fid_cache"
export FORCED_SUBS_FILMS_ROOT="$WORK/films"
export SCAN_LOG="$WORK/scan_log"
export SCAN_CACHE="$WORK/scan_cache"
export OST_API_KEY=test OST_USER_AGENT=test OST_USERNAME=test OST_PASSWORD=test

out=$("$FORCED_SUBS" scan)

echo "== HAS_FORCED for a file with a real forced track =="
assert_contains "has_forced.mkv bucketed HAS_FORCED" "$out" "$(printf 'HAS_FORCED\t%s/films/Star Wars/has_forced.mkv' "$WORK")"

echo "== NEEDS_FORCED_KNOWN for a curated, subtitle-less file =="
line=$(printf '%s\n' "$out" | grep "Phantom Menace.mp4")
assert_contains "bucketed NEEDS_FORCED_KNOWN" "$line" "NEEDS_FORCED_KNOWN"
assert_contains "carries the matched imdb_id" "$line" "tt0120915"
assert_contains "picks the theatrical edition" "$line" "theatrical"

echo "== NEEDS_FORCED_UNKNOWN for a file not on the curated list =="
line=$(printf '%s\n' "$out" | grep "Some Random Film")
assert_contains "bucketed NEEDS_FORCED_UNKNOWN" "$line" "NEEDS_FORCED_UNKNOWN"
assert_contains "reason is no_match" "$line" "no_match"

echo "== scan also appends to SCAN_LOG =="
assert_file_exists "scan log was written" "$SCAN_LOG"

echo "== incremental: an unchanged HAS_FORCED file is replayed from cache, not re-probed =="
"$FORCED_SUBS" scan >/dev/null  # populate the cache
# Point CONVERT_VIDEO at a nonexistent path for this run only: if the cached
# HAS_FORCED file still reports correctly, it proves scan didn't need to
# call convert_video for it at all (the file genuinely can't be re-probed).
out2=$(FORCED_SUBS_CONVERT_VIDEO="$WORK/no-such-convert_video" "$FORCED_SUBS" scan 2>&1)
assert_contains "HAS_FORCED file still reported correctly with convert_video unavailable" "$out2" "$(printf 'HAS_FORCED\t%s/films/Star Wars/has_forced.mkv' "$WORK")"

test_summary_and_exit
