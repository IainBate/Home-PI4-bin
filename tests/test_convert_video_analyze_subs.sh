#!/bin/bash
# Tests for `convert_video --analyze-subs <file>`: a non-encoding mode that
# runs only the existing subtitle-analysis logic and prints its result, so
# other tools (convert_season) can classify a file's subtitle situation
# without paying for a full transcode.
set -uo pipefail
cd "$(dirname "$0")"
source test_helpers.sh

REPO_ROOT="$(cd .. && pwd)"
CONVERT_VIDEO="$REPO_ROOT/convert_video"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- Build fixtures -------------------------------------------------------
# Each fixture lives in its own subdirectory: analyze_subtitles scans the
# whole containing directory for sibling .srt files (it doesn't filter by
# basename), so fixtures sharing a directory would contaminate each other.
mkdir -p "$WORK/no_subs" "$WORK/high_coverage" "$WORK/low_coverage" "$WORK/external_srt"

ffmpeg -y -f lavfi -i testsrc=duration=10:size=320x180:rate=10 -f lavfi -i sine=duration=10 \
    -pix_fmt yuv420p "$WORK/base.mp4" -hide_banner -loglevel error

cat > "$WORK/high.srt" <<'EOF'
1
00:00:00,000 --> 00:00:05,000
Hola
EOF

cat > "$WORK/low.srt" <<'EOF'
1
00:00:00,000 --> 00:00:00,500
Hola
EOF

# no embedded subtitle at all, no sibling .srt
ffmpeg -y -i "$WORK/base.mp4" -map 0:v -map 0:a -c copy "$WORK/no_subs/no_subs.mkv" -hide_banner -loglevel error

# forced English subtitle covering ~50% of the 10s runtime
ffmpeg -y -i "$WORK/base.mp4" -i "$WORK/high.srt" -map 0:v -map 0:a -map 1:s -c:v copy -c:a copy -c:s srt \
    -metadata:s:s:0 language=eng -disposition:s:0 forced "$WORK/high_coverage/high_coverage.mkv" -hide_banner -loglevel error

# forced English subtitle covering ~5% of the 10s runtime
ffmpeg -y -i "$WORK/base.mp4" -i "$WORK/low.srt" -map 0:v -map 0:a -map 1:s -c:v copy -c:a copy -c:s srt \
    -metadata:s:s:0 language=eng -disposition:s:0 forced "$WORK/low_coverage/low_coverage.mkv" -hide_banner -loglevel error

# no embedded subtitle, but a sidecar .srt file next to it
ffmpeg -y -i "$WORK/base.mp4" -map 0:v -map 0:a -c copy "$WORK/external_srt/external_srt.mkv" -hide_banner -loglevel error
cp "$WORK/high.srt" "$WORK/external_srt/external_srt.srt"

run_analyze() {
    "$CONVERT_VIDEO" --analyze-subs "$1"
}

# --- Tests ---------------------------------------------------------------
echo "== no subtitles at all =="
out=$(run_analyze "$WORK/no_subs/no_subs.mkv")
assert_contains "no_subs: reports FORCED=0" "$out" "FORCED=0"
assert_contains "no_subs: reports EXTERNAL_SRT=0" "$out" "EXTERNAL_SRT=0"

echo "== high coverage forced subtitle =="
out=$(run_analyze "$WORK/high_coverage/high_coverage.mkv")
assert_contains "high_coverage: reports FORCED=1" "$out" "FORCED=1"
coverage=$(echo "$out" | grep -oE 'COVERAGE=[0-9.]+' | cut -d= -f2)
assert_eq "high_coverage: reports a non-empty coverage value" "no" "$([[ -z "$coverage" ]] && echo yes || echo no)"
result=$(awk -v c="${coverage:-0}" 'BEGIN { print (c >= 15) ? "yes" : "no" }')
assert_eq "high_coverage: coverage >= 15%" "yes" "$result"

echo "== low coverage forced subtitle =="
out=$(run_analyze "$WORK/low_coverage/low_coverage.mkv")
assert_contains "low_coverage: reports FORCED=1" "$out" "FORCED=1"
coverage=$(echo "$out" | grep -oE 'COVERAGE=[0-9.]+' | cut -d= -f2)
assert_eq "low_coverage: reports a non-empty coverage value" "no" "$([[ -z "$coverage" ]] && echo yes || echo no)"
result=$(awk -v c="${coverage:-999}" 'BEGIN { print (c < 15) ? "yes" : "no" }')
assert_eq "low_coverage: coverage < 15%" "yes" "$result"

echo "== external srt sidecar, no embedded subs =="
out=$(run_analyze "$WORK/external_srt/external_srt.mkv")
assert_contains "external_srt: reports FORCED=0" "$out" "FORCED=0"
assert_contains "external_srt: reports EXTERNAL_SRT=1" "$out" "EXTERNAL_SRT=1"

echo "== analyze mode never encodes anything =="
run_analyze "$WORK/no_subs/no_subs.mkv" >/dev/null
shopt -s nullglob
leftovers=("$WORK"/*/tmp_*.mp4)
shopt -u nullglob
assert_eq "no leftover tmp_*.mp4 after analyze" "0" "${#leftovers[@]}"

echo "== analyze mode exits 0 =="
run_analyze "$WORK/no_subs/no_subs.mkv" >/dev/null
assert_eq "exit code 0" "0" "$?"

test_summary_and_exit
