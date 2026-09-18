#!/bin/bash
set -uo pipefail
cd "$(dirname "$0")"
source test_helpers.sh

REPO_ROOT="$(cd .. && pwd)"
FORCED_SUBS="$REPO_ROOT/forced_subs"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/lib" "$WORK/films/Star Wars" "$WORK/films/Curated" \
    "$WORK/films/NotCurated" "$WORK/films/MoanaCollision"
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
  - title: "Some Curated Film"
    aliases: ""
    year: 2021
    imdb_id: "tt2222222"
    editions: "theatrical:0"
  - title: "Moana"
    aliases: ""
    year: 2016
    imdb_id: "tt3521164"
    editions: "theatrical:0"
  - title: "Moana"
    aliases: ""
    year: 2026
    imdb_id: "tt9999999"
    editions: "theatrical:0"
EOF

for f in "Star Wars/Phantom Menace.mp4" "Star Wars/Unmatched Obscure Film (2015).mp4" \
    "Curated/Some Curated Film.mp4" "NotCurated/Some Uncurated Film.mp4" "MoanaCollision/Moana.mp4"; do
    ffmpeg -y -f lavfi -i testsrc=duration=3:size=320x180:rate=10 -f lavfi -i sine=duration=3 \
        -pix_fmt yuv420p "$WORK/films/$f" -hide_banner -loglevel error
done

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

# "Some Curated Film" is already identified (manual, sticky) and on the
# curated list, but apply couldn't fetch a matching subtitle for it -
# a fresh unavailable_cache entry, as apply itself would leave behind.
printf '%s\ttt2222222\tSome Curated Film\t2021\tmanual\t\t2026-01-01\n' \
    "$WORK/films/Curated/Some Curated Film.mp4" >> "$FID_CACHE"
printf '%s\tno_match_found\t%s\n' "$WORK/films/Curated/Some Curated Film.mp4" "$(date -I)" > "$UNAVAILABLE_CACHE"

# "Some Uncurated Film" is already identified (manual) but its imdb_id has
# no entry anywhere in films.yaml. Since any resolved film is now eligible
# for fetching regardless of curation, apply already tried and failed for
# it too - a fresh unavailable_cache entry, same shape as the curated case.
printf '%s\ttt5555555\tSome Uncurated Film\t2022\tmanual\t\t2026-01-01\n' \
    "$WORK/films/NotCurated/Some Uncurated Film.mp4" >> "$FID_CACHE"
printf '%s\tno_match_found\t%s\n' "$WORK/films/NotCurated/Some Uncurated Film.mp4" "$(date -I)" >> "$UNAVAILABLE_CACHE"

# "MoanaCollision/Moana.mp4" is deliberately NOT pre-identified - scan
# will run identify on it automatically, the hash stub returns nothing,
# and the filename-based fallback finds both curated Moana entries with
# no year to disambiguate by (see forced_subs_identify_one).

out=$("$FORCED_SUBS" report)

echo "== four sections are present =="
assert_contains "has the already-fine section" "$out" "Already fine"
assert_contains "has the added-by-script section" "$out" "Added by this script"
assert_contains "has the needs-a-decision section" "$out" "Needs forced subtitles - you decide what to do"

echo "== the previously-applied file appears under added-by-script =="
assert_contains "Phantom Menace listed as added" "$out" "Phantom Menace.mp4"

echo "== identified films apply couldn't fetch a subtitle for are listed with their reason =="
assert_contains "has the identified-but-unfetched subsection" "$out" "Identified, but no matching subtitle could be fetched automatically"
assert_contains "Some Curated Film listed with its unavailable-cache reason" "$out" "$(printf '%s' "$WORK/films/Curated/Some Curated Film.mp4 (no_match_found)")"

echo "== an identified film with no curated entry at all is listed the same way (curation no longer gates fetching) =="
assert_contains "Some Uncurated Film listed alongside curated ones" "$out" "$(printf '%s' "$WORK/films/NotCurated/Some Uncurated Film.mp4 (no_match_found)")"

echo "== a filename matching multiple curated titles/years is listed for disambiguation =="
assert_contains "has the ambiguous-year subsection" "$out" "needs disambiguation"
assert_contains "Moana collision file listed" "$out" "MoanaCollision/Moana.mp4"

echo "== files with no confident film match at all are only counted, not listed individually =="
assert_contains "has a no-confident-match count line" "$out" "file(s) have no confident film match at all"
if [[ "$out" == *"Unmatched Obscure Film"* ]]; then
    fail "Unmatched Obscure Film should be summarized by count, not listed by name (it's not a curated/identified film)"
else
    pass "Unmatched Obscure Film is not listed individually"
fi

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
