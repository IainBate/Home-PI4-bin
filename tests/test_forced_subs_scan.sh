#!/bin/bash
set -uo pipefail
cd "$(dirname "$0")"
source test_helpers.sh

REPO_ROOT="$(cd .. && pwd)"
FORCED_SUBS="$REPO_ROOT/forced_subs"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/lib" "$WORK/films/Star Wars" "$WORK/films/Unmatched" "$WORK/films/TitleSearch"
cp "$REPO_ROOT/lib/forced_subs_common.sh" "$REPO_ROOT/lib/known_films.py" "$WORK/lib/"
cat > "$WORK/lib/ost.py" <<'PYEOF'
import sys
cmd = sys.argv[1]
if cmd == "hash":
    print("0000000000000000")
elif cmd == "search_by_title":
    if sys.argv[2] == "Uncurated Resolvable Film":
        print("tt7777777\tUncurated Resolvable Film\t2024")
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
ffmpeg -y -i "$WORK/base.mp4" -map 0:v -map 0:a -c copy "$WORK/films/TitleSearch/Uncurated Resolvable Film.mp4" -hide_banner -loglevel error

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

echo "== NEEDS_FORCED_KNOWN for a film resolved via title-search alone, with no curated entry at all =="
# known_films.yaml's role has narrowed to supplying edition-safety data
# for titles with real multiple cuts, not gating whether a film gets
# attempted at all - any resolved imdb_id (from any identify tier) is
# now eligible, so this un-curated film still buckets as NEEDS_FORCED_KNOWN.
line=$(printf '%s\n' "$out" | grep "Uncurated Resolvable Film")
assert_contains "bucketed NEEDS_FORCED_KNOWN despite no curated entry" "$line" "NEEDS_FORCED_KNOWN"
assert_contains "carries the title-search-resolved imdb_id" "$line" "tt7777777"
assert_contains "edition is unmatched (no curated edition data exists)" "$line" "unmatched_edition"

echo "== scan also appends to SCAN_LOG =="
assert_file_exists "scan log was written" "$SCAN_LOG"

echo "== incremental: an unchanged HAS_FORCED file is replayed from cache, not re-probed =="
"$FORCED_SUBS" scan >/dev/null  # populate the cache
# Point CONVERT_VIDEO at a nonexistent path for this run only: if the cached
# HAS_FORCED file still reports correctly, it proves scan didn't need to
# call convert_video for it at all (the file genuinely can't be re-probed).
out2=$(FORCED_SUBS_CONVERT_VIDEO="$WORK/no-such-convert_video" "$FORCED_SUBS" scan 2>&1)
assert_contains "HAS_FORCED file still reported correctly with convert_video unavailable" "$out2" "$(printf 'HAS_FORCED\t%s/films/Star Wars/has_forced.mkv' "$WORK")"

# A stand-in convert_video that records every invocation to a marker log
# (so the tests below can prove whether a re-probe actually happened)
# while still returning realistic --analyze-subs output.
MARKER_LOG="$WORK/convert_video_marker_log"
FAKE_CONVERT_VIDEO="$WORK/fake_convert_video.sh"
cat > "$FAKE_CONVERT_VIDEO" <<EOF
#!/bin/bash
echo "\$2" >> "$MARKER_LOG"
echo "COVERAGE=0 FORCED=0 EXTERNAL_SRT=0"
EOF
chmod +x "$FAKE_CONVERT_VIDEO"
PHANTOM_FILE="$WORK/films/Star Wars/Phantom Menace.mp4"

echo "== incremental: a freshly-checked NEEDS_FORCED_KNOWN file is replayed from cache within the freshness window =="
"$FORCED_SUBS" scan >/dev/null  # populate the cache with today's checked_date
rm -f "$MARKER_LOG"
FORCED_SUBS_CONVERT_VIDEO="$FAKE_CONVERT_VIDEO" "$FORCED_SUBS" scan >/dev/null
if grep -qF "$PHANTOM_FILE" "$MARKER_LOG" 2>/dev/null; then
    fail "Phantom Menace was re-probed even though its cache entry is fresh"
else
    pass "Phantom Menace was NOT re-probed (replayed from cache, still within the freshness window)"
fi

echo "== incremental: a stale (>=SCAN_FRESHNESS_DAYS) NEEDS_FORCED_KNOWN entry is re-probed =="
# Back-date just this one cache row's checked_date (last field) well past
# the default 30-day freshness window, leaving its bucket/other fields
# untouched.
awk -F'\t' -v OFS='\t' -v p="$PHANTOM_FILE" '$1==p {$NF="2020-01-01"} {print}' "$SCAN_CACHE" > "$SCAN_CACHE.tmp"
mv "$SCAN_CACHE.tmp" "$SCAN_CACHE"
rm -f "$MARKER_LOG"
FORCED_SUBS_CONVERT_VIDEO="$FAKE_CONVERT_VIDEO" "$FORCED_SUBS" scan >/dev/null
if grep -qF "$PHANTOM_FILE" "$MARKER_LOG" 2>/dev/null; then
    pass "Phantom Menace was re-probed once its cache entry went stale"
else
    fail "Phantom Menace should have been re-probed - its cache entry is well past the freshness window"
fi

echo "== scan --rehash forces a re-probe even within the freshness window =="
"$FORCED_SUBS" scan >/dev/null  # re-populate with today's checked_date again
rm -f "$MARKER_LOG"
FORCED_SUBS_CONVERT_VIDEO="$FAKE_CONVERT_VIDEO" "$FORCED_SUBS" scan --rehash >/dev/null
if grep -qF "$PHANTOM_FILE" "$MARKER_LOG" 2>/dev/null; then
    pass "scan --rehash re-probed a file despite its fresh cache entry"
else
    fail "scan --rehash should bypass the freshness check entirely"
fi

echo "== scan --rehash also gives a previously-unresolved file another identify attempt =="
# "Some Random Film" resolved to nothing on the first scan (no hash match,
# not curated, and the fake ost.py's search_by_title only recognizes
# "Uncurated Resolvable Film"). Point search_by_title at it now and confirm
# a plain scan leaves it alone (sticky "unresolved" cache) while
# scan --rehash gives it a fresh identify attempt that resolves it.
RANDOM_FILM="$WORK/films/Unmatched/Some Random Film (2015).mp4"
cat > "$WORK/lib/ost.py" <<'PYEOF'
import sys
cmd = sys.argv[1]
if cmd == "hash":
    print("0000000000000000")
elif cmd == "search_by_title":
    if sys.argv[2] in ("Uncurated Resolvable Film", "Some Random Film"):
        print("tt5432109\tSome Random Film\t2015")
PYEOF
out_plain=$("$FORCED_SUBS" scan)
line=$(printf '%s\n' "$out_plain" | grep "Some Random Film")
assert_contains "plain scan leaves it NEEDS_FORCED_UNKNOWN (identify cache is sticky without --rehash)" "$line" "NEEDS_FORCED_UNKNOWN"

out_rehash=$("$FORCED_SUBS" scan --rehash)
line2=$(printf '%s\n' "$out_rehash" | grep "Some Random Film")
assert_contains "scan --rehash resolves it via a fresh identify attempt" "$line2" "NEEDS_FORCED_KNOWN"
assert_contains "carries the newly title-search-resolved imdb_id" "$line2" "tt5432109"

echo "== a plain 'identify --rehash' (not scan --rehash) still gets picked up by a later PLAIN scan =="
# Regression test for a real production incident: cmd_scan's freshness
# check only looks at the file's own stat signature and a time window -
# it has no way to notice identify resolved a file that scan itself
# already cached as unresolved, since the video file itself never
# changed. Without fid_cache_set's scan_cache invalidation, a plain scan
# (as apply calls internally) would keep replaying the stale
# NEEDS_FORCED_UNKNOWN bucket for up to SCAN_FRESHNESS_DAYS regardless of
# how many times `identify --rehash` re-resolves the file in the
# meantime - exactly what happened the first time this shipped (223
# newly-identified films were invisible to `apply` until this fix).
INVALIDATION_FILM="$WORK/films/TitleSearch/Invalidation Film.mp4"
ffmpeg -y -i "$WORK/base.mp4" -map 0:v -map 0:a -c copy "$INVALIDATION_FILM" -hide_banner -loglevel error

cat > "$WORK/lib/ost.py" <<'PYEOF'
import sys
cmd = sys.argv[1]
if cmd == "hash":
    print("0000000000000000")
PYEOF
out_before=$("$FORCED_SUBS" scan)
line_before=$(printf '%s\n' "$out_before" | grep "Invalidation Film")
assert_contains "starts out unresolved (no search_by_title match yet)" "$line_before" "NEEDS_FORCED_UNKNOWN"

# Now the title becomes resolvable (simulating TMDB/title-search finding
# it on a later attempt) and identify --rehash (NOT scan --rehash) is
# run directly - this is the exact sequence a real deployment uses:
# `forced_subs identify --rehash` followed later by the plain,
# freshness-respecting `forced_subs apply` (which calls plain `scan`
# internally, no --rehash).
cat > "$WORK/lib/ost.py" <<'PYEOF'
import sys
cmd = sys.argv[1]
if cmd == "hash":
    print("0000000000000000")
elif cmd == "search_by_title":
    if sys.argv[2] == "Invalidation Film":
        print("tt2468013\tInvalidation Film\t2022")
PYEOF
"$FORCED_SUBS" identify --rehash >/dev/null
assert_eq "identify --rehash alone resolved the imdb_id in fid_cache" "tt2468013" "$(source "$WORK/lib/forced_subs_common.sh"; FID_CACHE="$WORK/fid_cache" fid_cache_get_field "$INVALIDATION_FILM" imdb_id)"

out_after=$("$FORCED_SUBS" scan)
line_after=$(printf '%s\n' "$out_after" | grep "Invalidation Film")
assert_contains "a later PLAIN scan (no --rehash) now sees the update" "$line_after" "NEEDS_FORCED_KNOWN"
assert_contains "carries the newly-resolved imdb_id" "$line_after" "tt2468013"

test_summary_and_exit
