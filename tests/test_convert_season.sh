#!/bin/bash
# Tests for convert_season. Sources the script (rather than executing it)
# so individual functions can be tested directly; convert_season guards its
# main() behind a "run only when executed, not sourced" check for this.
set -o pipefail
cd "$(dirname "$0")"
source test_helpers.sh

REPO_ROOT="$(cd .. && pwd)"
source "$REPO_ROOT/convert_season"

# --- extract_episode_tag --------------------------------------------------
echo "== extract_episode_tag =="

result="$(extract_episode_tag "Show.Name.S01E01.Something.mkv")"
assert_eq "long name with S01E01 in the middle" "S01E01" "$result"

result="$(extract_episode_tag "show s2e3 stuff.mp4")"
assert_eq "lowercase, single-digit season/episode gets zero-padded" "S02E03" "$result"

result="$(extract_episode_tag "no_pattern_here.mkv")"
assert_eq "no SxxEyy pattern returns empty" "" "$result"

result="$(extract_episode_tag "Multi.S10E12.Title.avi")"
assert_eq "already two-digit season/episode" "S10E12" "$result"

result="$(extract_episode_tag "S1E1.mkv")"
assert_eq "bare S1E1 filename" "S01E01" "$result"

# --- find_video_files -----------------------------------------------------
echo "== find_video_files =="

TREE="$(mktemp -d)"
trap 'rm -rf "$TREE"' EXIT
mkdir -p "$TREE/ShowA/Season1" "$TREE/deep/nested/dir"
touch "$TREE/ShowA/Season1/A.S01E01.mkv"
touch "$TREE/ShowA/Season1/A.S01E02.MP4"
touch "$TREE/ShowA/other.txt"
touch "$TREE/ShowA/notes.srt"
touch "$TREE/random.avi"
touch "$TREE/deep/nested/dir/clip.m4v"
touch "$TREE/deep/nested/dir/"$'weird\nname.mkv'   # embedded newline in the filename

found=()
while IFS= read -r -d '' entry; do
    found+=("$entry")
done < <(find_video_files "$TREE" | sort -z)

expected=(
    "$TREE/ShowA/Season1/A.S01E01.mkv"
    "$TREE/ShowA/Season1/A.S01E02.MP4"
    "$TREE/deep/nested/dir/clip.m4v"
    "$TREE/deep/nested/dir/"$'weird\nname.mkv'
    "$TREE/random.avi"
)
expected_sorted=()
while IFS= read -r -d '' entry; do
    expected_sorted+=("$entry")
done < <(printf '%s\0' "${expected[@]}" | sort -z)

assert_eq "finds exactly the video files, including one with a newline in its name (count)" "${#expected_sorted[@]}" "${#found[@]}"
assert_eq "found list matches expected list" "${expected_sorted[*]}" "${found[*]}"

# --- rename_to_tag ---------------------------------------------------------
echo "== rename_to_tag =="

RTDIR="$(mktemp -d)"
touch "$RTDIR/Show.Name.S01E01.Something.MKV"
result="$(rename_to_tag "$RTDIR/Show.Name.S01E01.Something.MKV" "S01E01")"
assert_eq "rename_to_tag exit code" "0" "$?"
assert_eq "returns new path" "$RTDIR/S01E01.mkv" "$result"
assert_file_exists "renamed file exists with lowercased ext" "$RTDIR/S01E01.mkv"
assert_file_missing "original long filename is gone" "$RTDIR/Show.Name.S01E01.Something.MKV"

# Idempotent: already-correctly-named file
touch "$RTDIR/S01E02.mp4"
result="$(rename_to_tag "$RTDIR/S01E02.mp4" "S01E02")"
assert_eq "idempotent rename exit code" "0" "$?"
assert_eq "idempotent rename returns same path" "$RTDIR/S01E02.mp4" "$result"
assert_file_exists "file still exists after no-op rename" "$RTDIR/S01E02.mp4"

# Collision: two different files in the same directory both map to S01E03
touch "$RTDIR/Show.S01E03.PartA.mkv"
touch "$RTDIR/Show.S01E03.PartB.mkv"
rename_to_tag "$RTDIR/Show.S01E03.PartA.mkv" "S01E03" >/dev/null
result="$(rename_to_tag "$RTDIR/Show.S01E03.PartB.mkv" "S01E03" 2>/dev/null)"
rc=$?
assert_eq "collision: rename_to_tag returns non-zero" "1" "$rc"
assert_eq "collision: prints nothing to stdout" "" "$result"
assert_file_exists "collision: first file untouched at its new name" "$RTDIR/S01E03.mkv"
assert_file_exists "collision: second file left at its original name" "$RTDIR/Show.S01E03.PartB.mkv"

rm -rf "$RTDIR"

# --- find_video_files_with_tags / duplicate_tags_from_list -----------------
echo "== find_video_files_with_tags =="

FVWT="$(mktemp -d)"
mkdir -p "$FVWT/dirA" "$FVWT/dirB"
touch "$FVWT/dirA/Show.S01E01.mkv" "$FVWT/dirB/Show.S01E01.Alt.mkv" "$FVWT/dirA/no_pattern.mkv"

lines=()
while IFS= read -r line; do
    lines+=("$line")
done < <(find_video_files_with_tags "$FVWT" | sort)

assert_eq "one TAG\\tpath line per file (count)" "3" "${#lines[@]}"
assert_contains "tagged line for dirA episode" "${lines[*]}" "S01E01	$FVWT/dirA/Show.S01E01.mkv"
assert_contains "tagged line for dirB episode" "${lines[*]}" "S01E01	$FVWT/dirB/Show.S01E01.Alt.mkv"
assert_contains "untagged file has empty tag field" "${lines[*]}" "	$FVWT/dirA/no_pattern.mkv"

echo "== duplicate_tags_from_list =="

dupes="$(printf 'S01E01\t/a/1.mkv\nS01E01\t/b/2.mkv\nS01E02\t/a/3.mkv\n\t/a/4.mkv\n' | duplicate_tags_from_list)"
assert_eq "detects the one tag used by two files" "S01E01" "$dupes"

no_dupes="$(printf 'S01E01\t/a/1.mkv\nS01E02\t/a/2.mkv\n' | duplicate_tags_from_list)"
assert_eq "no duplicates when every tag is unique" "" "$no_dupes"

rm -rf "$FVWT"

# --- profile_bucket ---------------------------------------------------------
echo "== profile_bucket =="

assert_eq "no subs at all -> NONE" "NONE" "$(profile_bucket 'COVERAGE=0 FORCED=0 EXTERNAL_SRT=0')"
assert_eq "external srt only -> EXTERNAL_SRT" "EXTERNAL_SRT" "$(profile_bucket 'COVERAGE=0 FORCED=0 EXTERNAL_SRT=1')"
assert_eq "forced, coverage >= 15 -> HIGH" "HIGH" "$(profile_bucket 'COVERAGE=42.0 FORCED=1 EXTERNAL_SRT=0')"
assert_eq "forced, coverage exactly 15 -> HIGH" "HIGH" "$(profile_bucket 'COVERAGE=15.0 FORCED=1 EXTERNAL_SRT=0')"
assert_eq "forced, coverage < 15 -> LOW" "LOW" "$(profile_bucket 'COVERAGE=4.9 FORCED=1 EXTERNAL_SRT=0')"

# --- classify_profile (wires up to the real convert_video --analyze-subs) --
echo "== classify_profile =="

CPDIR="$(mktemp -d)"
mkdir -p "$CPDIR/none" "$CPDIR/high" "$CPDIR/low" "$CPDIR/ext"

ffmpeg -y -f lavfi -i testsrc=duration=10:size=160x90:rate=5 -f lavfi -i sine=duration=10 \
    -pix_fmt yuv420p -map 0:v -map 1:a -c:v libx264 -c:a aac "$CPDIR/base.mkv" -hide_banner -loglevel error

cat > "$CPDIR/high.srt" <<'EOF'
1
00:00:00,000 --> 00:00:05,000
Hola
EOF
cat > "$CPDIR/low.srt" <<'EOF'
1
00:00:00,000 --> 00:00:00,500
Hola
EOF

ffmpeg -y -i "$CPDIR/base.mkv" -map 0:v -map 0:a -c copy "$CPDIR/none/none.mkv" -hide_banner -loglevel error

ffmpeg -y -i "$CPDIR/base.mkv" -i "$CPDIR/high.srt" -map 0:v -map 0:a -map 1:s -c:v copy -c:a copy -c:s srt \
    -metadata:s:s:0 language=eng -disposition:s:0 forced "$CPDIR/high/high.mkv" -hide_banner -loglevel error

ffmpeg -y -i "$CPDIR/base.mkv" -i "$CPDIR/low.srt" -map 0:v -map 0:a -map 1:s -c:v copy -c:a copy -c:s srt \
    -metadata:s:s:0 language=eng -disposition:s:0 forced "$CPDIR/low/low.mkv" -hide_banner -loglevel error

ffmpeg -y -i "$CPDIR/base.mkv" -map 0:v -map 0:a -c copy "$CPDIR/ext/ext.mkv" -hide_banner -loglevel error
cp "$CPDIR/high.srt" "$CPDIR/ext/ext.srt"

assert_eq "classify_profile on a plain file with no subs" "NONE" "$(classify_profile "$CPDIR/none/none.mkv")"
assert_eq "classify_profile on a high-coverage forced-subtitle file" "HIGH" "$(classify_profile "$CPDIR/high/high.mkv")"
assert_eq "classify_profile on a low-coverage forced-subtitle file" "LOW" "$(classify_profile "$CPDIR/low/low.mkv")"
assert_eq "classify_profile on a file with only an external srt sidecar" "EXTERNAL_SRT" "$(classify_profile "$CPDIR/ext/ext.mkv")"

rm -rf "$CPDIR"

# --- organize_into_seasons --------------------------------------------------
echo "== organize_into_seasons =="

ODIR="$(mktemp -d)"
mkdir -p "$ODIR/Season 1"
touch "$ODIR/Season 1/S01E00.mp4"   # pre-existing, from an earlier run
touch "$ODIR/S01E01.mp4" "$ODIR/S01E02.mp4" "$ODIR/S02E01.mp4"
touch "$ODIR/not_an_episode.txt"    # unrelated file, must be left alone

organize_into_seasons "$ODIR"

assert_file_exists "pre-existing Season 1 folder still has its old file" "$ODIR/Season 1/S01E00.mp4"
assert_file_exists "S01E01 moved into Season 1" "$ODIR/Season 1/S01E01.mp4"
assert_file_exists "S01E02 moved into Season 1" "$ODIR/Season 1/S01E02.mp4"
assert_file_exists "Season 2 created and S02E01 moved into it" "$ODIR/Season 2/S02E01.mp4"
assert_file_missing "no loose S01E01 left at top level" "$ODIR/S01E01.mp4"
assert_file_missing "no loose S02E01 left at top level" "$ODIR/S02E01.mp4"
assert_file_exists "unrelated file untouched" "$ODIR/not_an_episode.txt"

rm -rf "$ODIR"

# --- main (orchestration) ---------------------------------------------------
# These tests point CONVERT_VIDEO at a stub instead of the real script: the
# real convert_video wiring (analyze-subs correctness, actual subtitle
# detection) is already covered above against real ffmpeg fixtures. What's
# under test here is convert_season's own orchestration - duplicate/no-match
# skipping, renaming, majority-bucket grouping, anomaly exclusion, the
# piped-decision plumbing, and final season organization.

make_stub_convert_video() {
    # $1 = log file, $2 = profile map file ("path\tANALYZE_OUTPUT" lines),
    # $3 = fail list file (renamed paths that should fail "conversion"),
    # $4 = dest base dir (mirrors /mnt/HDD/films for the stub)
    local stub="$1/stub_convert_video"
    cat > "$stub" <<STUB
#!/bin/bash
if [[ "\$1" == "--analyze-subs" ]]; then
    grep -F "\$2	" "$2" | cut -f2-
    exit 0
fi
no_subs="no"
if [[ "\$1" == "--no-subs" ]]; then
    no_subs="yes"
    shift
fi
file="\$1"; genre="\$2"
answer=""
if [ ! -t 0 ]; then read -r answer; fi
echo "CONVERT file=\$file genre=\$genre no_subs=\$no_subs stdin=\$answer" >> "$1/log"
if grep -qxF "\$file" "$3" 2>/dev/null; then
    exit 1
fi
dest_path="\$genre"
if [[ "\$genre" == "Modern" || "\$genre" == "Retro" ]]; then
    dest_path="Family/\$genre"
fi
mkdir -p "$4/\$dest_path"
cp "\$file" "$4/\$dest_path/\$(basename "\${file%.*}").mp4"
exit 0
STUB
    chmod +x "$stub"
    printf '%s\n' "$stub"
}

echo "== main: duplicates, no-match, majority bucket, anomaly, failure, organize =="

MTREE="$(mktemp -d)"
mkdir -p "$MTREE/dupA" "$MTREE/dupB" "$MTREE/nomatch" "$MTREE/ok1" "$MTREE/failme" "$MTREE/anom"
touch "$MTREE/dupA/Show.S01E05.PartA.mkv"
touch "$MTREE/dupB/Show.S01E05.PartB.mkv"
touch "$MTREE/nomatch/random_video.mkv"
touch "$MTREE/ok1/Show.S02E01.mkv"
touch "$MTREE/failme/Show.S02E02.mkv"
touch "$MTREE/anom/Show.S02E03.mkv"

STUB_DIR="$(mktemp -d)"
DEST_DIR="$(mktemp -d)"
: > "$STUB_DIR/log"
printf '%s\tCOVERAGE=0 FORCED=0 EXTERNAL_SRT=0\n' "$MTREE/ok1/S02E01.mkv" > "$STUB_DIR/profiles"
printf '%s\tCOVERAGE=0 FORCED=0 EXTERNAL_SRT=0\n' "$MTREE/failme/S02E02.mkv" >> "$STUB_DIR/profiles"
printf '%s\tCOVERAGE=42.0 FORCED=1 EXTERNAL_SRT=0\n' "$MTREE/anom/S02E03.mkv" >> "$STUB_DIR/profiles"
printf '%s\n' "$MTREE/failme/S02E02.mkv" > "$STUB_DIR/faillist"

CONVERT_VIDEO="$(make_stub_convert_video "$STUB_DIR" "$STUB_DIR/profiles" "$STUB_DIR/faillist" "$DEST_DIR")"
FILMS_BASE_DIR="$DEST_DIR"

output="$(main "$MTREE" "ShowX" 2>&1 </dev/null)"

assert_file_exists "duplicate file A left with its original name" "$MTREE/dupA/Show.S01E05.PartA.mkv"
assert_file_exists "duplicate file B left with its original name" "$MTREE/dupB/Show.S01E05.PartB.mkv"
assert_file_exists "unmatched file left with its original name" "$MTREE/nomatch/random_video.mkv"
assert_file_exists "ok1 renamed" "$MTREE/ok1/S02E01.mkv"
assert_file_exists "failme renamed (rename still happens even though conversion later fails)" "$MTREE/failme/S02E02.mkv"
assert_file_exists "anomaly renamed but left unconverted" "$MTREE/anom/S02E03.mkv"

assert_contains "reports the duplicate tag" "$output" "S01E05"
assert_contains "reports the anomaly" "$output" "S02E03"

log_content="$(cat "$STUB_DIR/log")"
assert_contains "converts ok1" "$log_content" "file=$MTREE/ok1/S02E01.mkv genre=ShowX"
assert_contains "attempts failme" "$log_content" "file=$MTREE/failme/S02E02.mkv genre=ShowX"
line_count=$(wc -l < "$STUB_DIR/log" | tr -d ' ')
assert_eq "exactly 2 real conversion attempts (dupes/nomatch/anomaly excluded)" "2" "$line_count"

assert_file_exists "organized: Season 2 created with the successful output" "$DEST_DIR/ShowX/Season 2/S02E01.mp4"
assert_file_missing "organized: no output for the failed conversion" "$DEST_DIR/ShowX/Season 2/S02E02.mp4"

rm -rf "$MTREE" "$STUB_DIR" "$DEST_DIR"

echo "== main: ambiguous (LOW) bucket asks once and applies the answer to every matching file =="

LTREE="$(mktemp -d)"
mkdir -p "$LTREE/e1" "$LTREE/e2"
touch "$LTREE/e1/Show.S01E01.mkv" "$LTREE/e2/Show.S01E02.mkv"

LSTUB_DIR="$(mktemp -d)"
LDEST_DIR="$(mktemp -d)"
: > "$LSTUB_DIR/log"
printf '%s\tCOVERAGE=4.0 FORCED=1 EXTERNAL_SRT=0\n' "$LTREE/e1/S01E01.mkv" > "$LSTUB_DIR/profiles"
printf '%s\tCOVERAGE=4.0 FORCED=1 EXTERNAL_SRT=0\n' "$LTREE/e2/S01E02.mkv" >> "$LSTUB_DIR/profiles"
: > "$LSTUB_DIR/faillist"

CONVERT_VIDEO="$(make_stub_convert_video "$LSTUB_DIR" "$LSTUB_DIR/profiles" "$LSTUB_DIR/faillist" "$LDEST_DIR")"
FILMS_BASE_DIR="$LDEST_DIR"

main "$LTREE" "ShowY" <<< "n" >/dev/null 2>&1

log_content="$(cat "$LSTUB_DIR/log")"
assert_contains "e1 conversion piped the 'n' decision" "$log_content" "file=$LTREE/e1/S01E01.mkv genre=ShowY no_subs=no stdin=n"
assert_contains "e2 conversion piped the same 'n' decision" "$log_content" "file=$LTREE/e2/S01E02.mkv genre=ShowY no_subs=no stdin=n"
line_count=$(wc -l < "$LSTUB_DIR/log" | tr -d ' ')
assert_eq "both files converted with the single decision" "2" "$line_count"

rm -rf "$LTREE" "$LSTUB_DIR" "$LDEST_DIR"

# --- show_dest_path ----------------------------------------------------------
echo "== show_dest_path =="

assert_eq "ordinary show name maps to itself" "Ted Lasso" "$(show_dest_path "Ted Lasso")"
assert_eq "Modern mirrors convert_video's Family/Modern special case" "Family/Modern" "$(show_dest_path "Modern")"
assert_eq "Retro mirrors convert_video's Family/Retro special case" "Family/Retro" "$(show_dest_path "Retro")"

echo "== episode_already_converted respects the Modern/Retro destination path =="

MRDIR="$(mktemp -d)"
mkdir -p "$MRDIR/Family/Modern/Season 1"
touch "$MRDIR/Family/Modern/Season 1/S01E01.mp4"
FILMS_BASE_DIR="$MRDIR"
if episode_already_converted "Modern" "S01E01"; then
    pass "finds the episode under Family/Modern, not a literal 'Modern' folder"
else
    fail "finds the episode under Family/Modern, not a literal 'Modern' folder"
fi
rm -rf "$MRDIR"

# --- season_number_from_tag -------------------------------------------------
echo "== season_number_from_tag =="

assert_eq "S02E01 -> 2 (leading zero stripped)" "2" "$(season_number_from_tag "S02E01")"
assert_eq "S10E12 -> 10" "10" "$(season_number_from_tag "S10E12")"

# --- episode_already_converted ----------------------------------------------
echo "== episode_already_converted =="

EACDIR="$(mktemp -d)"
mkdir -p "$EACDIR/ShowX/Season 2"
touch "$EACDIR/ShowX/Season 2/S02E01.mp4"
touch "$EACDIR/ShowX/S02E05.mp4"   # converted but not yet organized

FILMS_BASE_DIR="$EACDIR"
if episode_already_converted "ShowX" "S02E01"; then
    pass "detects an already-organized episode"
else
    fail "detects an already-organized episode"
fi
if episode_already_converted "ShowX" "S02E05"; then
    pass "detects an already-converted-but-not-yet-organized episode"
else
    fail "detects an already-converted-but-not-yet-organized episode"
fi
if episode_already_converted "ShowX" "S02E09"; then
    fail "does not falsely flag an episode that was never converted"
else
    pass "does not falsely flag an episode that was never converted"
fi

rm -rf "$EACDIR"

echo "== main: skips an already-converted episode instead of re-encoding it =="

SKTREE="$(mktemp -d)"
mkdir -p "$SKTREE/e1" "$SKTREE/e2"
touch "$SKTREE/e1/Show.S02E01.mkv"   # already converted in an earlier run
touch "$SKTREE/e2/Show.S02E02.mkv"   # new, needs converting

SKSTUB_DIR="$(mktemp -d)"
SKDEST_DIR="$(mktemp -d)"
: > "$SKSTUB_DIR/log"
printf '%s\tCOVERAGE=0 FORCED=0 EXTERNAL_SRT=0\n' "$SKTREE/e1/S02E01.mkv" > "$SKSTUB_DIR/profiles"
printf '%s\tCOVERAGE=0 FORCED=0 EXTERNAL_SRT=0\n' "$SKTREE/e2/S02E02.mkv" >> "$SKSTUB_DIR/profiles"
: > "$SKSTUB_DIR/faillist"
mkdir -p "$SKDEST_DIR/ShowX/Season 2"
touch "$SKDEST_DIR/ShowX/Season 2/S02E01.mp4"   # pre-existing output from "before"

CONVERT_VIDEO="$(make_stub_convert_video "$SKSTUB_DIR" "$SKSTUB_DIR/profiles" "$SKSTUB_DIR/faillist" "$SKDEST_DIR")"
FILMS_BASE_DIR="$SKDEST_DIR"

output="$(main "$SKTREE" "ShowX" </dev/null 2>&1)"

log_content="$(cat "$SKSTUB_DIR/log")"
assert_eq "does not re-invoke convert_video for the already-converted episode" "" "$(grep 'S02E01' <<< "$log_content")"
assert_contains "does invoke convert_video for the new episode" "$log_content" "S02E02"
assert_contains "reports the already-converted episode as skipped" "$output" "S02E01"

rm -rf "$SKTREE" "$SKSTUB_DIR" "$SKDEST_DIR"

echo "== main: still organizes stray destination files even when nothing new is renamed =="

NRTREE="$(mktemp -d)"
mkdir -p "$NRTREE/nomatch"
touch "$NRTREE/nomatch/random_video.mkv"   # nothing here will match/rename

NRSTUB_DIR="$(mktemp -d)"
NRDEST_DIR="$(mktemp -d)"
: > "$NRSTUB_DIR/log"
: > "$NRSTUB_DIR/profiles"
: > "$NRSTUB_DIR/faillist"
mkdir -p "$NRDEST_DIR/ShowX"
touch "$NRDEST_DIR/ShowX/S03E01.mp4"   # stray output left over from an earlier interrupted run

CONVERT_VIDEO="$(make_stub_convert_video "$NRSTUB_DIR" "$NRSTUB_DIR/profiles" "$NRSTUB_DIR/faillist" "$NRDEST_DIR")"
FILMS_BASE_DIR="$NRDEST_DIR"

main "$NRTREE" "ShowX" </dev/null >/dev/null 2>&1

assert_file_exists "stray file still gets organized into Season 3 on a no-rename run" "$NRDEST_DIR/ShowX/Season 3/S03E01.mp4"

rm -rf "$NRTREE" "$NRSTUB_DIR" "$NRDEST_DIR"

echo "== main: organizes into Family/Modern (not a literal 'Modern' folder) for that show name =="

MRTREE="$(mktemp -d)"
mkdir -p "$MRTREE/e1"
touch "$MRTREE/e1/Show.S01E01.mkv"

MRSTUB_DIR="$(mktemp -d)"
MRDEST_DIR="$(mktemp -d)"
: > "$MRSTUB_DIR/log"
printf '%s\tCOVERAGE=0 FORCED=0 EXTERNAL_SRT=0\n' "$MRTREE/e1/S01E01.mkv" > "$MRSTUB_DIR/profiles"
: > "$MRSTUB_DIR/faillist"

CONVERT_VIDEO="$(make_stub_convert_video "$MRSTUB_DIR" "$MRSTUB_DIR/profiles" "$MRSTUB_DIR/faillist" "$MRDEST_DIR")"
FILMS_BASE_DIR="$MRDEST_DIR"

main "$MRTREE" "Modern" </dev/null >/dev/null 2>&1

assert_file_exists "organized under Family/Modern/Season 1, matching convert_video's own genre redirect" "$MRDEST_DIR/Family/Modern/Season 1/S01E01.mp4"

rm -rf "$MRTREE" "$MRSTUB_DIR" "$MRDEST_DIR"

test_summary_and_exit
