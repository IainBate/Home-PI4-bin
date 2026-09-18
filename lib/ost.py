#!/usr/bin/env python3
"""OpenSubtitles.com REST API + moviehash helper for forced_subs.

Stdlib only (urllib, json, struct) so this runs on the Pi's system python3
with no venv/pip install. Credentials come from environment variables,
never argv, so they never show up in `ps`.

Usage:
  ost.py hash <file>
  ost.py login                                    (env: OST_API_KEY OST_USER_AGENT OST_USERNAME OST_PASSWORD)
  ost.py identify_by_hash <hash>                   (env: OST_API_KEY OST_USER_AGENT)
  ost.py find_forced_by_hash <hash>                (env: OST_API_KEY OST_USER_AGENT)
  ost.py find_forced_by_imdb <imdb_numeric>        (env: OST_API_KEY OST_USER_AGENT)
  ost.py search_by_title <title> [year]            (env: OST_API_KEY OST_USER_AGENT)
  ost.py download <file_id> <output_path>          (env: OST_API_KEY OST_USER_AGENT OST_TOKEN)
"""
import json
import os
import re
import struct
import sys
import urllib.error
import urllib.parse
import urllib.request

BASE_URL = "https://api.opensubtitles.com/api/v1"


def moviehash(path):
    longlongformat = "<q"
    bytesize = struct.calcsize(longlongformat)
    filesize = os.path.getsize(path)
    h = filesize
    chunk_bytes = 65536
    with open(path, "rb") as f:
        for offset in (0, max(0, filesize - chunk_bytes)):
            f.seek(offset)
            for _ in range(chunk_bytes // bytesize):
                buf = f.read(bytesize)
                if len(buf) < bytesize:
                    break
                (val,) = struct.unpack(longlongformat, buf)
                h = (h + val) & 0xFFFFFFFFFFFFFFFF
    return "%016x" % h


def _request(method, path, api_key, user_agent, token=None, body=None):
    headers = {
        "Accept": "application/json",
        "Content-Type": "application/json",
        "Api-Key": api_key,
        "User-Agent": user_agent,
    }
    if token:
        headers["Authorization"] = f"Bearer {token}"
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(f"{BASE_URL}/{path}", data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        sys.stderr.write(f"HTTP {e.code} calling {path}: {e.read().decode('utf-8', 'replace')}\n")
        sys.exit(1)
    except urllib.error.URLError as e:
        sys.stderr.write(f"network error calling {path}: {e}\n")
        sys.exit(1)


def cmd_login():
    resp = _request(
        "POST", "login", os.environ["OST_API_KEY"], os.environ["OST_USER_AGENT"],
        body={"username": os.environ["OST_USERNAME"], "password": os.environ["OST_PASSWORD"]},
    )
    print(resp["token"])


def _best_feature_match(data):
    for item in data:
        fd = (item.get("attributes", {}) or {}).get("feature_details", {}) or {}
        imdb_id = fd.get("imdb_id")
        if imdb_id:
            return imdb_id, fd.get("title") or fd.get("movie_name") or "", fd.get("year") or ""
    return None


def cmd_identify_by_hash(moviehash_value):
    resp = _request(
        "GET", f"subtitles?moviehash={moviehash_value}&moviehash_match=only",
        os.environ["OST_API_KEY"], os.environ["OST_USER_AGENT"],
    )
    match = _best_feature_match(resp.get("data", []))
    if match:
        imdb_id, title, year = match
        print(f"tt{int(imdb_id):07d}\t{title}\t{year}")


def _best_forced_match(data):
    for item in data:
        attrs = item.get("attributes", {}) or {}
        if not attrs.get("foreign_parts_only"):
            continue
        files = attrs.get("files") or []
        if not files:
            continue
        return files[0].get("file_id"), attrs.get("release") or "", attrs.get("language") or ""
    return None


def cmd_find_forced_by_hash(moviehash_value):
    resp = _request(
        "GET",
        f"subtitles?moviehash={moviehash_value}&moviehash_match=only&languages=en&foreign_parts_only=include",
        os.environ["OST_API_KEY"], os.environ["OST_USER_AGENT"],
    )
    match = _best_forced_match(resp.get("data", []))
    if match:
        file_id, release, language = match
        print(f"{file_id}\t{release}\t{language}")


def cmd_find_forced_by_imdb(imdb_numeric):
    resp = _request(
        "GET", f"subtitles?imdb_id={imdb_numeric}&languages=en&foreign_parts_only=include",
        os.environ["OST_API_KEY"], os.environ["OST_USER_AGENT"],
    )
    match = _best_forced_match(resp.get("data", []))
    if match:
        file_id, release, language = match
        print(f"{file_id}\t{release}\t{language}")


def _normalize_for_title_match(s):
    s = s.lower()
    s = re.sub(r"[^a-z0-9]+", " ", s)
    return " ".join(s.split())


def cmd_search_by_title(title, year=""):
    # Stage 1 of identify's title-search fallback (used only once the
    # hash match and the curated known_films.yaml filename match have
    # both failed): search OpenSubtitles' movie/feature database - not
    # subtitle search - directly by title. Deliberately EXACT-match only,
    # no substring/fuzzy logic, and never guesses: requires feature_type
    # "Movie" (excludes TV episodes, clip shows, fan videos that the raw
    # API response otherwise mixes in - confirmed against a real "Moana"
    # query, which also returned an unrelated song video mislabeled as a
    # Movie), an exact normalized title match, and - when a year was
    # extracted from the filename - an exact year match too. With no year
    # to disambiguate, more than one exact-title Movie match is treated
    # as ambiguous and nothing is printed, exactly like the existing
    # curated-list filename fallback's own multi-year collision handling.
    query = urllib.parse.quote(title)
    path = f"features?query={query}"
    if year:
        path += f"&year={urllib.parse.quote(str(year))}"
    resp = _request("GET", path, os.environ["OST_API_KEY"], os.environ["OST_USER_AGENT"])
    target = _normalize_for_title_match(title)
    candidates = []
    for item in resp.get("data", []):
        attrs = item.get("attributes", {}) or {}
        if attrs.get("feature_type") != "Movie":
            continue
        imdb_id = attrs.get("imdb_id")
        if not imdb_id:
            continue
        api_title = attrs.get("title") or ""
        if _normalize_for_title_match(api_title) != target:
            continue
        api_year = str(attrs.get("year") or "")
        if year and api_year != str(year):
            continue
        candidates.append((imdb_id, api_title, api_year))
    if len(candidates) == 1:
        imdb_id, api_title, api_year = candidates[0]
        print(f"tt{int(imdb_id):07d}\t{api_title}\t{api_year}")


def cmd_download(file_id, output_path):
    resp = _request(
        "POST", "download", os.environ["OST_API_KEY"], os.environ["OST_USER_AGENT"],
        token=os.environ["OST_TOKEN"], body={"file_id": int(file_id)},
    )
    link = resp.get("link")
    if not link:
        sys.stderr.write(f"download response had no link: {resp}\n")
        sys.exit(1)
    req = urllib.request.Request(link, headers={"User-Agent": os.environ["OST_USER_AGENT"]})
    with urllib.request.urlopen(req, timeout=60) as sub_resp, open(output_path, "wb") as out:
        out.write(sub_resp.read())
    print(f"{resp.get('remaining', '')}\t{resp.get('message', '')}")


def main():
    if len(sys.argv) < 2:
        sys.stderr.write(__doc__)
        sys.exit(2)
    cmd, args = sys.argv[1], sys.argv[2:]
    if cmd == "hash":
        print(moviehash(args[0]))
    elif cmd == "login":
        cmd_login()
    elif cmd == "identify_by_hash":
        cmd_identify_by_hash(args[0])
    elif cmd == "find_forced_by_hash":
        cmd_find_forced_by_hash(args[0])
    elif cmd == "find_forced_by_imdb":
        cmd_find_forced_by_imdb(args[0])
    elif cmd == "download":
        cmd_download(args[0], args[1])
    else:
        sys.stderr.write(f"unknown command: {cmd}\n")
        sys.exit(2)


if __name__ == "__main__":
    main()
