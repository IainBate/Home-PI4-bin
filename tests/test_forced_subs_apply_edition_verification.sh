#!/bin/bash
# Regression test for the multi-edition runtime-verification fix in
# cmd_apply: when a curated title has more than one edition (e.g.
# theatrical vs extended) and OpenSubtitles' edition-exact hash lookup
# finds nothing, apply falls back to the runtime-unfiltered IMDb search.
# That fallback must not be trusted blindly - the downloaded candidate's
# own last-cue timestamp must line up with this file's actual duration
# (see srt_last_cue_minutes() and its use in cmd_apply in forced_subs).
# A close match should still get muxed in; a mismatch (wrong edition's
# subtitle) must be rejected and logged "ambiguous", same as before this
# fix existed for the case where the fallback never even ran.
set -uo pipefail
cd "$(dirname "$0")"
source test_helpers.sh

REPO_ROOT="$(cd .. && pwd)"
FORCED_SUBS="$REPO_ROOT/forced_subs"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/lib" "$WORK/films/Match" "$WORK/films/Mismatch"
cp "$REPO_ROOT/lib/forced_subs_common.sh" "$REPO_ROOT/lib/known_films.py" "$WORK/lib/"

cat > "$WORK/films.yaml" <<'EOF'
films:
  - title: "Runtime Match Film"
    aliases: ""
    year: 2024
    imdb_id: "tt6000001"
    editions: "theatrical:5,extended:20"
  - title: "Runtime Mismatch Film"
    aliases: ""
    year: 2024
    imdb_id: "tt6000002"
    editions: "theatrical:5,extended:20"
EOF

# Both fixtures are ~20 minutes (1200s) long - i.e. actually the "extended"
# cut. rate=1 keeps frame count (and encode time) trivial despite the long
# duration.
ffmpeg -y -f lavfi -i testsrc=duration=1200:size=320x180:rate=1 -f lavfi -i sine=duration=1200 \
    -pix_fmt yuv420p "$WORK/films/Match/Runtime Match Film.mkv" -hide_banner -loglevel error
ffmpeg -y -f lavfi -i testsrc=duration=1200:size=320x180:rate=1 -f lavfi -i sine=duration=1200 \
    -pix_fmt yuv420p "$WORK/films/Mismatch/Runtime Mismatch Film.mkv" -hide_banner -loglevel error

MATCH_FILE="$WORK/films/Match/Runtime Match Film.mkv"
MISMATCH_FILE="$WORK/films/Mismatch/Runtime Mismatch Film.mkv"

# Candidate SRT for the "match" fixture: last cue ends at 19:55 (~19 min),
# within the 5-minute tolerance of the file's actual ~20 min duration.
cat > "$WORK/match_candidate.srt" <<'EOF'
1
00:19:50,000 --> 00:19:55,000
Closing line, near the end of the extended cut.
EOF

# Candidate SRT for the "mismatch" fixture: last cue ends at 05:00 (~5 min)
# - the OTHER curated edition's runtime, 15 minutes off the file's actual
# ~20 min duration and well past the 5-minute tolerance.
cat > "$WORK/mismatch_candidate.srt" <<'EOF'
1
00:04:55,000 --> 00:05:00,000
Closing line, but from the theatrical cut's runtime instead.
EOF

# Fake ost.py: find_forced_by_hash always comes back empty (forces every
# fixture through the IMDb fallback), find_forced_by_imdb returns a
# distinct sub_file_id per imdb_id, and download serves the matching
# candidate SRT prepared above.
cat > "$WORK/lib/ost.py" <<PYEOF
import sys
cmd = sys.argv[1]
if cmd == "hash":
    print("0000000000000000")
elif cmd == "find_forced_by_hash":
    pass
elif cmd == "find_forced_by_imdb":
    imdb = sys.argv[2]
    if imdb == "6000001":
        print("101\tRuntime.Match.Forced\ten")
    elif imdb == "6000002":
        print("102\tRuntime.Mismatch.Forced\ten")
elif cmd == "download":
    sub_id = sys.argv[2]
    src = "$WORK/match_candidate.srt" if sub_id == "101" else "$WORK/mismatch_candidate.srt"
    with open(sys.argv[3], "wb") as f:
        f.write(open(src, "rb").read())
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

echo "== a runtime-matched fallback candidate gets muxed in =="
analyze_match=$("$REPO_ROOT/convert_video" --analyze-subs "$MATCH_FILE")
assert_contains "FORCED=1 after apply (runtime matched within tolerance)" "$analyze_match" "FORCED=1"
assert_contains "logged success for the matched fixture" "$(cat "$APPLY_LOG")" "$(printf '%s\tsuccess' "$MATCH_FILE")"

echo "== a runtime-mismatched fallback candidate is rejected, not muxed in =="
analyze_mismatch=$("$REPO_ROOT/convert_video" --analyze-subs "$MISMATCH_FILE")
assert_contains "still FORCED=0 (wrong-edition candidate was not trusted)" "$analyze_mismatch" "FORCED=0"
assert_contains "logged unavailable/ambiguous for the mismatched fixture" "$(cat "$APPLY_LOG")" "$(printf '%s\tunavailable\tambiguous' "$MISMATCH_FILE")"

test_summary_and_exit
