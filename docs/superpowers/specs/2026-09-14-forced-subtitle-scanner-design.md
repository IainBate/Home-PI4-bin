# Forced-subtitle scanner + fetcher — design

## Purpose

`/mnt/HDD/films` on the Home Pi4 contains films that should carry a
*forced* subtitle track (covering foreign-language/alien-language dialogue
in an otherwise-English film, e.g. Huttese in Star Wars, Elvish in LOTR) but
don't. This adds a script to:

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
  - `forced_subs scan` — Phase 1, read-only.
  - `forced_subs apply [--max-downloads N] [--quiet]` — Phase 2.
  - Both source shared logic from the same file (film-identification,
    bucketing) so `apply` always re-derives its candidate set fresh from
    `scan`'s logic rather than trusting stale state.
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

## Phase 1: `scan`

- Walks `/mnt/HDD/films`, pruning the `Our Family` directory entirely
  (home videos, not in scope).
- For each video file, runs the **existing** `convert_video --analyze-subs
  <file>` (no new ffprobe logic) to get `FORCED=0|1`, `COVERAGE=<pct>`,
  `EXTERNAL_SRT=0|1`.
- Identifies the film: normalizes filename + parent folder (strips
  extension, resolution/codec tags — **year is extracted separately, not
  discarded**: a 4-digit `19xx`/`20xx` token, typically in parentheses or
  after a dash, e.g. `Moana - 2026` or `Moana (2026)`) and matches the
  remaining title text against `forced_subs_known_films.yaml`
  titles/aliases (case-insensitive substring/word-overlap — no
  fuzzy-matching library, keeps this dependency-free like the rest of the
  repo).
  - If exactly one curated entry matches the title, use it (year in the
    filename, if present, is a sanity check only — most of the library
    won't have a year tag at all, e.g. `Star Wars/Phantom Menace.mp4`).
  - If **more than one** curated entry shares that title (e.g. Moana
    (2016) and Moana (2026) are two separate entries, same title,
    different `year`/`imdb_id`) — this is the Moana case — the filename's
    extracted year is *required* to disambiguate. Matches the one entry
    whose `year` agrees. If the filename has no year token, or the year
    doesn't match any candidate, this is **not guessed**: bucketed as
    `NEEDS_FORCED_UNKNOWN` with reason `ambiguous_title_multiple_years`,
    so it surfaces for manual review rather than risking the wrong film's
    subtitle being muxed in.
  - Edition (for a single matched film) picked by comparing the file's
    actual ffprobe duration against the matched entry's
    `editions[].runtime_minutes`.
- Buckets each file:
  - `HAS_FORCED` — `FORCED=1` with `COVERAGE>=15` (matches convert_video's
    existing threshold for "this is real forced-sub content, not a
    mislabeled full track"), or `EXTERNAL_SRT=1`.
  - `NEEDS_FORCED_KNOWN` — no forced subs, film matched in the curated
    list. This is `apply`'s candidate set.
  - `NEEDS_FORCED_UNKNOWN` — no forced subs, film not on the curated list.
    Reported only; never touched by `apply`.
- Output: printed to stdout and appended to
  `/home/pi/logs/forced_subs_scan_logfile`, one line per file:
  `<bucket>\t<path>\t<matched_title>\t<matched_edition>\t<coverage>\t<external_srt>`.

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
  2. Otherwise, search OpenSubtitles: **primary** strategy is
     moviehash-based lookup (the standard mechanism subtitle tools use for
     exact-release matching — matches subtitles uploaded against files
     with the identical hash, so it's edition-exact when a match exists).
     **Fallback**: IMDb ID + `languages=en` + forced/foreign-parts-only
     filter, sanity-checked against the matched edition's expected
     runtime. If still ambiguous, log to the unavailable cache with
     reason `ambiguous` rather than guessing — a mistimed subtitle is
     worse than no subtitle.
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
`films_backup` conventions: logs under `/home/pi/logs`, `--quiet` for cron,
a new daily cron entry for `forced_subs apply --quiet` in `crontab.txt`
(and `fresh_install.sh` updated per its existing pattern for new services).

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
