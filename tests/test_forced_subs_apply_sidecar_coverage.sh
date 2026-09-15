#!/bin/bash
# Focused regression test for Fix 2 (final-review fix wave, C2): a sidecar
# .srt whose own cue coverage is high (a full-length dialogue subtitle, not
# a short forced-only one) must NOT be trusted as "forced" just because it
# sits next to the film with a matching basename. It must fall through to
# the normal hash/imdb search path instead - see srt_coverage_percent() and
# its use in cmd_apply in forced_subs.
set -uo pipefail
cd "$(dirname "$0")"
source test_helpers.sh

REPO_ROOT="$(cd .. && pwd)"
FORCED_SUBS="$REPO_ROOT/forced_subs"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/lib" "$WORK/films/FullSidecar"
cp "$REPO_ROOT/lib/forced_subs_common.sh" "$REPO_ROOT/lib/known_films.py" "$WORK/lib/"

cat > "$WORK/films.yaml" <<'EOF'
films:
  - title: "Full Coverage Sidecar Film"
    aliases: ""
    year: 2024
    imdb_id: "tt5555555"
    editions: "theatrical:0"
EOF

ffmpeg -y -f lavfi -i testsrc=duration=3:size=320x180:rate=10 -f lavfi -i sine=duration=3 \
    -pix_fmt yuv420p "$WORK/films/FullSidecar/Full Coverage Sidecar Film.mkv" -hide_banner -loglevel error

FILE="$WORK/films/FullSidecar/Full Coverage Sidecar Film.mkv"

# A sidecar .srt whose cue spans nearly the whole 3s video (~93% coverage) -
# a full-length dialogue track, not a short forced-only one. Must be
# rejected as untrustworthy per the <15% threshold.
cat > "$WORK/films/FullSidecar/Full Coverage Sidecar Film.srt" <<'EOF'
1
00:00:00,000 --> 00:00:02,800
This is a full-length dialogue subtitle, not a short forced-only line.
EOF

# Fake ost.py: records every find_forced_by_hash/find_forced_by_imdb call
# to a marker log (proof the search path ran) and always returns no match,
# so a successful remux can only have happened via the (untrustworthy)
# sidecar shortcut.
cat > "$WORK/lib/ost.py" <<PYEOF
import sys
cmd = sys.argv[1]
MARKER = "$WORK/search_marker_log"
if cmd == "hash":
    print("ffffffffffffffff")
elif cmd == "find_forced_by_hash":
    with open(MARKER, "a") as m:
        m.write("hash\n")
elif cmd == "find_forced_by_imdb":
    with open(MARKER, "a") as m:
        m.write("imdb\n")
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

marker_log() { cat "$WORK/search_marker_log" 2>/dev/null || true; }

echo "== a full-coverage sidecar is not trusted: the film is left untouched =="
analyze=$("$REPO_ROOT/convert_video" --analyze-subs "$FILE")
assert_contains "still FORCED=0 (sidecar was not muxed in)" "$analyze" "FORCED=0"

echo "== the search path ran instead of the sidecar shortcut =="
if [[ "$(marker_log)" == *"hash"* ]]; then
    pass "find_forced_by_hash was called (fell through to search, as required)"
else
    fail "find_forced_by_hash was never called - full-coverage sidecar was wrongly trusted"
fi

echo "== logged as unavailable (no_match_found), not as a success via the sidecar =="
assert_contains "logged unavailable, not success" "$(cat "$APPLY_LOG")" "$(printf '%s\tunavailable' "$FILE")"

test_summary_and_exit
