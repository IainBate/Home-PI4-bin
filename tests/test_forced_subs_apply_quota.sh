#!/bin/bash
set -uo pipefail
cd "$(dirname "$0")"
source test_helpers.sh

# Regression test for a real production incident (2026-09-24): once
# OpenSubtitles' daily download quota ran out mid-run, every remaining
# candidate's download came back HTTP 406, was recorded as
# download_failed, and so landed in the unavailable cache - hiding 9
# films that DO have a forced subtitle for a week. A quota refusal must
# instead stop the run cleanly, leaving the film uncached so tomorrow's
# run retries it.

REPO_ROOT="$(cd .. && pwd)"
FORCED_SUBS="$REPO_ROOT/forced_subs"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/lib" "$WORK/films/Quota"
cp "$REPO_ROOT/lib/forced_subs_common.sh" "$REPO_ROOT/lib/known_films.py" "$WORK/lib/"

cat > "$WORK/films.yaml" <<'EOF'
films:
  - title: "Quota Film One"
    aliases: ""
    year: 2020
    imdb_id: "tt1000001"
    editions: "theatrical:0"
  - title: "Quota Film Two"
    aliases: ""
    year: 2021
    imdb_id: "tt1000002"
    editions: "theatrical:0"
EOF

FILM_ONE="$WORK/films/Quota/Quota Film One.mkv"
FILM_TWO="$WORK/films/Quota/Quota Film Two.mkv"
ffmpeg -y -f lavfi -i testsrc=duration=3:size=320x180:rate=10 -f lavfi -i sine=duration=3 \
    -pix_fmt yuv420p "$FILM_ONE" -hide_banner -loglevel error
cp "$FILM_ONE" "$FILM_TWO"

# Fake ost.py: both films have a hash match, but every download is refused
# the way the real ost.py reports a 406 quota refusal (exit 3).
cat > "$WORK/lib/ost.py" <<PYEOF
import sys
cmd = sys.argv[1]
if cmd == "hash":
    print("1111111111111111" if "One" in sys.argv[2] else "2222222222222222")
elif cmd == "find_forced_by_hash":
    print("555\tQuota.Film.Forced\ten")
elif cmd == "download":
    import os
    with open("$WORK/download_marker_log", "a") as m:
        m.write("download base_url=" + os.environ.get("OST_BASE_URL", "") + "\n")
    sys.stderr.write('HTTP 406 calling download: {"remaining":-1,"message":"You have downloaded your allowed 5 subtitles for 24h."}\n')
    sys.exit(3)
elif cmd == "login":
    print("test-token-abc123\tvip-api.opensubtitles.com\tuser_id=42 level=Sub leecher allowed_downloads=20 vip=False base_url=vip-api.opensubtitles.com")
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

printf '%s\ttt1000001\tQuota Film One\t2020\tmanual\t\t2026-01-01\n' "$FILM_ONE" >> "$FID_CACHE"
printf '%s\ttt1000002\tQuota Film Two\t2021\tmanual\t\t2026-01-01\n' "$FILM_TWO" >> "$FID_CACHE"

"$FORCED_SUBS" apply --max-downloads 15 >/dev/null 2>&1
rc=$?

echo "== a quota refusal ends the run cleanly =="
assert_eq "apply exits 0 (quota exhaustion is not a failure)" "0" "$rc"
assert_eq "stops after the first refused download" "1" "$(grep -c download "$WORK/download_marker_log" 2>/dev/null || echo 0)"
assert_contains "logs the refusal as quota_exceeded" "$(cat "$APPLY_LOG" 2>/dev/null)" "quota_exceeded"

echo "== login details are passed on and logged =="
assert_contains "download calls get the login-supplied base_url" "$(cat "$WORK/download_marker_log" 2>/dev/null)" "base_url=vip-api.opensubtitles.com"
assert_contains "apply log records the login summary" "$(cat "$APPLY_LOG" 2>/dev/null)" "$(printf 'login\tuser_id=42 level=Sub leecher allowed_downloads=20')"
if grep -q "test-token-abc123" "$APPLY_LOG" 2>/dev/null; then
    fail "apply log must never contain the login token"
else
    pass "apply log never contains the login token"
fi

echo "== no film is marked unavailable because of the quota =="
if [ -s "$UNAVAILABLE_CACHE" ]; then
    fail "unavailable cache should be empty, got: $(cat "$UNAVAILABLE_CACHE")"
else
    pass "unavailable cache left empty"
fi
if grep -q "download_failed" "$APPLY_LOG" 2>/dev/null; then
    fail "quota refusal must not be logged as download_failed"
else
    pass "no download_failed entries"
fi

test_summary_and_exit
