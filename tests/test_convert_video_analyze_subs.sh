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
mkdir -p "$WORK/no_subs" "$WORK/high_coverage" "$WORK/low_coverage" "$WORK/external_srt" "$WORK/mp4_forced" "$WORK/realistic_coverage"

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

# ~1% of the 10s runtime - realistic for genuine forced-subtitle content
# (a handful of foreign-language lines in an otherwise-English film is
# typically well under 10% of the runtime, not the 15-50% this suite's
# other fixtures use). This is the specific value that exposed a real bc
# bug: `(a / b) * 100` at `scale=1` truncates the tiny intermediate
# division result to "0.0" *before* the multiplication ever happens, so
# any genuine coverage under ~10% silently computed as exactly 0.
cat > "$WORK/realistic.srt" <<'EOF'
1
00:00:00,000 --> 00:00:00,100
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

# forced English subtitle covering ~1% of the 10s runtime
ffmpeg -y -i "$WORK/base.mp4" -i "$WORK/realistic.srt" -map 0:v -map 0:a -map 1:s -c:v copy -c:a copy -c:s srt \
    -metadata:s:s:0 language=eng -disposition:s:0 forced "$WORK/realistic_coverage/realistic_coverage.mkv" -hide_banner -loglevel error

# forced English subtitle in an mp4/mov_text container (not mkv/srt like the
# other fixtures above): ffmpeg's dump shows a bracketed track-id here
# ("Stream #0:2[0x3](eng):") that mkv never has - this fixture exists
# specifically to catch check_english_forced_sub failing to recognize a
# genuinely forced mp4 track, which it silently did before that regex
# learned to tolerate the bracket (confirmed present on both ffmpeg 7.1.5
# and 9.0.1, so not a version-specific fluke).
ffmpeg -y -i "$WORK/base.mp4" -i "$WORK/high.srt" -map 0:v -map 0:a -map 1:s -c:v copy -c:a copy -c:s mov_text \
    -metadata:s:s:0 language=eng -disposition:s:0 forced "$WORK/mp4_forced/mp4_forced.mp4" -hide_banner -loglevel error

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

echo "== realistic (~1%) coverage is computed correctly, not zeroed by bc precision loss =="
out=$(run_analyze "$WORK/realistic_coverage/realistic_coverage.mkv")
assert_contains "realistic_coverage: reports FORCED=1" "$out" "FORCED=1"
coverage=$(echo "$out" | grep -oE 'COVERAGE=[0-9.]+' | cut -d= -f2)
# The old (a/b)*100 formula truncated this exact scenario to exactly "0" -
# checking the actual number (not just "< 15" or "> 0", either of which
# the old broken formula would also have satisfied by accident) is what
# actually catches this regression.
result=$(awk -v c="${coverage:-0}" 'BEGIN { print (c >= 0.5 && c <= 2) ? "yes" : "no" }')
assert_eq "realistic_coverage: coverage is ~1% (0.5-2%), not truncated to 0" "yes" "$result"

echo "== external srt sidecar, no embedded subs =="
out=$(run_analyze "$WORK/external_srt/external_srt.mkv")
assert_contains "external_srt: reports FORCED=0" "$out" "FORCED=0"
assert_contains "external_srt: reports EXTERNAL_SRT=1" "$out" "EXTERNAL_SRT=1"

echo "== forced English subtitle in an mp4/mov_text container =="
out=$(run_analyze "$WORK/mp4_forced/mp4_forced.mp4")
assert_contains "mp4_forced: reports FORCED=1 (not masked by the [0x..] track-id bracket)" "$out" "FORCED=1"
coverage=$(echo "$out" | grep -oE 'COVERAGE=[0-9.]+' | cut -d= -f2)
assert_eq "mp4_forced: reports a non-empty coverage value" "no" "$([[ -z "$coverage" ]] && echo yes || echo no)"

echo "== analyze mode never encodes anything =="
run_analyze "$WORK/no_subs/no_subs.mkv" >/dev/null
shopt -s nullglob
leftovers=("$WORK"/*/tmp_*.mp4)
shopt -u nullglob
assert_eq "no leftover tmp_*.mp4 after analyze" "0" "${#leftovers[@]}"

echo "== analyze mode exits 0 =="
run_analyze "$WORK/no_subs/no_subs.mkv" >/dev/null
assert_eq "exit code 0" "0" "$?"

echo "== ffmpeg's stdin is protected from being read as interactive commands =="
# Regression test for a real production incident: without </dev/null on an
# ffmpeg call, ffmpeg treats an inherited stdin pipe as an interactive
# control channel and reads from it, printing "Enter command: ..." /
# "Parse error, ..." for each line it can't parse. This actually happened
# when forced_subs's cmd_scan/cmd_apply ran ffmpeg nested inside a
# `while read ... done < <(...)` process substitution - the long-running
# remux call had a real window to poll stdin mid-operation and stole data
# meant for the read loop, corrupting both. That race can't be reproduced
# reliably in a fast unit test (a quick synthetic fixture remuxes almost
# instantly, however it's invoked), so this checks statically that every
# ffmpeg invocation in this codebase - the actual, permanent guarantee -
# redirects stdin away from whatever it would otherwise inherit.
unprotected=""
while IFS=: read -r ffmpeg_file ffmpeg_line _; do
    [[ "$ffmpeg_file" == "" ]] && continue
    # A real ffmpeg invocation can span several backslash-continuation
    # lines, with the protecting redirect on a later line than the match
    # itself (e.g. forced_subs's remux call) - check a window after the
    # match, not just the matched line.
    window=$(sed -n "${ffmpeg_line},$((ffmpeg_line + 6))p" "$ffmpeg_file")
    if [[ "$window" != *"/dev/null"* && "$window" != *"-nostdin"* ]]; then
        unprotected="${unprotected}${ffmpeg_file}:${ffmpeg_line} "
    fi
done < <(grep -rn 'ffmpeg -i\|ffmpeg -y' "$REPO_ROOT/convert_video" "$REPO_ROOT/forced_subs" | grep -v ':\s*#')
assert_eq "every ffmpeg invocation in convert_video/forced_subs protects its stdin" "" "$unprotected"

echo "== --no-subs skips subtitle analysis entirely, even when subtitles are present =="

NSDIR="$(mktemp -d)"
ffmpeg -y -f lavfi -i testsrc=duration=3:size=160x90:rate=5 -f lavfi -i sine=duration=3 \
    -pix_fmt yuv420p "$NSDIR/base.mp4" -hide_banner -loglevel error
cat > "$NSDIR/subs.srt" <<'EOF'
1
00:00:00,000 --> 00:00:02,000
Hola
EOF
ffmpeg -y -i "$NSDIR/base.mp4" -i "$NSDIR/subs.srt" -map 0:v -map 0:a -map 1:s -c:v libx264 -c:a aac -c:s srt \
    -metadata:s:s:0 language=eng -disposition:s:0 forced "$NSDIR/Movie With Subs.mkv" -hide_banner -loglevel error

# Genre is a unique, obviously-throwaway name: on a machine where
# /mnt/HDD/films actually exists (i.e. the real Pi target, unlike this
# possibly-macOS dev box), convert_video's final mv *succeeds* into
# /mnt/HDD/films/<genre>/, unlike on a box without that mount where it's
# left behind as tmp_*.mp4 in cwd instead. The test must work - and clean
# up after itself - in both cases without ever assuming which one it's on.
NS_GENRE="convert_video_test_no_subs_$(basename "$NSDIR")"
REAL_DEST="/mnt/HDD/films/$NS_GENRE/Movie With Subs.mp4"

out=$(cd "$NSDIR" && "$CONVERT_VIDEO" -n --no-subs "Movie With Subs.mkv" "$NS_GENRE" </dev/null 2>&1)

assert_eq "no-subs: never runs the subtitle analysis probe" "no" "$([[ "$out" == *"Analyzing subtitles"* ]] && echo yes || echo no)"

tmp_output=$(find "$NSDIR" -maxdepth 1 -name "tmp_*.mp4" | head -1)
if [[ -z "$tmp_output" && -f "$REAL_DEST" ]]; then
    tmp_output="$REAL_DEST"
fi
assert_eq "no-subs: still produces an encoded output despite skipping analysis" "no" "$([[ -z "$tmp_output" ]] && echo yes || echo no)"
sub_stream_count=$(ffprobe -v error -select_streams s -show_entries stream=index -of csv=p=0 "$tmp_output" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "no-subs: output has no subtitle stream (source had one, but -no-subs forces -sn)" "0" "$sub_stream_count"

# Clean up wherever the output actually landed, including the real media
# library path when this ran somewhere /mnt/HDD/films genuinely exists.
rm -f "$REAL_DEST"
rmdir "/mnt/HDD/films/$NS_GENRE" 2>/dev/null
rm -rf "$NSDIR"

test_summary_and_exit
