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
  - title: "Star Wars: Episode IV - A New Hope"
    aliases: "A New Hope|Star Wars"
    year: 1977
    imdb_id: "tt0076759"
    editions: "theatrical:121"
  - title: "Solo: A Star Wars Story"
    aliases: "Solo"
    year: 2018
    imdb_id: "tt3778644"
    editions: "theatrical:135"
  - title: "Dune"
    aliases: ""
    year: 2021
    imdb_id: "tt1160419"
    editions: "theatrical:155"
  - title: "Dune: Part Two"
    aliases: "Dune Part Two"
    year: 2024
    imdb_id: "tt15239678"
    editions: "theatrical:166"
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

echo "== find_by_title_year: real-world compound filename combining two aliases =="
# Real library filenames often concatenate multiple identifying phrases
# into one string (e.g. "Episode I - The Phantom Menace") rather than
# using a single curated alias verbatim - this must still match via
# word-boundary substring containment, not require an exact whole-string
# equality.
result=$(python3 "$KNOWN_FILMS_PY" find_by_title_year "$WORK/films.yaml" "Episode I - The Phantom Menace" "")
assert_eq "matches despite combining both 'Episode I' and 'Phantom Menace'" \
    "tt0120915	Star Wars: Episode I - The Phantom Menace	1999" "$result"

echo "== find_by_title_year: word-boundary matching rejects partial-word overlap =="
# "War" (from the "Star Wars" alias) must not match inside "Warfare" -
# _contains_as_words is a word-boundary check, not a raw substring check.
result=$(python3 "$KNOWN_FILMS_PY" find_by_title_year "$WORK/films.yaml" "Modern Warfare Chronicles" "")
assert_eq "no false match from a partial word overlap" "" "$result"

echo "== find_by_title_year: a real word-boundary match on a multi-word alias still works =="
result=$(python3 "$KNOWN_FILMS_PY" find_by_title_year "$WORK/films.yaml" "Star Wars - Behind the Scenes" "")
assert_eq "matches via the 'Star Wars' alias as whole words" \
    "tt0076759	Star Wars: Episode IV - A New Hope	1977" "$result"

echo "== find_by_title_year: an exact full match beats a weaker partial match from a different film =="
# "Solo - A Star Wars Story" contains the words "Star Wars" (Episode IV's
# generic alias) as a partial/containment match, but it's also an exact
# full-string match for Solo's own title - the exact match must win
# outright, not tie with the weaker partial match and go ambiguous.
result=$(python3 "$KNOWN_FILMS_PY" find_by_title_year "$WORK/films.yaml" "Solo - A Star Wars Story" "")
assert_eq "resolves to Solo, not an ambiguous tie with the Star Wars alias" \
    "tt3778644	Solo: A Star Wars Story	2018" "$result"

echo "== find_by_title_year: a sequel whose title contains the base film's title is not ambiguous =="
# "Dune" is a weaker partial match (its own title is a substring of the
# target); "Dune: Part Two"'s own title is an exact match for the target.
# The exact match must win, not tie with the weaker partial match.
result=$(python3 "$KNOWN_FILMS_PY" find_by_title_year "$WORK/films.yaml" "Dune Part Two" "")
assert_eq "resolves to the sequel, not an ambiguous tie with the base film" \
    "tt15239678	Dune: Part Two	2024" "$result"

echo "== find_by_title_year: the base film alone still resolves to itself, not the sequel =="
result=$(python3 "$KNOWN_FILMS_PY" find_by_title_year "$WORK/films.yaml" "Dune" "")
assert_eq "bare 'Dune' resolves to the base film" "tt1160419	Dune	2021" "$result"

test_summary_and_exit
