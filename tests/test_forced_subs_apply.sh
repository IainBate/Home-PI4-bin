#!/bin/bash
set -uo pipefail
cd "$(dirname "$0")"
source test_helpers.sh

REPO_ROOT="$(cd .. && pwd)"
FORCED_SUBS="$REPO_ROOT/forced_subs"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/lib" "$WORK/films/Star Wars" "$WORK/films/Sidecar" \
    "$WORK/films/FreshCache" "$WORK/films/StaleCache"
cp "$REPO_ROOT/lib/forced_subs_common.sh" "$REPO_ROOT/lib/known_films.py" "$WORK/lib/"

cat > "$WORK/films.yaml" <<'EOF'
films:
  - title: "Star Wars: Episode I - The Phantom Menace"
    aliases: "Phantom Menace"
    year: 1999
    imdb_id: "tt0120915"
    editions: "theatrical:0"
  - title: "No Subtitle Available Film"
    aliases: ""
    year: 2020
    imdb_id: "tt1111111"
    editions: "theatrical:0"
  - title: "Some Curated Film"
    aliases: ""
    year: 2021
    imdb_id: "tt2222222"
    editions: "theatrical:0"
  - title: "Fresh Cache Film"
    aliases: ""
    year: 2022
    imdb_id: "tt3333333"
    editions: "theatrical:0"
  - title: "Stale Cache Film"
    aliases: ""
    year: 2023
    imdb_id: "tt4444444"
    editions: "theatrical:0"
EOF

ffmpeg -y -f lavfi -i testsrc=duration=3:size=320x180:rate=10 -f lavfi -i sine=duration=3 \
    -pix_fmt yuv420p "$WORK/films/Star Wars/Phantom Menace.mkv" -hide_banner -loglevel error
cp "$WORK/films/Star Wars/Phantom Menace.mkv" "$WORK/films/Star Wars/No Subtitle Available Film.mkv"
cp "$WORK/films/Star Wars/Phantom Menace.mkv" "$WORK/films/Sidecar/Some Curated Film.mkv"
cp "$WORK/films/Star Wars/Phantom Menace.mkv" "$WORK/films/FreshCache/Fresh Cache Film.mkv"
cp "$WORK/films/Star Wars/Phantom Menace.mkv" "$WORK/films/StaleCache/Stale Cache Film.mkv"

SIDECAR_FILE="$WORK/films/Sidecar/Some Curated Film.mkv"
FRESH_FILE="$WORK/films/FreshCache/Fresh Cache Film.mkv"
STALE_FILE="$WORK/films/StaleCache/Stale Cache Film.mkv"

# A sidecar .srt sitting right next to the video, matching its basename -
# find_sidecar_srt (and convert_video's external-subtitle detection) should
# pick this up. Cue is deliberately short (0.3s of a 3s video, ~10%
# coverage) so it clears the Fix-2 <15% forced-vs-full trustworthiness
# check; test_forced_subs_apply_sidecar_coverage.sh covers the opposite
# (full-coverage, untrustworthy) case.
cat > "$WORK/films/Sidecar/Some Curated Film.srt" <<'EOF'
1
00:00:00,000 --> 00:00:00,300
Sidecar line
EOF

cat > "$WORK/dummy.srt" <<'EOF'
1
00:00:00,000 --> 00:00:02,000
Bocce
EOF

# Fake ost.py:
#  - "hash" returns a distinct fake moviehash per fixture so the marker log
#    below can prove exactly which files triggered a search.
#  - "find_forced_by_hash" / "find_forced_by_imdb" append every invocation to
#    $WORK/search_marker_log before deciding whether to return a match. Tests
#    use the ABSENCE or PRESENCE of a fixture's token in that log to prove
#    whether apply's search path ran for it at all (used both for the
#    sidecar shortcut, which must never search, and for the unavailable-cache
#    skip/retry behavior).
#  - Only Phantom Menace has a real match; everything else searches and
#    comes back empty.
cat > "$WORK/lib/ost.py" <<PYEOF
import sys
cmd = sys.argv[1]
MARKER = "$WORK/search_marker_log"
if cmd == "hash":
    name = sys.argv[2]
    if "Phantom" in name:
        print("aaaaaaaaaaaaaaaa")
    elif "Curated" in name:
        print("cccccccccccccccc")
    elif "Fresh Cache" in name:
        print("dddddddddddddddd")
    elif "Stale Cache" in name:
        print("eeeeeeeeeeeeeeee")
    else:
        print("bbbbbbbbbbbbbbbb")
elif cmd == "find_forced_by_hash":
    with open(MARKER, "a") as m:
        m.write("hash:" + sys.argv[2] + "\n")
    if sys.argv[2] == "aaaaaaaaaaaaaaaa":
        print("4461104\tPhantom.Menace.Forced\ten")
elif cmd == "find_forced_by_imdb":
    with open(MARKER, "a") as m:
        m.write("imdb:" + sys.argv[2] + "\n")
elif cmd == "download":
    with open(sys.argv[3], "wb") as f:
        f.write(open("$WORK/dummy.srt", "rb").read())
    print("19\tok")
elif cmd == "login":
    print("test-token-abc123")
PYEOF

# Fixture secrets.yaml so opensubtitles_login's now-required non-empty
# credential check (Fix 1) has something real to read, isolated from the
# repo's own (test-machine, likely absent) secrets.yaml.
cat > "$WORK/secrets.yaml" <<'EOF'
opensubtitles:
  api_key: "test-key"
  username: "test-user"
  password: "test-pass"
EOF

export FORCED_SUBS_LIBDIR="$WORK/lib"
export FORCED_SUBS_KNOWN_FILMS="$WORK/films.yaml"
export FORCED_SUBS_SECRETS_YAML="$WORK/secrets.yaml"
export FORCED_SUBS_LOCKFILE="$WORK/forced_subs.lock"
export FID_CACHE="$WORK/fid_cache"
export SCAN_CACHE="$WORK/scan_cache"
export FORCED_SUBS_FILMS_ROOT="$WORK/films"
export SCAN_LOG="$WORK/scan_log"
export APPLY_LOG="$WORK/apply_log"
export UNAVAILABLE_CACHE="$WORK/unavailable_cache"
export OST_API_KEY=test OST_USER_AGENT=test OST_USERNAME=test OST_PASSWORD=test OST_TOKEN=test

# Pre-populate the file-id cache with a "manual" identification for the
# sidecar/fresh/stale fixtures so scan resolves them onto the curated list
# deterministically, without depending on filename-fallback matching (that
# path is already covered by test_forced_subs_scan.sh).
printf '%s\ttt2222222\tSome Curated Film\t2021\tmanual\t\t2026-01-01\n' "$SIDECAR_FILE" >> "$FID_CACHE"
printf '%s\ttt3333333\tFresh Cache Film\t2022\tmanual\t\t2026-01-01\n' "$FRESH_FILE" >> "$FID_CACHE"
printf '%s\ttt4444444\tStale Cache Film\t2023\tmanual\t\t2026-01-01\n' "$STALE_FILE" >> "$FID_CACHE"

# Pre-populate the unavailable cache: a FRESH (today) entry for Fresh Cache
# Film, which apply must skip without searching; a STALE (year-2000) entry
# for Stale Cache Film, which apply must retry.
mkdir -p "$(dirname "$UNAVAILABLE_CACHE")"
printf '%s\tno_match_found\t%s\n' "$FRESH_FILE" "$(date -I)" > "$UNAVAILABLE_CACHE"
printf '%s\tno_match_found\t2000-01-01\n' "$STALE_FILE" >> "$UNAVAILABLE_CACHE"

"$FORCED_SUBS" apply --max-downloads 5 >/dev/null

marker_log() { cat "$WORK/search_marker_log" 2>/dev/null || true; }

echo "== the matched file got a forced subtitle track muxed in =="
analyze=$("$REPO_ROOT/convert_video" --analyze-subs "$WORK/films/Star Wars/Phantom Menace.mkv")
assert_contains "FORCED=1 after apply" "$analyze" "FORCED=1"

echo "== the unmatched file was left untouched and logged unavailable =="
analyze2=$("$REPO_ROOT/convert_video" --analyze-subs "$WORK/films/Star Wars/No Subtitle Available Film.mkv")
assert_contains "still FORCED=0 (untouched)" "$analyze2" "FORCED=0"
assert_contains "logged as unavailable" "$(cat "$APPLY_LOG")" "unavailable"
assert_file_exists "unavailable cache written" "$UNAVAILABLE_CACHE"

echo "== apply log records the success =="
assert_contains "success logged for Phantom Menace" "$(cat "$APPLY_LOG")" "success"

echo "== sidecar .srt shortcut: apply muxes it directly, without ever searching ost.py =="
analyze3=$("$REPO_ROOT/convert_video" --analyze-subs "$SIDECAR_FILE")
assert_contains "sidecar fixture FORCED=1 after apply" "$analyze3" "FORCED=1"
assert_contains "sidecar fixture logged success" "$(cat "$APPLY_LOG")" "$(printf '%s\tsuccess' "$SIDECAR_FILE")"
if [[ "$(marker_log)" == *"cccccccccccccccc"* ]]; then
    fail "sidecar shortcut never calls find_forced_by_hash/find_forced_by_imdb (marker log unexpectedly contains its hash)"
else
    pass "sidecar shortcut never calls find_forced_by_hash/find_forced_by_imdb"
fi

echo "== unavailable_cache_is_fresh: a fresh entry is skipped without re-searching =="
if [[ "$(marker_log)" == *"dddddddddddddddd"* ]]; then
    fail "fresh-cache file was searched (marker log unexpectedly contains its hash)"
else
    pass "fresh-cache file was skipped without searching"
fi
if grep -qF "$(printf '%s' "$FRESH_FILE")" "$APPLY_LOG"; then
    fail "fresh-cache file should have no new apply-log entry at all (it was skipped before any attempt)"
else
    pass "fresh-cache file has no apply-log entry (skipped before any attempt)"
fi

echo "== unavailable_cache_is_fresh: a stale (>=7 day) entry is retried =="
if [[ "$(marker_log)" == *"eeeeeeeeeeeeeeee"* ]]; then
    pass "stale-cache file was retried (search re-invoked)"
else
    fail "stale-cache file should have been retried (marker log missing its hash)"
fi
assert_contains "stale-cache file re-logged as unavailable after retry" "$(cat "$APPLY_LOG")" "$(printf '%s\tunavailable' "$STALE_FILE")"

test_summary_and_exit
