#!/bin/bash
# Tests for identify_film_from_file's 4th tier (TMDB runtime
# disambiguation), which only fires once hash, curated-filename, and
# OpenSubtitles title-search have all failed. Exercised directly against
# the shared library function, with a fake tmdb.py standing in for the
# live API.
set -uo pipefail
cd "$(dirname "$0")"
source test_helpers.sh

REPO_ROOT="$(cd .. && pwd)"
source "$REPO_ROOT/lib/forced_subs_common.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/lib" "$WORK/films"
cp "$REPO_ROOT/lib/known_films.py" "$WORK/lib/"
cat > "$WORK/films.yaml" <<'EOF'
films: []
EOF

# identify_film_from_file calls the *real* ffprobe on the *real* fixture
# file to measure duration for the runtime tiebreak, so these need to
# actually be long clips, not just placeholders - rate=1 keeps frame
# count (and encode time) trivial despite the long duration.
ffmpeg -y -f lavfi -i testsrc=duration=1:size=320x180:rate=1 -pix_fmt yuv420p "$WORK/films/No Tmdb Key Film.mp4" -hide_banner -loglevel error
ffmpeg -y -f lavfi -i testsrc=duration=1:size=320x180:rate=1 -pix_fmt yuv420p "$WORK/films/Still Ambiguous Film.mp4" -hide_banner -loglevel error
ffmpeg -y -f lavfi -i testsrc=duration=7620:size=320x180:rate=1 -pix_fmt yuv420p "$WORK/films/Jurassic Park.mp4" -hide_banner -loglevel error

cat > "$WORK/lib/ost.py" <<'PYEOF'
import sys
cmd = sys.argv[1]
if cmd == "hash":
    print("0000000000000000")
PYEOF

MARKER="$WORK/tmdb_marker_log"
cat > "$WORK/lib/tmdb.py" <<PYEOF
import sys
with open("$MARKER", "a") as m:
    m.write(" ".join(sys.argv[1:]) + "\n")
title = sys.argv[2] if len(sys.argv) > 2 else ""
if title == "Jurassic Park":
    print("tt0107290\tJurassic Park\t1993")
# "Still Ambiguous Film" and anything else: print nothing (unresolved)
PYEOF

export FID_CACHE="$WORK/fid_cache"

echo "== TMDB tier resolves a title when TMDB_API_KEY is configured =="
export TMDB_API_KEY="test-tmdb-key"
identified=$(identify_film_from_file "$WORK/films/Jurassic Park.mp4" "$WORK/lib" "$WORK/films.yaml")
assert_eq "resolved via TMDB" "tt0107290" "$(printf '%s' "$identified" | cut -f1)"
assert_eq "confidence is tmdb, distinct from the other tiers" "tmdb" "$(printf '%s' "$identified" | cut -f4)"
assert_contains "tmdb.py was actually invoked" "$(cat "$MARKER")" "identify"

echo "== TMDB tier is skipped entirely when TMDB_API_KEY is not set (no credentials configured) =="
unset TMDB_API_KEY
rm -f "$MARKER"
identified2=$(identify_film_from_file "$WORK/films/No Tmdb Key Film.mp4" "$WORK/lib" "$WORK/films.yaml")
assert_eq "still unresolved" "" "$(printf '%s' "$identified2" | cut -f1)"
assert_eq "reason is no_match" "no_match" "$(printf '%s' "$identified2" | cut -f5)"
if [ -f "$MARKER" ]; then
    fail "tmdb.py was invoked despite TMDB_API_KEY being unset"
else
    pass "tmdb.py was never invoked without credentials configured"
fi

echo "== TMDB tier declining to guess (still ambiguous) falls through to unresolved/no_match =="
export TMDB_API_KEY="test-tmdb-key"
identified3=$(identify_film_from_file "$WORK/films/Still Ambiguous Film.mp4" "$WORK/lib" "$WORK/films.yaml")
assert_eq "no imdb_id" "" "$(printf '%s' "$identified3" | cut -f1)"
assert_eq "confidence is unresolved, not tmdb" "unresolved" "$(printf '%s' "$identified3" | cut -f4)"
assert_eq "reason is no_match" "no_match" "$(printf '%s' "$identified3" | cut -f5)"

test_summary_and_exit
