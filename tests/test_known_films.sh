#!/bin/bash
set -uo pipefail
cd "$(dirname "$0")"
source test_helpers.sh

REPO_ROOT="$(cd .. && pwd)"
KNOWN_FILMS_PY="$REPO_ROOT/lib/known_films.py"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/films.yaml" <<'EOF'
films:
  - title: "Star Wars: Episode I - The Phantom Menace"
    aliases: "Phantom Menace|Episode I"
    year: 1999
    imdb_id: "tt0120915"
    editions: "theatrical:133,2011_bluray:136"
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

echo "== lookup by imdb_id =="
result=$(python3 "$KNOWN_FILMS_PY" lookup "$WORK/films.yaml" tt0120915)
assert_eq "returns title/year/editions" \
    "Star Wars: Episode I - The Phantom Menace	1999	theatrical:133,2011_bluray:136" "$result"

echo "== lookup unknown imdb_id exits non-zero and prints nothing =="
out=$(python3 "$KNOWN_FILMS_PY" lookup "$WORK/films.yaml" tt0000001 2>/dev/null)
rc=$?
assert_eq "exit code is non-zero" "no" "$([[ $rc -eq 0 ]] && echo yes || echo no)"
assert_eq "no output" "" "$out"

echo "== find_by_title_year: single unambiguous match ignores year (sanity-check only) =="
result=$(python3 "$KNOWN_FILMS_PY" find_by_title_year "$WORK/films.yaml" "Phantom Menace" "")
assert_eq "matches via alias even with no year given" "tt0120915	Star Wars: Episode I - The Phantom Menace	1999" "$result"

echo "== find_by_title_year: title collision (the Moana case) with no year is ambiguous =="
result=$(python3 "$KNOWN_FILMS_PY" find_by_title_year "$WORK/films.yaml" "Moana" "")
count=$(printf '%s\n' "$result" | grep -c .)
assert_eq "returns both Moana candidates" "2" "$count"

echo "== find_by_title_year: title collision resolved by year =="
result=$(python3 "$KNOWN_FILMS_PY" find_by_title_year "$WORK/films.yaml" "Moana" "2026")
assert_eq "returns only the 2026 Moana" "tt9999999	Moana	2026" "$result"

echo "== find_by_title_year: no match at all =="
result=$(python3 "$KNOWN_FILMS_PY" find_by_title_year "$WORK/films.yaml" "Completely Unknown Film" "")
assert_eq "empty output" "" "$result"

test_summary_and_exit
