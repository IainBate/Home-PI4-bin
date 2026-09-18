#!/bin/bash
# Regression test for the multi-edition safety check in cmd_apply: when a
# curated title has more than one edition (e.g. theatrical vs extended)
# and OpenSubtitles' edition-exact hash lookup finds nothing, apply falls
# back to the runtime-unfiltered IMDb search. That fallback's candidate
# must not be trusted blindly.
#
# An earlier version of this check compared the candidate SRT's own last
# cue timestamp to the video's actual duration - that was WRONG: a forced
# subtitle track only covers foreign-language dialogue scenes, so even a
# correctly-matched candidate's last cue can sit long before the credits
# (proven directly against a real OpenSubtitles response for The
# Fellowship of the Ring's extended cut, whose last forced cue lands 46
# minutes before the film's actual end). The fix instead checks the
# candidate's own release-name string for an explicit conflicting edition
# label - see edition_label_conflict() in forced_subs.
set -uo pipefail
cd "$(dirname "$0")"
source test_helpers.sh

REPO_ROOT="$(cd .. && pwd)"
FORCED_SUBS="$REPO_ROOT/forced_subs"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/lib" "$WORK/films/Match" "$WORK/films/Conflict" "$WORK/films/Unresolved"
cp "$REPO_ROOT/lib/forced_subs_common.sh" "$REPO_ROOT/lib/known_films.py" "$WORK/lib/"

cat > "$WORK/films.yaml" <<'EOF'
films:
  - title: "Label Match Film"
    aliases: ""
    year: 2024
    imdb_id: "tt7000001"
    editions: "theatrical:5,extended:20"
  - title: "Label Conflict Film"
    aliases: ""
    year: 2024
    imdb_id: "tt7000002"
    editions: "theatrical:5,extended:20"
  - title: "Unresolved Edition Film"
    aliases: ""
    year: 2024
    imdb_id: "tt7000003"
    editions: "theatrical:5,extended:20"
EOF

# Match and Conflict fixtures are ~20 minutes (1200s) long, i.e. actually
# the "extended" cut per pick_edition. Unresolved is ~50 minutes - not
# within 3 minutes of either curated edition, so pick_edition can't
# confidently resolve it at all. rate=1 keeps frame count (and encode
# time) trivial despite the long durations.
ffmpeg -y -f lavfi -i testsrc=duration=1200:size=320x180:rate=1 -f lavfi -i sine=duration=1200 \
    -pix_fmt yuv420p "$WORK/films/Match/Label Match Film.mkv" -hide_banner -loglevel error
ffmpeg -y -f lavfi -i testsrc=duration=1200:size=320x180:rate=1 -f lavfi -i sine=duration=1200 \
    -pix_fmt yuv420p "$WORK/films/Conflict/Label Conflict Film.mkv" -hide_banner -loglevel error
ffmpeg -y -f lavfi -i testsrc=duration=3000:size=320x180:rate=1 -f lavfi -i sine=duration=3000 \
    -pix_fmt yuv420p "$WORK/films/Unresolved/Unresolved Edition Film.mkv" -hide_banner -loglevel error

MATCH_FILE="$WORK/films/Match/Label Match Film.mkv"
CONFLICT_FILE="$WORK/films/Conflict/Label Conflict Film.mkv"
UNRESOLVED_FILE="$WORK/films/Unresolved/Unresolved Edition Film.mkv"

cat > "$WORK/dummy.srt" <<'EOF'
1
00:00:05,000 --> 00:00:08,000
A forced line, wherever it happens to fall in the runtime.
EOF

# Fake ost.py: find_forced_by_hash always comes back empty (forces every
# fixture through the IMDb fallback, when it's even attempted), and
# find_forced_by_imdb's release name is exactly what each case is testing
# - a label matching the resolved edition, a label conflicting with it,
# or (for the unresolved-edition fixture, which must never even reach
# this call) an entry that would fail the test outright if it were
# invoked. Every imdb-fallback call is also recorded to a marker log.
cat > "$WORK/lib/ost.py" <<PYEOF
import sys
cmd = sys.argv[1]
MARKER = "$WORK/imdb_marker_log"
if cmd == "hash":
    print("0000000000000000")
elif cmd == "find_forced_by_hash":
    pass
elif cmd == "find_forced_by_imdb":
    imdb = sys.argv[2]
    with open(MARKER, "a") as m:
        m.write(imdb + "\n")
    if imdb == "7000001":
        print("101\tSome.Release.Extended.Edition.1080p\ten")
    elif imdb == "7000002":
        print("102\tSome.Release.Theatrical.Cut.1080p\ten")
    elif imdb == "7000003":
        print("103\tShould.Never.Be.Requested\ten")
elif cmd == "download":
    with open(sys.argv[3], "wb") as f:
        f.write(open("$WORK/dummy.srt", "rb").read())
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

marker_log() { cat "$WORK/imdb_marker_log" 2>/dev/null || true; }

echo "== a candidate labelled with the resolved edition is trusted and muxed in =="
analyze_match=$("$REPO_ROOT/convert_video" --analyze-subs "$MATCH_FILE")
assert_contains "FORCED=1 after apply (release name matches resolved edition)" "$analyze_match" "FORCED=1"
assert_contains "logged success for the matched fixture" "$(cat "$APPLY_LOG")" "$(printf '%s\tsuccess' "$MATCH_FILE")"

echo "== a candidate explicitly labelled as a different edition is rejected =="
analyze_conflict=$("$REPO_ROOT/convert_video" --analyze-subs "$CONFLICT_FILE")
assert_contains "still FORCED=0 (conflicting-edition candidate was not trusted)" "$analyze_conflict" "FORCED=0"
assert_contains "logged unavailable/ambiguous for the conflicting fixture" "$(cat "$APPLY_LOG")" "$(printf '%s\tunavailable\tambiguous' "$CONFLICT_FILE")"

echo "== a file whose own edition can't be resolved never even attempts the fallback =="
analyze_unresolved=$("$REPO_ROOT/convert_video" --analyze-subs "$UNRESOLVED_FILE")
assert_contains "still FORCED=0 (bailed before searching)" "$analyze_unresolved" "FORCED=0"
assert_contains "logged unavailable/ambiguous for the unresolved fixture" "$(cat "$APPLY_LOG")" "$(printf '%s\tunavailable\tambiguous' "$UNRESOLVED_FILE")"
if [[ "$(marker_log)" == *"7000003"* ]]; then
    fail "find_forced_by_imdb was called for the unresolved-edition fixture (should have bailed first)"
else
    pass "find_forced_by_imdb was never called for the unresolved-edition fixture"
fi

test_summary_and_exit
