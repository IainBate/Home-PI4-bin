#!/bin/bash
# Focused regression test for Fix 3 (final-review fix wave, C3): remuxing
# in the new forced subtitle must not drop pre-existing subtitle streams.
# Starts from a film that already has one embedded (non-forced, full
# coverage) English subtitle track, runs it through a full apply (hash
# search match -> download -> remux_forced_subtitle), and confirms BOTH
# the original subtitle stream and the newly muxed-in forced one survive.
set -uo pipefail
cd "$(dirname "$0")"
source test_helpers.sh

REPO_ROOT="$(cd .. && pwd)"
FORCED_SUBS="$REPO_ROOT/forced_subs"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/lib" "$WORK/films/PreserveStreams"
cp "$REPO_ROOT/lib/forced_subs_common.sh" "$REPO_ROOT/lib/known_films.py" "$WORK/lib/"

cat > "$WORK/films.yaml" <<'EOF'
films:
  - title: "Preserve Streams Film"
    aliases: ""
    year: 2025
    imdb_id: "tt6666666"
    editions: "theatrical:0"
EOF

FILE="$WORK/films/PreserveStreams/Preserve Streams Film.mkv"

# Base clip, plus a pre-existing full-coverage English subtitle track with
# NO forced disposition (so cmd_scan still buckets this NEEDS_FORCED_KNOWN,
# not HAS_FORCED - it's a normal dialogue track, not a forced one).
ffmpeg -y -f lavfi -i testsrc=duration=3:size=320x180:rate=10 -f lavfi -i sine=duration=3 \
    -pix_fmt yuv420p "$WORK/base.mp4" -hide_banner -loglevel error
cat > "$WORK/existing.srt" <<'EOF'
1
00:00:00,000 --> 00:00:02,900
Pre-existing full-length dialogue subtitle.
EOF
ffmpeg -y -i "$WORK/base.mp4" -i "$WORK/existing.srt" -map 0:v -map 0:a -map 1:s \
    -c:v copy -c:a copy -c:s srt -metadata:s:s:0 language=eng \
    "$FILE" -hide_banner -loglevel error

# A distinctive, clearly-not-"now" mtime so the post-apply comparison
# below is unambiguous.
touch -d "2020-01-01 00:00:00" "$FILE"
before_mtime=$(source "$WORK/lib/forced_subs_common.sh"; file_stat_signature "$FILE" | cut -d: -f2)

# Confirm the starting fixture really has exactly one, non-forced, subtitle
# stream before apply runs (so a later count of 2 is meaningful).
before_forced=$(ffprobe -v error -select_streams s -show_entries stream_disposition=forced -of csv=p=0 "$FILE" | grep -c '^1$' || true)
before_count=$(ffprobe -v error -select_streams s -show_entries stream=index -of csv=p=0 "$FILE" | grep -c . || true)
assert_eq "fixture starts with exactly 1 subtitle stream" "1" "$before_count"
assert_eq "fixture's pre-existing subtitle is not forced" "0" "${before_forced:-0}"

cat > "$WORK/downloaded_forced.srt" <<'EOF'
1
00:00:00,000 --> 00:00:00,300
Forced line.
EOF

# Fake ost.py: the hash-search path matches and "downloads" a short forced
# subtitle - this drives apply through the full remux_forced_subtitle path.
cat > "$WORK/lib/ost.py" <<PYEOF
import sys
cmd = sys.argv[1]
if cmd == "hash":
    print("9999999999999999")
elif cmd == "find_forced_by_hash":
    print("123456\tPreserve.Streams.Forced\ten")
elif cmd == "download":
    with open(sys.argv[3], "wb") as f:
        f.write(open("$WORK/downloaded_forced.srt", "rb").read())
    print("19\tok")
elif cmd == "login":
    print("test-token")
PYEOF

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
export OST_API_KEY=test OST_USER_AGENT=test OST_USERNAME=test OST_PASSWORD=test

"$FORCED_SUBS" apply --max-downloads 5 >/dev/null

echo "== apply logged success (remux actually happened) =="
assert_contains "success logged for Preserve Streams Film" "$(cat "$APPLY_LOG")" "$(printf '%s\tsuccess' "$FILE")"

echo "== both the old and new subtitle streams are present after remux =="
after_count=$(ffprobe -v error -select_streams s -show_entries stream=index -of csv=p=0 "$FILE" | grep -c . || true)
assert_eq "2 subtitle streams present after remux (old + new)" "2" "$after_count"

echo "== the new subtitle landed at s:0 and carries the forced disposition =="
analyze=$("$REPO_ROOT/convert_video" --analyze-subs "$FILE")
assert_contains "FORCED=1 after apply" "$analyze" "FORCED=1"
forced_flags=$(ffprobe -v error -select_streams s -show_entries stream_disposition=forced -of csv=p=0 "$FILE")
assert_contains "exactly one stream carries the forced disposition" "$forced_flags" "1"
assert_contains "the other stream is not forced" "$forced_flags" "0"

test_summary_and_exit
