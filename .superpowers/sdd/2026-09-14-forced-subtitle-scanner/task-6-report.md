# Task 6 Report: `forced_subs identify` subcommand

## What I implemented

- Created `forced_subs` (new file, executable): header/shared-setup block (env-var
  overrides, sourcing `lib/forced_subs_common.sh`, `load_opensubtitles_creds`,
  `opensubtitles_login`), the `identify` path (`forced_subs_identify_one`,
  `cmd_identify_set`, `cmd_identify`), and the `main()` dispatcher with the
  `identify` case plus a usage fallback for `scan|apply|report` (added in later
  tasks). Content matches the brief's Step 3 code block verbatim.
- Created `tests/test_forced_subs_identify.sh` (new file, executable), based
  verbatim on the brief's Step 1 code, with one deliberate fixture change (see
  "Issues" below).

## TDD evidence

### RED (Step 2 — before `forced_subs` existed)

Command:
```
bash tests/test_forced_subs_identify.sh
```
Output (excerpt):
```
== unambiguous filename match resolves via the fallback path ==
tests/test_forced_subs_identify.sh: line 53: /Users/ijb500/Home_PI4_bin/.claude/worktrees/forced-subs-scanner/forced_subs: No such file or directory
FAIL - Phantom Menace resolved to its imdb_id (expected [tt0120915], got [])
...
9 run, 8 failed
```
Failed for the expected reason: `forced_subs` did not exist yet.

### GREEN (Step 4 — after writing `forced_subs` and fixing the fixture, see below)

Command:
```
bash tests/test_forced_subs_identify.sh
```
Output:
```
== unambiguous filename match resolves via the fallback path ==
ok - Phantom Menace resolved to its imdb_id
ok - confidence is filename, not hash (fake ost.py returns no hash match)
== the Moana case: year in the filename disambiguates ==
ok - Moana - 2026 resolves to the 2026 entry
ok - Moana - 2016 resolves to the 2016 entry
== the Moana case: no year in the filename is left unresolved, not guessed ==
ok - ambiguous file has no imdb_id
ok - reason recorded as ambiguous
== --set manually resolves an ambiguous file and is sticky ==
ok - manually set imdb_id
ok - confidence is manual
ok - a later plain identify --rehash does not overwrite the manual entry

9 run, 0 failed
```
Exit code 0.

Full existing test suite re-run afterward, all green (no regressions):
`test_convert_season.sh` 71/71, `test_convert_video_analyze_subs.sh` 15/15,
`test_forced_subs_common.sh` 19/19, `test_known_films.sh` 7/7,
`test_ost_hash.sh` 5/5, `test_secrets_roundtrip.sh` 4/4.

## Files changed

- `/Users/ijb500/Home_PI4_bin/.claude/worktrees/forced-subs-scanner/forced_subs` (new, executable)
- `/Users/ijb500/Home_PI4_bin/.claude/worktrees/forced-subs-scanner/tests/test_forced_subs_identify.sh` (new, executable)

Commit: `04da5ae` "Add forced_subs identify subcommand"

## Issue found and fixed: one test-fixture deviation from the verbatim brief

The brief's Step 1 test used a fixture file named `Moana - Unknown Year.mp4`
to exercise the "no year in the filename, left ambiguous" path. Running it
against the (already-completed, already-reviewed) Task 3
`normalize_title_from_path` and Task 5 `find_by_title_year` revealed a real
integration gap, not a transcription error:

- `normalize_title_from_path` deliberately does **not** strip arbitrary
  trailing `- words` text glued with spaces on both sides of the dash — only
  digit years, quality/codec tags, and dash-glued suffixes with no space
  before the word (e.g. `x264-GROUP`). This is intentional, frozen Task-3
  behavior, confirmed by `tests/test_forced_subs_common.sh`'s own regression
  tests (the Star Wars film's real title legitimately contains
  `- The Phantom Menace`, so a generic "strip everything after ` - `" rule
  would break real titles).
- `find_by_title_year` in `known_films.py` matches by **exact** normalized
  title equality (or alias), by design (simple, dependency-free parser).
- Consequently `Moana - Unknown Year.mp4` normalizes to the literal string
  `"Moana - Unknown Year"`, which never equals `"Moana"`, so the fallback
  lookup returned zero candidates (`no_match`) instead of the two-way
  collision (`ambiguous_title_multiple_years"`) the test intended to exercise.

I verified this by hand: running `known_films.py find_by_title_year` directly
with `"Moana - Unknown Year"` returned nothing, while running it with
`"Moana"` returned both Moana records (the true ambiguous case). I also
diffed both `forced_subs` and the test against the brief's markdown to rule
out a copy/paste error — both were byte-for-byte verbatim transcriptions
(only the brief's own comment/fence lines differed, as expected).

Given `normalize_title_from_path` and `find_by_title_year` are out of this
task's scope (owned by already-reviewed Tasks 3 and 5) and `forced_subs`'s
own Step 3 code is specified verbatim with no title-cleanup logic to add
without going out of scope, I fixed this at the only place that was mine to
adjust and that didn't touch any interface or logic: the test fixture. I
renamed the ambiguous-file fixture from `Moana - Unknown Year.mp4` to
`Moana.mp4` (no dash-suffix, still no digit year) in
`tests/test_forced_subs_identify.sh`, updating the corresponding path
references in the later assertions and the `--set`/`--rehash` section. This
fixture actually reaches the ambiguous branch through the real (unmodified)
library code: `normalize_title_from_path` returns exactly `"Moana"`,
`extract_year_from_name` returns empty, and `find_by_title_year` returns
both 2016/2026 candidates since no year is available to filter on — count 2
→ `confidence=unresolved`, `reason=ambiguous_title_multiple_years`, exactly
as the test asserts. No other line of the test or of `forced_subs` was
changed from the brief's verbatim text.

## Self-review findings

- Moana disambiguation now passes for the real reason (verified via the
  fixture fix above and a raw `known_films.py` invocation), not by
  accident.
- `--set` and `--rehash` both exercised and pass: `--set` writes a
  `manual`-confidence row and is sticky against a later `--rehash`, per the
  test's last two assertions.
- All seven env-var overrides named in the brief are wired in `forced_subs`,
  even though most aren't consumed elsewhere until later tasks:
  `FORCED_SUBS_LIBDIR`→`LIBDIR`, `FORCED_SUBS_KNOWN_FILMS`→`KNOWN_FILMS_YAML`,
  `FID_CACHE`, `FORCED_SUBS_FILMS_ROOT`→`FILMS_ROOT`,
  `FORCED_SUBS_CONVERT_VIDEO`→`CONVERT_VIDEO`,
  `FORCED_SUBS_REPORT_FILE`→`REPORT_FILE`, `SCAN_CACHE` (exported alongside
  `FID_CACHE`/`UNAVAILABLE_CACHE`).
- `shellcheck -x forced_subs` reports only two SC2034 "appears unused"
  warnings for `CONVERT_VIDEO` and `REPORT_FILE` — expected and by design,
  since those are consumed starting Task 7/9 respectively; no other
  warnings.
- Diffed both new files against the brief's markdown to confirm nothing
  beyond the one documented fixture-name deviation was added or changed.
- Ran the full existing test suite (`test_convert_season.sh`,
  `test_convert_video_analyze_subs.sh`, `test_forced_subs_common.sh`,
  `test_known_films.sh`, `test_ost_hash.sh`, `test_secrets_roundtrip.sh`) —
  all still green, no regressions from adding `forced_subs`.

## Concerns for follow-up (not blocking, not in this task's scope)

- The test run prints benign stderr noise on this dev machine:
  `forced_subs: line 54: /home/pi/logs/forced_subs_scan_logfile: No such
  file or directory`. This comes from `identify_by_hash`'s
  `2>>"${SCAN_LOG:-/dev/null}"` redirect — `SCAN_LOG` isn't among the
  brief's listed test-override env vars, so it defaults to the Pi-only path
  `/home/pi/logs/forced_subs_scan_logfile`, which doesn't exist locally.
  This doesn't affect exit codes or assertions and matches the brief's
  verbatim code exactly (`SCAN_LOG` isn't in the brief's env-override list,
  unlike `FID_CACHE`/`SCAN_CACHE`/etc.), so I left it as specified — flagging
  it in case a later task wants a `FORCED_SUBS_SCAN_LOG`-style override for
  quieter local test runs.
- The upstream plan brief's test fixture (`Moana - Unknown Year.mp4`) should
  probably be corrected in the source plan document too, since any future
  re-generation of this test from the plan would reproduce the same latent
  failure against the frozen Task 3/5 libraries.

## Code review fix applied

**Finding:** The `forced_subs_identify_one` function's stderr redirect on line 54
uses `2>>"${SCAN_LOG:-/dev/null}"`, which cannot fall back to `/dev/null` because
`SCAN_LOG` is unconditionally assigned at line 17, causing spurious
"No such file or directory" errors on dev machines where `/home/pi/logs/` doesn't exist.

**Fix applied:** Changed `2>>"${SCAN_LOG:-/dev/null}"` to `2>/dev/null` on line 54.
The intent is to suppress `ost.py` diagnostic noise, not to log it, so the redirect
should be unconditional.

**Test results:**

```
bash tests/test_forced_subs_identify.sh
== unambiguous filename match resolves via the fallback path ==
ok - Phantom Menace resolved to its imdb_id
ok - confidence is filename, not hash (fake ost.py returns no hash match)
== the Moana case: year in the filename disambiguates ==
ok - Moana - 2026 resolves to the 2026 entry
ok - Moana - 2016 resolves to the 2016 entry
== the Moana case: no year in the filename is left unresolved, not guessed ==
ok - ambiguous file has no imdb_id
ok - reason recorded as ambiguous
== --set manually resolves an ambiguous file and is sticky ==
ok - manually set imdb_id
ok - confidence is manual
ok - a later plain identify --rehash does not overwrite the manual entry

9 run, 0 failed
```

Full test suite (all pristine, no stderr noise):
- `test_forced_subs_common.sh`: 19 run, 0 failed
- `test_known_films.sh`: 7 run, 0 failed
- `test_ost_hash.sh`: 5 run, 0 failed
- `test_secrets_roundtrip.sh`: 4 run, 0 failed
- `test_convert_video_analyze_subs.sh`: 15 run, 0 failed
- `test_convert_season.sh`: 71 run, 0 failed

**Commit:** 5b361be (auto-committed during fix application)
