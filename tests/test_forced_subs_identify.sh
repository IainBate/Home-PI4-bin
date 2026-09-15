#!/bin/bash
set -uo pipefail
cd "$(dirname "$0")"
source test_helpers.sh

REPO_ROOT="$(cd .. && pwd)"
FORCED_SUBS="$REPO_ROOT/forced_subs"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/lib" "$WORK/films/Star Wars" "$WORK/films/Moana Films"
cp "$REPO_ROOT/lib/forced_subs_common.sh" "$REPO_ROOT/lib/known_films.py" "$WORK/lib/"
touch "$WORK/films/Star Wars/Phantom Menace.mp4"
touch "$WORK/films/Moana Films/Moana - 2026.mp4"
touch "$WORK/films/Moana Films/Moana - 2016.mp4"
touch "$WORK/films/Moana Films/Moana.mp4"

cat > "$WORK/films.yaml" <<'EOF'
films:
  - title: "Star Wars: Episode I - The Phantom Menace"
    aliases: "Phantom Menace|Episode I"
    year: 1999
    imdb_id: "tt0120915"
    editions: "theatrical:133"
  - title: "Moana"
    aliases: ""
    year: 2016
    imdb_id: "tt3521164"
    editions: "theatrical:107"
  - title: "Moana"
    aliases: ""
    year: 2026
    imdb_id: "tt9999999"
    editions: "theatrical:110"
EOF

# Fake ost.py: `hash` returns a fixed value; every network subcommand
# returns nothing (empty), forcing identify down the filename-fallback
# path deterministically for this test.
cat > "$WORK/lib/ost.py" <<'PYEOF'
import sys
if sys.argv[1] == "hash":
    print("0000000000000000")
PYEOF

export FORCED_SUBS_LIBDIR="$WORK/lib"
export FORCED_SUBS_KNOWN_FILMS="$WORK/films.yaml"
export FORCED_SUBS_LOCKFILE="$WORK/forced_subs.lock"
export FID_CACHE="$WORK/fid_cache"
export FORCED_SUBS_FILMS_ROOT="$WORK/films"
export OST_API_KEY=test OST_USER_AGENT=test OST_USERNAME=test OST_PASSWORD=test

echo "== unambiguous filename match resolves via the fallback path =="
"$FORCED_SUBS" identify >/dev/null
source "$WORK/lib/forced_subs_common.sh"
assert_eq "Phantom Menace resolved to its imdb_id" "tt0120915" "$(fid_cache_get_field "$WORK/films/Star Wars/Phantom Menace.mp4" imdb_id)"
assert_eq "confidence is filename, not hash (fake ost.py returns no hash match)" "filename" "$(fid_cache_get_field "$WORK/films/Star Wars/Phantom Menace.mp4" confidence)"

echo "== the Moana case: year in the filename disambiguates =="
assert_eq "Moana - 2026 resolves to the 2026 entry" "tt9999999" "$(fid_cache_get_field "$WORK/films/Moana Films/Moana - 2026.mp4" imdb_id)"
assert_eq "Moana - 2016 resolves to the 2016 entry" "tt3521164" "$(fid_cache_get_field "$WORK/films/Moana Films/Moana - 2016.mp4" imdb_id)"

echo "== the Moana case: no year in the filename is left unresolved, not guessed =="
assert_eq "ambiguous file has no imdb_id" "" "$(fid_cache_get_field "$WORK/films/Moana Films/Moana.mp4" imdb_id)"
assert_eq "reason recorded as ambiguous" "ambiguous_title_multiple_years" "$(fid_cache_get_field "$WORK/films/Moana Films/Moana.mp4" reason)"

echo "== --set manually resolves an ambiguous file and is sticky =="
"$FORCED_SUBS" identify --set "$WORK/films/Moana Films/Moana.mp4" tt9999999 >/dev/null
assert_eq "manually set imdb_id" "tt9999999" "$(fid_cache_get_field "$WORK/films/Moana Films/Moana.mp4" imdb_id)"
assert_eq "confidence is manual" "manual" "$(fid_cache_get_field "$WORK/films/Moana Films/Moana.mp4" confidence)"
"$FORCED_SUBS" identify --rehash >/dev/null
assert_eq "a later plain identify --rehash does not overwrite the manual entry" "manual" "$(fid_cache_get_field "$WORK/films/Moana Films/Moana.mp4" confidence)"

test_summary_and_exit
