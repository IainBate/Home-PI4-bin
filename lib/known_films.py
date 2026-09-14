#!/usr/bin/env python3
"""Reader for forced_subs_known_films.yaml's flat, line-oriented format.

See the module docstring in the spec (docs/superpowers/specs/2026-09-14-
forced-subtitle-scanner-design.md, "Components") for the exact schema.
Not a general YAML parser by design - the shape is fixed and simple.

Usage:
  known_films.py lookup <yaml_path> <imdb_id>
  known_films.py find_by_title_year <yaml_path> <normalized_title> <year_or_empty>
"""
import re
import sys


def _unquote(value):
    value = value.strip()
    if len(value) >= 2 and value[0] == '"' and value[-1] == '"':
        return value[1:-1]
    return value


def _parse_records(yaml_path):
    records = []
    current = None
    with open(yaml_path) as f:
        for raw_line in f:
            line = raw_line.rstrip("\n")
            m = re.match(r'^\s*-\s*title:\s*(.*)$', line)
            if m:
                if current:
                    records.append(current)
                current = {"title": _unquote(m.group(1))}
                continue
            if current is None:
                continue
            m = re.match(r'^\s+([a-z_]+):\s*(.*)$', line)
            if m:
                current[m.group(1)] = _unquote(m.group(2))
    if current:
        records.append(current)
    return records


def _normalize(text):
    return re.sub(r'[^a-z0-9]+', ' ', text.lower()).strip()


def cmd_lookup(yaml_path, imdb_id):
    for rec in _parse_records(yaml_path):
        if rec.get("imdb_id") == imdb_id:
            print(f"{rec.get('title', '')}\t{rec.get('year', '')}\t{rec.get('editions', '')}")
            return
    sys.exit(1)


def cmd_find_by_title_year(yaml_path, normalized_title, year):
    target = _normalize(normalized_title)
    if not target:
        return
    candidates = []
    for rec in _parse_records(yaml_path):
        title_norm = _normalize(rec.get("title", ""))
        alias_norms = [_normalize(a) for a in rec.get("aliases", "").split("|") if a]
        if target == title_norm or target in alias_norms:
            candidates.append(rec)
    # Year only matters to disambiguate a genuine title collision (e.g. two
    # different Moana entries) - a single match is returned regardless of
    # whether the filename happened to carry a (possibly stale/absent) year.
    if len(candidates) > 1 and year:
        candidates = [r for r in candidates if r.get("year") == year]
    for rec in candidates:
        print(f"{rec.get('imdb_id', '')}\t{rec.get('title', '')}\t{rec.get('year', '')}")


def main():
    if len(sys.argv) < 3:
        sys.stderr.write(__doc__)
        sys.exit(2)
    cmd = sys.argv[1]
    if cmd == "lookup":
        cmd_lookup(sys.argv[2], sys.argv[3])
    elif cmd == "find_by_title_year":
        cmd_find_by_title_year(sys.argv[2], sys.argv[3], sys.argv[4] if len(sys.argv) > 4 else "")
    else:
        sys.stderr.write(f"unknown command: {cmd}\n")
        sys.exit(2)


if __name__ == "__main__":
    main()
