# Forced-subtitle scanner + fetcher — design

## Purpose

`/mnt/HDD/films` on the Home Pi4 contains films that should carry a
*forced* subtitle track (covering foreign-language/alien-language dialogue
in an otherwise-English film, e.g. Huttese in Star Wars, Elvish in LOTR) but
don't. This adds a script to:

0. **Identify** each file with a unique reference (IMDb ID), cached, so
   later phases work off exact identity instead of fuzzy filename
   guessing.
1. **Scan** the tree and report, per file, whether it already has forced
   subs, is missing them but is a film we're confident needs them, or is
   missing them and we don't know.
2. **Apply**: for the confident-missing set, fetch a matching forced-English
   SRT from OpenSubtitles.com and remux it into the file (stream copy, no
   re-encode), a few files at a time per day to stay within API limits.

## Explicit non-goals

- No sourcing of replacement video files from piracy sites (ruled out
  earlier in this project's discussion — copyright infringement).
- No automatic judgement of "does this obscure film need forced subs" —
  that call is only made for films on a curated, human-reviewed list. Files
  not on the list are reported, never acted on.
- No second subtitle source/scraper for now (see "Subtitle source" below).

## Components

- **`forced_subs`** — new script in repo root. Subcommands:
  - `forced_subs identify [--rehash] [--set <path> <imdb_id>]` — Phase 0,
    read-only except for its own cache file (see below).
  - `forced_subs scan` — Phase 1, read-only.
  - `forced_subs apply [--max-downloads N] [--quiet]` — Phase 2.
  - `forced_subs report [--verbose]` — human-facing summary (see
    "Reporting" below): added-by-script vs. still-needs-manual-attention.
  - All source shared logic from the same file (identity lookup, bucketing)
    so `scan`/`apply`/`report` always re-derive their candidate sets fresh
    from current file state and the identity cache rather than trusting
    separately-stored state.
- **`forced_subs_file_ids`** (`/home/pi/logs/forced_subs_file_ids`) — the
  identity cache Phase 0 writes and every later phase reads. One row per
  file: `path`, `imdb_id`, `title`, `year`, `confidence`
  (`hash`/`filename`/`manual`/`unresolved`), `last_checked`. Persistent,
  not a log-and-forget file — it's the ground truth for "which film is
  this," and a `manual` entry (set via `--set`, e.g. once you've eyeballed
  an ambiguous Moana file yourself) is never overwritten by a later
  `identify` run.
- **`forced_subs_known_films.yaml`** — curated list, committed to git.
  Schema per entry — note `year` is required and identifies a distinct
  *film*, not an edition: two films can share a title (e.g. Moana (2016)
  animated vs. Moana (2026) live-action remake are two different `imdb_id`s
  and two separate entries), whereas `editions` is for cuts of the *same*
  film (theatrical vs. director's cut share one `imdb_id`/`year`).
  ```yaml
  - title: "Star Wars: Episode I - The Phantom Menace"
    aliases: ["Phantom Menace", "Episode I"]
    year: 1999
    imdb_id: "tt0120915"
    editions:
      - name: theatrical
        runtime_minutes: 133
      - name: 2011_bluray
        runtime_minutes: 136
  - title: "Moana"
    aliases: []
    year: 2016
    imdb_id: "tt3521164"
    editions:
      - name: theatrical
        runtime_minutes: 107
  - title: "Moana"
    aliases: []
    year: 2026
    imdb_id: "tt0000000"  # filled in for real during implementation
    editions:
      - name: theatrical
        runtime_minutes: 0  # filled in for real during implementation
  ```
  Seeded initially with franchises I'm confident about (Star Wars saga,
  LOTR trilogy, and similar — to be filled in during implementation).
  Grows over time as `scan`'s `NEEDS_FORCED_UNKNOWN` bucket gets manually
  reviewed and confirmed entries get added.
- **Secrets mechanism** — ported from `~/home_automation` on the Pi
  (`scripts/lib/secrets_common.sh`, `scripts/encrypt_secrets.sh`,
  `scripts/decrypt_secrets.sh`), same design: `secrets.yaml` (gitignored
  plaintext), `secrets.yaml.enc` (committed, AES-256-CBC/PBKDF2, keyed by
  SHA-256 hash of a passphrase — recommended: the Pi's login password),
  `secrets.yaml.example` (committed template). Holds:
  ```yaml
  opensubtitles:
    api_key: "..."
    username: "iainbate"
    password: "..."
  secrets_backup:
    passphrase_hash: "..."
  ```
- **`.gitignore`** (new — repo has none today) — must list `secrets.yaml`
  before this work merges, or the plaintext credential file risks being
  committed.

## Phase 0: `identify`

Walks `/mnt/HDD/films`, pruning `Our Family`, and for each video file not
already in `forced_subs_file_ids` (or all files, with `--rehash`),
resolves a unique reference — an IMDb ID — and caches it:

1. **Primary: hash lookup.** Computes the file's OpenSubtitles moviehash +
   size and queries OpenSubtitles' hash-based search. When it returns a
   match, the result carries the *actual* film's metadata (imdb_id, title,
   year) for that exact release — independent of filename, and this is
   what resolves same-title-different-film cases (e.g. Moana (2016) vs.
   Moana (2026)) reliably, since the hash is specific to one exact file.
   Recorded with `confidence=hash`.
2. **Fallback: filename/folder matching.** If no hash match (nobody's
   uploaded subs against that exact release), normalizes filename + parent
   folder (strips extension, resolution/codec tags — **year is extracted
   separately, not discarded**: a 4-digit `19xx`/`20xx` token, typically in
   parentheses or after a dash) and matches the remaining title text
   against `forced_subs_known_films.yaml` titles/aliases. If exactly one
   curated entry matches the title, use it (`confidence=filename`); if
   more than one curated entry shares that title, the filename's extracted
   year is required to disambiguate, and if it's absent or doesn't match
   any candidate, **this is not guessed** — recorded as
   `confidence=unresolved`, reason `ambiguous_title_multiple_years`.
   Anything with no title match at all is also `unresolved`, reason
   `no_match`.
3. **Manual override.** `forced_subs identify --set <path> <imdb_id>` lets
   you resolve any `unresolved` (or wrong) entry by hand — e.g. after
   eyeballing which Moana is which yourself. Sticky: never overwritten by
   a later plain `identify` run.

This uses OpenSubtitles *search* calls only (no downloads), which share a
much more generous quota than `apply`'s download budget — see "Subtitle
source" below — so `identify` doesn't need day-by-day rate limiting the
way `apply` does; it can process the whole backlog in one run, and after
that only has new/uncached files left to do.

## Phase 1: `scan`

- Walks `/mnt/HDD/films`, pruning `Our Family`, same as `identify`.
- For each video file, runs the **existing** `convert_video --analyze-subs
  <file>` (no new ffprobe logic) to get `FORCED=0|1`, `COVERAGE=<pct>`,
  `EXTERNAL_SRT=0|1`.
- Looks up the file's `imdb_id` in `forced_subs_file_ids` (running
  `identify`'s per-file logic inline if the cache has no entry yet for
  it). If still `unresolved`, buckets straight to `NEEDS_FORCED_UNKNOWN`
  (reason from the identity cache, e.g. `ambiguous_title_multiple_years`
  or `no_match`) — no further matching logic needed here, since
  disambiguation is entirely `identify`'s job now.
- Otherwise, looks the `imdb_id` up directly in
  `forced_subs_known_films.yaml` (an exact key lookup, not fuzzy matching
  — ambiguity was already resolved in Phase 0). Edition (if the entry has
  more than one) picked by comparing the file's actual ffprobe duration
  against `editions[].runtime_minutes`.
- Buckets each file:
  - `HAS_FORCED` — `FORCED=1` with `COVERAGE>=15` (matches convert_video's
    existing threshold for "this is real forced-sub content, not a
    mislabeled full track"), or `EXTERNAL_SRT=1`.
  - `NEEDS_FORCED_KNOWN` — no forced subs, `imdb_id` matched in the
    curated list. This is `apply`'s candidate set.
  - `NEEDS_FORCED_UNKNOWN` — no forced subs, and either the film is
    unidentified or its `imdb_id` isn't on the curated list yet. Reported
    only; never touched by `apply`.
- Output: printed to stdout and appended to
  `/home/pi/logs/forced_subs_scan_logfile`, one line per file:
  `<bucket>\t<path>\t<imdb_id>\t<matched_title>\t<matched_edition>\t<coverage>\t<external_srt>`.

### Incremental scanning

The library is scanned repeatedly (weekly `identify`, daily `apply`, and
`scan`/`report` run by hand) indefinitely, potentially over years, so
`scan` must not pay the cost of re-probing every file on every run forever.
A second cache, `forced_subs_scan_cache` (path, file size, mtime, and the
full bucketing result), lets `scan` skip re-running `convert_video
--analyze-subs` (and the identity/known-films lookups) for a file when
**both** are true: the file's size+mtime are unchanged since the cache row
was written, **and** that row's bucket was `HAS_FORCED` — a settled,
unlikely-to-regress state. Anything still `NEEDS_FORCED_*` is always
re-checked (cheap relative to the whole library, and necessary: its state
can change between runs, e.g. once `apply` fixes it). Because a successful
`apply` remux changes the file's mtime, a file that was `NEEDS_FORCED_KNOWN`
yesterday and got fixed overnight is automatically re-evaluated (cache
signature no longer matches) and picked up as `HAS_FORCED` on the next
`scan` — no explicit invalidation logic needed. Replacing a file on disk
(new rip, re-encode) is likewise caught by the same size/mtime check.

## Phase 2: `apply`

- Re-runs `scan`'s bucketing logic to get the current `NEEDS_FORCED_KNOWN`
  set (always derived fresh from the files themselves — no separate
  manifest to go stale or get corrupted).
- Skips any file present in a small "unavailable" cache
  (`/home/pi/logs/forced_subs_unavailable_cache`: `path`, `last_checked`,
  `reason`) checked within the last 7 days, so a confirmed-no-match search
  isn't repeated daily.
- Processes candidates in deterministic order (sorted by path), stopping
  once `--max-downloads` files have been **successfully** downloaded+muxed
  (default conservative, e.g. 5 — to be confirmed/tuned against the actual
  OpenSubtitles free-tier daily quota once the account is live). Failed
  searches don't count against this budget, only successful downloads do,
  since search quota is separate and much more generous than download
  quota.
- Per candidate:
  1. If `EXTERNAL_SRT=1` already (a sidecar `.srt` sits next to the file),
     skip searching entirely and mux that file directly.
  2. Otherwise, search OpenSubtitles: **primary** strategy is the same
     moviehash-based lookup `identify` already used (reuses that hash
     rather than recomputing it — matches subtitles uploaded against files
     with the identical hash, so it's edition-exact when a match exists).
     **Fallback**: the file's cached `imdb_id` + `languages=en` +
     forced/foreign-parts-only filter, sanity-checked against the matched
     edition's expected runtime. If still ambiguous, log to the
     unavailable cache with reason `ambiguous` rather than guessing — a
     mistimed subtitle is worse than no subtitle.
  3. Download the matched SRT (requires the JWT from `/login`).
  4. Remux via ffmpeg to a temp file: `-map 0:v -map 0:a -map 1:s -c:v
     copy -c:a copy`, subtitle codec `mov_text` for `.mp4`/`.m4v`
     containers or native `srt` for `.mkv`, `-disposition:s:0 forced`,
     `-metadata:s:s:0 language=eng`.
  5. Verify the temp file with ffprobe (duration matches original, forced
     subtitle stream present and correctly flagged).
  6. Atomically `mv` the verified temp file over the original path. The
     original is never deleted until the replacement is confirmed valid;
     no separate `.bak` copy is retained (per your answer on the replace-
     safety question).
- Every attempt (success/fail/unavailable) is logged to
  `/home/pi/logs/forced_subs_apply_logfile`.

## Reporting

A third subcommand, **`forced_subs report`**, produces the human-facing
summary — the thing you actually read, as opposed to the append-only logs
`scan`/`apply` write for their own bookkeeping. It combines a fresh `scan`
with the cumulative contents of `forced_subs_apply_logfile` and prints
three clearly separated sections:

1. **Already fine** — had forced subs before this project touched
   anything (`HAS_FORCED`, and not present in the apply log's success
   entries). Just a count by default; full list with `--verbose`.
2. **Added by this script** — every file `apply` has successfully
   remuxed, ever (from the apply log's success entries), so you can see
   what changed without diffing the filesystem yourself.
3. **You'll need to sort these out yourself** — everything still missing
   forced subs after the above: `NEEDS_FORCED_KNOWN` entries that stayed
   unresolved (unavailable/ambiguous after search) plus every
   `NEEDS_FORCED_UNKNOWN` entry (title not on the curated list at all).
   Each line says why (`unresolved: no_match`,
   `unresolved: ambiguous_title_multiple_years`, `not_on_known_list`,
   `no_match_found`, `ambiguous`, etc.) so it's clear whether the fix is
   "identify this file manually via `forced_subs identify --set`," "add
   this `imdb_id` to the curated list," or "no forced-sub release exists
   on OpenSubtitles for this one — find/download manually."

This is the output you'd actually run and read after a batch of daily
`apply` runs has had time to work through the backlog.

`report` writes this same output to a file at the **top level of the films
tree itself** — `/mnt/HDD/films/_FORCED_SUBTITLES_REPORT.txt` — in addition
to stdout, so it's visible just by browsing the share (a leading `_` sorts
it above the film folders in most file browsers), not only from a shell on
the Pi. Overwritten on each `report` run, not appended.

## Subtitle source

OpenSubtitles.com REST API only. It's the sole major subtitle site with an
official, ToS-compliant API — Subscene/YIFY Subtitles/Addic7ed have none,
and scraping them isn't something to automate. If the unavailable-cache log
later shows OpenSubtitles systematically missing titles, adding a second
source becomes a separate, later decision — not built now (YAGNI).

Auth: API key (`Api-Key` header, from the registered "consumer") plus
username/password login for a JWT (raises the download quota above the
anonymous tier and is required for `/download`).

## Deployment

Runs on the Pi (not the Mac) via SSH/cron, matching `convert_video`/
`films_backup` conventions: logs/cache under `/home/pi/logs`, `--quiet`
for cron, new cron entries in `crontab.txt` (and `fresh_install.sh`
updated per its existing pattern for new services):
- `forced_subs identify --quiet` — weekly (new films arrive rarely; this
  just needs to pick up whatever's been added since last time — already-
  cached files are skipped).
- `forced_subs apply --quiet` — daily, per the rate-limited design above.
- `forced_subs identify --quiet` also runs `@reboot` (the Pi reboots
  weekly via its own separate cron job). `identify` caches each file's
  result as it goes and skips anything already resolved, so it's always
  safe to interrupt and re-run — this just means a reboot mid-run resumes
  automatically on the next boot instead of waiting for next Sunday. No
  separate watchdog/process-monitoring is needed: cron re-firing on
  schedule (daily/weekly/on reboot) already is the retry mechanism.

Initial run of `identify` against the whole existing library is done
manually (not via cron) so any `unresolved` results can be reviewed and
fixed with `--set` before `apply` starts relying on the cache.

## Testing

Bash tests under `tests/`, using the existing dependency-free
`test_helpers.sh` (no new test framework). Follows
`test_convert_video_analyze_subs.sh`'s pattern of building small synthetic
ffmpeg fixtures. OpenSubtitles API calls are mocked/stubbed in `apply`-phase
tests (no live network calls in the test suite) — exact stubbing mechanism
(e.g. an overridable curl wrapper) is an implementation-plan detail, not
fixed here.

## Open items for the implementation plan to resolve

- Exact initial contents of `forced_subs_known_films.yaml` (which
  franchises/titles to seed).
- Exact OpenSubtitles free-tier daily download quota, once the account is
  live, to tune `--max-downloads`' default.
- Exact mechanism for stubbing OpenSubtitles HTTP calls in tests.
