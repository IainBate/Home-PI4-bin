#!/usr/bin/env python3
"""TMDB (themoviedb.org) REST API helper for forced_subs's fourth
identification tier - runtime-based disambiguation when the hash match,
the curated known_films.yaml list, and OpenSubtitles' own title-search
have all failed to resolve a file (see identify_film_from_file in
lib/forced_subs_common.sh). Exists specifically for titles that collide
with a remake/sequel of the same name (e.g. "Jurassic Park" vs "Jurassic
World", "The Lion King" 1994 vs 2019) where OpenSubtitles' search has no
runtime data to tell them apart.

Stdlib only (urllib, json), same conventions as ost.py: credentials come
from environment variables, never argv, so they never show up in `ps`.

Usage:
  tmdb.py identify <title> [year] [file_duration_min]   (env: TMDB_API_KEY)
"""
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

BASE_URL = "https://api.themoviedb.org/3"

# How many minutes a candidate's TMDB-listed runtime may differ from the
# file's own measured duration and still count as a match. Real title
# collisions (remakes, sequels sharing a name) differ by tens of minutes
# in practice, so this stays tight deliberately - it only needs to absorb
# minor rounding/cut differences, never enough to blur two different
# films together.
RUNTIME_TOLERANCE_MIN = 5

# A single generic title can return many "exact match" results (rare, but
# possible) - cap how many candidates get a details lookup (a second API
# call each) per identify attempt.
MAX_CANDIDATES = 5


def _request(path, api_key):
    sep = "&" if "?" in path else "?"
    url = f"{BASE_URL}/{path}{sep}api_key={urllib.parse.quote(api_key)}"
    req = urllib.request.Request(url, headers={"Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        sys.stderr.write(f"HTTP {e.code} calling {path}: {e.read().decode('utf-8', 'replace')}\n")
        sys.exit(1)
    except urllib.error.URLError as e:
        sys.stderr.write(f"network error calling {path}: {e}\n")
        sys.exit(1)


def _normalize_for_title_match(s):
    s = s.lower()
    s = re.sub(r"[^a-z0-9]+", " ", s)
    return " ".join(s.split())


def _exact_title_matches(search_results, title):
    target = _normalize_for_title_match(title)
    out = []
    for item in search_results:
        item_title = item.get("title") or item.get("original_title") or ""
        if _normalize_for_title_match(item_title) == target:
            out.append(item)
    return out


def _finalize(item, details_by_id):
    details = details_by_id.get(item.get("id")) or {}
    imdb_id = details.get("imdb_id") or ""
    if not imdb_id:
        # No IMDb ID on this TMDB entry - the rest of forced_subs is
        # entirely IMDb-ID-centric (known_films.yaml, fid_cache, the
        # OpenSubtitles lookups), so a match we can't express as an
        # imdb_id is useless here regardless of how well the title/
        # runtime matched.
        return None
    title = item.get("title") or item.get("original_title") or ""
    year = str(item.get("release_date") or "")[:4]
    return imdb_id, title, year


# Pure filtering/tiebreak logic, separated from the HTTP calls below so
# it's unit-testable without a live API. `details_by_id` maps a
# candidate's TMDB id to its /movie/{id} response (only the candidates
# the caller actually fetched, per MAX_CANDIDATES).
#
# Stage 1: exact normalized-title match required, same discipline as
# ost.py's pick_title_match - never loose/fuzzy. If a year was given and
# narrows the exact-title matches to precisely one, that's resolved
# without needing runtime at all (matches OpenSubtitles tier's own
# trust model: exact title + exact year is already high-confidence).
# Stage 2 (no year, or year alone still leaves more than one): use each
# remaining candidate's own runtime against the file's actual measured
# duration - exactly one candidate within RUNTIME_TOLERANCE_MIN wins;
# zero or multiple is still ambiguous, never guessed.
def pick_candidate(search_results, title, year, file_duration_min, details_by_id):
    exact = _exact_title_matches(search_results, title)
    if not exact:
        return None

    if year:
        year_matches = [c for c in exact if str(c.get("release_date") or "")[:4] == str(year)]
        if len(year_matches) == 1:
            return _finalize(year_matches[0], details_by_id)
        if year_matches:
            exact = year_matches

    if len(exact) == 1 and not year:
        # A single exact-title match with no year available at all to
        # even attempt disambiguation, and no other candidates to be
        # ambiguous against - runtime isn't needed to break a tie that
        # doesn't exist, but do still require it actually correspond to
        # something with an imdb_id.
        return _finalize(exact[0], details_by_id)

    if file_duration_min is None:
        return None

    by_runtime = []
    for item in exact:
        details = details_by_id.get(item.get("id"))
        if not details:
            continue
        runtime = details.get("runtime")
        if not runtime:
            continue
        if abs(runtime - file_duration_min) <= RUNTIME_TOLERANCE_MIN:
            by_runtime.append(item)

    if len(by_runtime) == 1:
        return _finalize(by_runtime[0], details_by_id)
    return None


def cmd_identify(title, year, file_duration_min):
    api_key = os.environ["TMDB_API_KEY"]
    query = urllib.parse.quote(title)
    path = f"search/movie?query={query}"
    if year:
        path += f"&year={urllib.parse.quote(str(year))}"
    resp = _request(path, api_key)
    results = resp.get("results") or []

    exact = _exact_title_matches(results, title)[:MAX_CANDIDATES]
    details_by_id = {}
    for item in exact:
        movie_id = item.get("id")
        if movie_id is not None:
            details_by_id[movie_id] = _request(f"movie/{movie_id}", api_key)

    match = pick_candidate(results, title, year, file_duration_min, details_by_id)
    if match:
        imdb_id, matched_title, matched_year = match
        print(f"{imdb_id}\t{matched_title}\t{matched_year}")


def main():
    if len(sys.argv) < 2:
        sys.stderr.write(__doc__)
        sys.exit(2)
    cmd, args = sys.argv[1], sys.argv[2:]
    if cmd == "identify":
        title = args[0]
        year = args[1] if len(args) > 1 and args[1] else ""
        duration_min = None
        if len(args) > 2 and args[2]:
            duration_min = int(args[2])
        cmd_identify(title, year, duration_min)
    else:
        sys.stderr.write(f"unknown command: {cmd}\n")
        sys.exit(2)


if __name__ == "__main__":
    main()
