#!/bin/bash
set -uo pipefail
cd "$(dirname "$0")"
source test_helpers.sh

REPO_ROOT="$(cd .. && pwd)"
FORCED_SUBS="$REPO_ROOT/forced_subs"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/lib" "$WORK/films/Star Wars"
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
EOF

ffmpeg -y -f lavfi -i testsrc=duration=3:size=320x180:rate=10 -f lavfi -i sine=duration=3 \
    -pix_fmt yuv420p "$WORK/films/Star Wars/Phantom Menace.mkv" -hide_banner -loglevel error
cp "$WORK/films/Star Wars/Phantom Menace.mkv" "$WORK/films/Star Wars/No Subtitle Available Film.mkv"

cat > "$WORK/dummy.srt" <<'EOF'
1
00:00:00,000 --> 00:00:02,000
Bocce
EOF

# Fake ost.py: file 1 (Phantom Menace) gets a forced-hash match + a
# downloadable subtitle; file 2 (No Subtitle Available) gets nothing from
# either search, exercising the unavailable-cache path.
cat > "$WORK/lib/ost.py" <<PYEOF
import sys
cmd = sys.argv[1]
if cmd == "hash":
    if "Phantom" in sys.argv[2]:
        print("aaaaaaaaaaaaaaaa")
    else:
        print("bbbbbbbbbbbbbbbb")
elif cmd == "find_forced_by_hash":
    if sys.argv[2] == "aaaaaaaaaaaaaaaa":
        print("4461104\tPhantom.Menace.Forced\ten")
elif cmd == "find_forced_by_imdb":
    pass
elif cmd == "download":
    with open(sys.argv[3], "wb") as f:
        f.write(open("$WORK/dummy.srt", "rb").read())
    print("19\tok")
PYEOF

export FORCED_SUBS_LIBDIR="$WORK/lib"
export FORCED_SUBS_KNOWN_FILMS="$WORK/films.yaml"
export FID_CACHE="$WORK/fid_cache"
export FORCED_SUBS_FILMS_ROOT="$WORK/films"
export SCAN_LOG="$WORK/scan_log"
export APPLY_LOG="$WORK/apply_log"
export UNAVAILABLE_CACHE="$WORK/unavailable_cache"
export OST_API_KEY=test OST_USER_AGENT=test OST_USERNAME=test OST_PASSWORD=test OST_TOKEN=test

"$FORCED_SUBS" apply --max-downloads 5 >/dev/null

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

test_summary_and_exit
