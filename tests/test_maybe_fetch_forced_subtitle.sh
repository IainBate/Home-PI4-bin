#!/bin/bash
# Tests for maybe_fetch_forced_subtitle (lib/forced_subs_common.sh) - the
# post-conversion fetch hook convert_video calls once a film finishes
# converting, when nothing else already provided a subtitle. Exercised
# directly rather than through convert_video's own (untested, hardware-
# dependent) full encode pipeline.
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
films:
  - title: "Curated Confident Film"
    aliases: ""
    year: 2020
    imdb_id: "tt1111111"
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

cat > "$WORK/secrets.yaml" <<'EOF'
opensubtitles:
  api_key: "test-key"
  username: "test-user"
  password: "test-pass"
EOF

cat > "$WORK/dummy.srt" <<'EOF'
1
00:00:00,000 --> 00:00:00,300
Forced line.
EOF

ffmpeg -y -f lavfi -i testsrc=duration=3:size=320x180:rate=10 -f lavfi -i sine=duration=3 \
    -pix_fmt yuv420p "$WORK/films/Curated Confident Film.mp4" -hide_banner -loglevel error
cp "$WORK/films/Curated Confident Film.mp4" "$WORK/films/Moana.mp4"
cp "$WORK/films/Curated Confident Film.mp4" "$WORK/films/Totally Unresolvable Film.mp4"
cp "$WORK/films/Curated Confident Film.mp4" "$WORK/films/No Creds Film.mp4"

export FID_CACHE="$WORK/fid_cache"

cat > "$WORK/lib/ost.py" <<PYEOF
import sys
cmd = sys.argv[1]
if cmd == "hash":
    name = sys.argv[2]
    print("aaaaaaaaaaaaaaaa" if "Curated Confident" in name else "0000000000000000")
elif cmd == "identify_by_hash":
    if sys.argv[2] == "aaaaaaaaaaaaaaaa":
        print("tt1111111\tCurated Confident Film\t2020")
elif cmd == "find_forced_by_hash":
    print("101\tSome.Release.Forced\ten")
elif cmd == "find_forced_by_imdb":
    imdb = sys.argv[2]
    if imdb == "9999999":
        print("102\tMoana.2026.Forced\ten")
elif cmd == "download":
    with open(sys.argv[3], "wb") as f:
        f.write(open("$WORK/dummy.srt", "rb").read())
    print("19\tok")
elif cmd == "login":
    print("test-token")
PYEOF

echo "== a confidently auto-identified film is fetched and muxed with no prompt =="
out=$(maybe_fetch_forced_subtitle "$WORK/films/Curated Confident Film.mp4" "$WORK/lib" "$WORK/films.yaml" "$WORK/secrets.yaml" </dev/null)
assert_contains "reports the identified title" "$out" "Curated Confident Film"
assert_contains "reports success" "$out" "Forced-English subtitle added"
analyze=$("$REPO_ROOT/convert_video" --analyze-subs "$WORK/films/Curated Confident Film.mp4")
assert_contains "the file actually has a forced stream now" "$analyze" "FORCED=1"

echo "== an ambiguous title/year prompts, and picking a numbered candidate resolves it =="
out=$(printf '2\n' | maybe_fetch_forced_subtitle "$WORK/films/Moana.mp4" "$WORK/lib" "$WORK/films.yaml" "$WORK/secrets.yaml")
assert_contains "shows both candidates" "$out" "tt3521164"
assert_contains "shows both candidates" "$out" "tt9999999"
assert_contains "resolves and fetches" "$out" "Forced-English subtitle added"
analyze2=$("$REPO_ROOT/convert_video" --analyze-subs "$WORK/films/Moana.mp4")
assert_contains "Moana.mp4 now has a forced stream" "$analyze2" "FORCED=1"
assert_eq "the manual pick (2 -> tt9999999) was recorded in fid_cache" "tt9999999" "$(fid_cache_get_field "$WORK/films/Moana.mp4" imdb_id)"
assert_eq "recorded with manual confidence" "manual" "$(fid_cache_get_field "$WORK/films/Moana.mp4" confidence)"

echo "== a totally unresolvable film prompts for a manual IMDb ID; pressing enter skips =="
rm -f "$WORK/fid_cache"
out=$(printf '\n' | maybe_fetch_forced_subtitle "$WORK/films/Totally Unresolvable Film.mp4" "$WORK/lib" "$WORK/films.yaml" "$WORK/secrets.yaml")
assert_contains "reports skipping" "$out" "Skipping forced-subtitle fetch"
analyze3=$("$REPO_ROOT/convert_video" --analyze-subs "$WORK/films/Totally Unresolvable Film.mp4")
assert_contains "still no forced subtitle" "$analyze3" "FORCED=0"

echo "== missing OpenSubtitles credentials skips gracefully without crashing =="
cat > "$WORK/empty_secrets.yaml" <<'EOF'
opensubtitles:
  api_key: ""
  username: ""
  password: ""
EOF
out=$(maybe_fetch_forced_subtitle "$WORK/films/No Creds Film.mp4" "$WORK/lib" "$WORK/films.yaml" "$WORK/empty_secrets.yaml" </dev/null)
assert_contains "reports skipping due to missing credentials" "$out" "credentials not configured"

test_summary_and_exit
