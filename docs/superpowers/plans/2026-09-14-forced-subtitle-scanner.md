# Forced-Subtitle Scanner + Fetcher Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `forced_subs` (identify/scan/apply/report) to Home_PI4_bin so `/mnt/HDD/films` can be scanned for missing forced-English subtitles, matched to films via a curated list + OpenSubtitles hash lookup, and fixed automatically within a daily API budget.

**Architecture:** A bash script (`forced_subs`, matching the repo's existing style) drives four subcommands, backed by two small Python 3 stdlib-only helpers (`lib/ost.py` for OpenSubtitles REST calls + the moviehash algorithm, `lib/known_films.py` for reading the curated films list) — Python is used only where bash is a poor fit (64-bit hashing, JSON), never as a general scripting layer, and is already a hard dependency of `home_automation` on this same Pi. A ported `secrets.yaml.enc` mechanism holds OpenSubtitles credentials.

**Tech Stack:** bash, python3 (stdlib only: `json`, `struct`, `urllib.request` — no pip packages), ffmpeg/ffprobe (already a dependency via `convert_video`), openssl (already used by the ported secrets mechanism).

**Spec:** `docs/superpowers/specs/2026-09-14-forced-subtitle-scanner-design.md`

## Global Constraints

- No sourcing of replacement video files from piracy sites (spec: "Explicit non-goals").
- No automatic "does this film need forced subs" judgement outside the curated `forced_subs_known_films.yaml` list — anything not on it is reported only, never touched by `apply` (spec: "Explicit non-goals", "Phase 1: scan").
- OpenSubtitles.com REST API only; no second/scraped subtitle source (spec: "Subtitle source").
- `secrets.yaml` must never be committed in plaintext — `.gitignore` must exist and list it before this work merges (spec: "Components").
- Runs on the Home Pi4 via SSH/cron, not the Mac (spec: "Deployment").
- Tests are dependency-free bash using the existing `tests/test_helpers.sh` (no new test framework), following `tests/test_convert_video_analyze_subs.sh`'s synthetic-fixture style; OpenSubtitles HTTP calls are stubbed, never live, in tests (spec: "Testing").
- `Phase 2: apply` never deletes the original file until the remuxed replacement is verified valid; no `.bak` copy is retained (spec: "Phase 2: apply", step 6).
- OpenSubtitles REST API details below were verified against the API's own Python client source (`github.com/dusking/opensubtitles-com`, files `opensubtitles.py`/`responses.py`) and corroborating docs during planning, not recalled from memory:
  - Base URL: `https://api.opensubtitles.com/api/v1`.
  - Every call needs headers `Api-Key: <key>` and `User-Agent: <app string>`; authenticated calls (`/download`) also need `Authorization: Bearer <token>`.
  - `POST /login` body `{"username":..., "password":...}` → response has `.token` and `.user.allowed_downloads`.
  - `GET /subtitles?...` accepts `moviehash`, `moviehash_match` (`include`/`only`), `imdb_id` (numeric, no `tt` prefix), `languages`, `foreign_parts_only` (`exclude`/`include` — **not** `only`; you must filter the returned items client-side on each item's own `attributes.foreign_parts_only` boolean to actually restrict to forced subs). Each result item: `.attributes.feature_details.{imdb_id,title,year}`, `.attributes.files[0].file_id`, `.attributes.release`, `.attributes.foreign_parts_only`.
  - `POST /download` body `{"file_id": <int>}` → response `.link` (temporary URL to fetch), `.remaining`, `.message`.

---

### Task 1: Repo scaffolding — `.gitignore` and secrets template

**Files:**
- Create: `.gitignore`
- Create: `secrets.yaml.example`
- Create: `lib/` (directory, via the first file placed in it in Task 3)

**Interfaces:**
- Produces: a `secrets.yaml.example` documenting the exact keys later tasks read (`opensubtitles.api_key`, `opensubtitles.username`, `opensubtitles.password`, `secrets_backup.passphrase_hash`).

- [ ] **Step 1: Create `.gitignore`**

```gitignore
secrets.yaml
```

- [ ] **Step 2: Create `secrets.yaml.example`**

```yaml
opensubtitles:
  api_key: "your-opensubtitles-api-key"
  username: "your-opensubtitles-username"
  password: "your-opensubtitles-password"
secrets_backup:
  passphrase_hash: ""
```

- [ ] **Step 3: Verify `secrets.yaml` really is ignored**

Run: `cd /Users/ijb500/Home_PI4_bin && touch secrets.yaml && git status --porcelain secrets.yaml`
Expected: no output (file not tracked/listed). Then `rm secrets.yaml` (nothing real in it yet).

- [ ] **Step 4: Commit**

```bash
git add .gitignore secrets.yaml.example
git commit -m "Add .gitignore and secrets.yaml.example for forced_subs work"
```

---

### Task 2: Port the secrets encrypt/decrypt mechanism

Ports `~/home_automation`'s `secrets.yaml.enc` mechanism (fetched from the Pi during brainstorming) into this repo, with one deliberate simplification: the original's `read_configured_passphrase_hash` shells out to `python3 -c "import yaml..."`, which needs `pyyaml`. This repo has no Python dependency at all today, and `secrets.yaml` here only ever needs simple two-level `key: value` reads, so this port replaces that one function with a small `awk` reader instead — same behavior, zero new dependency. Everything else (the SHA-256-hashed-passphrase design, the verified-round-trip-before-overwrite safety check, the `--quiet` cron contract) is ported as-is.

**Files:**
- Create: `scripts/lib/secrets_common.sh`
- Create: `scripts/encrypt_secrets.sh`
- Create: `scripts/decrypt_secrets.sh`
- Test: `tests/test_secrets_roundtrip.sh`

**Interfaces:**
- Produces: `secrets_openssl` (bash function, args: `-e|-d -in <path> -out <path>`), `sha256_hex` (bash function, reads stdin, prints hex), `read_configured_passphrase_hash` (bash function, prints the hash from `secrets.yaml` or nothing).

- [ ] **Step 1: Write the failing test**

```bash
# tests/test_secrets_roundtrip.sh
#!/bin/bash
set -uo pipefail
cd "$(dirname "$0")"
source test_helpers.sh

REPO_ROOT="$(cd .. && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cp "$REPO_ROOT/scripts/encrypt_secrets.sh" "$REPO_ROOT/scripts/decrypt_secrets.sh" "$WORK/"
mkdir -p "$WORK/lib"
cp "$REPO_ROOT/scripts/lib/secrets_common.sh" "$WORK/lib/"
mkdir -p "$WORK/scripts/lib"
cp "$REPO_ROOT/scripts/lib/secrets_common.sh" "$WORK/scripts/lib/"
mv "$WORK/encrypt_secrets.sh" "$WORK/decrypt_secrets.sh" "$WORK/scripts/" 2>/dev/null || {
    mkdir -p "$WORK/scripts"
    cp "$REPO_ROOT/scripts/encrypt_secrets.sh" "$REPO_ROOT/scripts/decrypt_secrets.sh" "$WORK/scripts/"
}

cd "$WORK"
cat > secrets.yaml <<'EOF'
opensubtitles:
  api_key: "test-key-123"
  username: "tester"
  password: "hunter2"
secrets_backup:
  passphrase_hash: ""
EOF

echo "== encrypt with an explicit passphrase (non-interactive) =="
SECRETS_BACKUP_PASSPHRASE="correct-horse-battery-staple" bash scripts/encrypt_secrets.sh --quiet >/dev/null 2>&1 || true
# --quiet requires a configured hash OR the env var; env var path should succeed and write the .enc file.
assert_file_exists "secrets.yaml.enc was written" "secrets.yaml.enc"

echo "== decrypting into a fresh copy reproduces the original =="
mv secrets.yaml secrets.yaml.original
SECRETS_BACKUP_PASSPHRASE="correct-horse-battery-staple" SECRETS_BACKUP_OVERWRITE=1 bash scripts/decrypt_secrets.sh >/dev/null 2>&1
assert_eq "decrypted secrets.yaml matches the original byte-for-byte" \
    "$(cat secrets.yaml.original)" "$(cat secrets.yaml)"

echo "== wrong passphrase is refused =="
rm -f secrets.yaml
SECRETS_BACKUP_PASSPHRASE="wrong-passphrase" SECRETS_BACKUP_OVERWRITE=1 bash scripts/decrypt_secrets.sh >/dev/null 2>&1
exit_code=$?
assert_eq "wrong passphrase exits non-zero" "no" "$([[ $exit_code -eq 0 ]] && echo yes || echo no)"
assert_file_missing "wrong passphrase does not write secrets.yaml" "secrets.yaml"

test_summary_and_exit
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/ijb500/Home_PI4_bin && bash tests/test_secrets_roundtrip.sh`
Expected: FAIL — `scripts/lib/secrets_common.sh` etc. don't exist yet.

- [ ] **Step 3: Write `scripts/lib/secrets_common.sh`**

```bash
# scripts/lib/secrets_common.sh - shared helpers for encrypt_secrets.sh / decrypt_secrets.sh.
# Sourced, never executed. Ported from ~/home_automation on the Home Pi4, with one
# change: read_configured_passphrase_hash uses a small awk reader instead of
# python3+pyyaml, since this repo has no Python dependency and secrets.yaml here
# only ever needs simple two-level key reads.

sha256_hex() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | cut -d' ' -f1
    else
        shasum -a 256 | cut -d' ' -f1
    fi
}

secrets_openssl() {
    openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt "$@" \
        -pass env:SECRETS_BACKUP_PASSPHRASE_HASH
}

# Prints secrets.yaml's secrets_backup.passphrase_hash, or nothing if absent.
# Run from the repo root (same convention as the ported original).
read_configured_passphrase_hash() {
    [ -f "secrets.yaml" ] || return 0
    awk '
        /^secrets_backup:/ { in_block=1; next }
        /^[^ \t]/ { in_block=0 }
        in_block && /^[ \t]*passphrase_hash:/ {
            sub(/^[^:]*:[ \t]*/, "")
            gsub(/^"|"$/, "")
            print
            exit
        }
    ' secrets.yaml
}
```

- [ ] **Step 4: Write `scripts/encrypt_secrets.sh`**

```bash
#!/bin/bash
# encrypt_secrets.sh - Encrypt secrets.yaml into secrets.yaml.enc for backup in git.
# Ported from ~/home_automation on the Home Pi4 (see git history for the original's
# full design rationale). Passphrase: recommended is the Home Pi4's own login
# password - hashed with SHA-256 before use, never used raw as the openssl key.
#
# Passphrase source, checked in this order:
#   1. $SECRETS_BACKUP_PASSPHRASE, if set.
#   2. secrets_backup.passphrase_hash in secrets.yaml, if set.
#   3. Otherwise, prompts interactively (twice, must match).
#
# --quiet: for cron. Requires option 1 or 2 above.

set -e
cd "$(dirname "$0")/.."
. "scripts/lib/secrets_common.sh"

QUIET=false
[ "${1:-}" = "--quiet" ] && QUIET=true
log() { [ "$QUIET" = true ] || echo "$@"; }

if [ ! -f "secrets.yaml" ]; then
    echo "ERROR: secrets.yaml not found in $(pwd)" >&2
    exit 1
fi

WORK_ENC="$(mktemp "${TMPDIR:-/tmp}/secrets.enc.XXXXXX")"
WORK_PLAIN="$(mktemp "${TMPDIR:-/tmp}/secrets.plain.XXXXXX")"
cleanup() { rm -f "$WORK_ENC" "$WORK_PLAIN"; }
trap cleanup EXIT

PASSPHRASE_HASH=""
if [ -n "${SECRETS_BACKUP_PASSPHRASE:-}" ]; then
    PASSPHRASE_HASH="$(printf '%s' "$SECRETS_BACKUP_PASSPHRASE" | sha256_hex)"
else
    PASSPHRASE_HASH="$(read_configured_passphrase_hash)"
fi

if [ -z "$PASSPHRASE_HASH" ]; then
    if [ "$QUIET" = true ]; then
        echo "ERROR: --quiet needs secrets_backup.passphrase_hash in secrets.yaml, or \$SECRETS_BACKUP_PASSPHRASE." >&2
        exit 1
    fi
    if [ ! -t 0 ]; then
        echo "ERROR: no passphrase configured and no terminal to prompt on." >&2
        exit 1
    fi
    read -r -s -p "Passphrase: " RAW_PASSPHRASE; echo ""
    read -r -s -p "Passphrase (again): " RAW_PASSPHRASE_CONFIRM; echo ""
    if [ "$RAW_PASSPHRASE" != "$RAW_PASSPHRASE_CONFIRM" ] || [ -z "$RAW_PASSPHRASE" ]; then
        echo "ERROR: passphrases didn't match (or were empty) - nothing was changed." >&2
        exit 1
    fi
    PASSPHRASE_HASH="$(printf '%s' "$RAW_PASSPHRASE" | sha256_hex)"
    unset RAW_PASSPHRASE RAW_PASSPHRASE_CONFIRM
    echo "Computed hash (paste into secrets_backup.passphrase_hash for unattended runs):"
    echo "  $PASSPHRASE_HASH"
fi

export SECRETS_BACKUP_PASSPHRASE_HASH="$PASSPHRASE_HASH"

UNCHANGED=false
if [ -f "secrets.yaml.enc" ]; then
    if secrets_openssl -d -in secrets.yaml.enc -out "$WORK_PLAIN" 2>/dev/null &&
       cmp -s "$WORK_PLAIN" "secrets.yaml"; then
        UNCHANGED=true
    fi
fi
if [ "$UNCHANGED" = true ]; then
    log "secrets.yaml is unchanged since the last backup - nothing to do."
    exit 0
fi

secrets_openssl -e -in secrets.yaml -out "$WORK_ENC"
if ! secrets_openssl -d -in "$WORK_ENC" -out "$WORK_PLAIN" 2>/dev/null ||
   ! cmp -s "$WORK_PLAIN" "secrets.yaml"; then
    echo "ERROR: the new backup did not decrypt back to secrets.yaml - refusing to replace secrets.yaml.enc." >&2
    exit 1
fi

cp "$WORK_ENC" secrets.yaml.enc
chmod 644 secrets.yaml.enc
log "Wrote secrets.yaml.enc (verified it decrypts back to secrets.yaml)."
```

- [ ] **Step 5: Write `scripts/decrypt_secrets.sh`**

```bash
#!/bin/bash
# decrypt_secrets.sh - Restore secrets.yaml from its encrypted git backup.
# Ported from ~/home_automation on the Home Pi4. Run from the repo root.

set -e
cd "$(dirname "$0")/.."
. "scripts/lib/secrets_common.sh"

if [ ! -f "secrets.yaml.enc" ]; then
    echo "ERROR: secrets.yaml.enc not found in $(pwd)" >&2
    exit 1
fi

if [ -f "secrets.yaml" ]; then
    if [ -n "${SECRETS_BACKUP_OVERWRITE:-}" ]; then
        echo "secrets.yaml already exists - overwriting (SECRETS_BACKUP_OVERWRITE set)."
    elif [ ! -t 0 ]; then
        echo "ERROR: secrets.yaml exists and there's no terminal to confirm on. Set SECRETS_BACKUP_OVERWRITE=1." >&2
        exit 1
    else
        read -r -p "secrets.yaml already exists - overwrite it? [y/N] " confirm
        if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
            echo "Aborted. Nothing was changed."
            exit 1
        fi
    fi
fi

if [ -n "${SECRETS_BACKUP_PASSPHRASE:-}" ]; then
    PASSPHRASE_HASH="$(printf '%s' "$SECRETS_BACKUP_PASSPHRASE" | sha256_hex)"
else
    if [ ! -t 0 ]; then
        echo "ERROR: no terminal to prompt on. Set \$SECRETS_BACKUP_PASSPHRASE to run non-interactively." >&2
        exit 1
    fi
    read -r -s -p "Passphrase: " RAW_PASSPHRASE; echo ""
    PASSPHRASE_HASH="$(printf '%s' "$RAW_PASSPHRASE" | sha256_hex)"
    unset RAW_PASSPHRASE
fi

WORK_PLAIN="$(mktemp "${TMPDIR:-/tmp}/secrets.plain.XXXXXX")"
trap 'rm -f "$WORK_PLAIN"' EXIT

export SECRETS_BACKUP_PASSPHRASE_HASH="$PASSPHRASE_HASH"
if ! secrets_openssl -d -in secrets.yaml.enc -out "$WORK_PLAIN" 2>/dev/null; then
    echo "ERROR: could not decrypt secrets.yaml.enc - wrong passphrase? Nothing was changed." >&2
    exit 1
fi
unset SECRETS_BACKUP_PASSPHRASE_HASH

if ! grep -q ":" "$WORK_PLAIN"; then
    echo "ERROR: decrypted output doesn't look like secrets.yaml - refusing to install it." >&2
    exit 1
fi

cp "$WORK_PLAIN" secrets.yaml
chmod 600 secrets.yaml
echo "Restored secrets.yaml"
```

- [ ] **Step 6: Make the new scripts executable and run the test**

Run: `chmod +x /Users/ijb500/Home_PI4_bin/scripts/encrypt_secrets.sh /Users/ijb500/Home_PI4_bin/scripts/decrypt_secrets.sh && bash /Users/ijb500/Home_PI4_bin/tests/test_secrets_roundtrip.sh`
Expected: PASS (all assertions ok).

- [ ] **Step 7: Commit**

```bash
git add scripts/lib/secrets_common.sh scripts/encrypt_secrets.sh scripts/decrypt_secrets.sh tests/test_secrets_roundtrip.sh
git commit -m "Port home_automation's secrets.yaml.enc mechanism into this repo"
```

- [ ] **Step 8: Populate the real `secrets.yaml` (not committed — gitignored)**

This is a one-time manual step, not a code change:

```bash
cd /Users/ijb500/Home_PI4_bin
cp secrets.yaml.example secrets.yaml
# Edit secrets.yaml by hand and fill in:
#   opensubtitles.api_key      = the API key from the "New Consumer" you registered
#   opensubtitles.username     = iainbate
#   opensubtitles.password     = (the OpenSubtitles.com account password already
#                                  shared earlier in this conversation)
# Leave secrets_backup.passphrase_hash empty for now - the first `encrypt_secrets.sh`
# run (interactive) will compute and print it for you to paste in.
bash scripts/encrypt_secrets.sh
git add secrets.yaml.enc
git commit -m "Add encrypted secrets.yaml.enc backup"
```

---

### Task 3: `lib/forced_subs_common.sh` — filesystem, naming, and cache helpers

**Files:**
- Create: `lib/forced_subs_common.sh`
- Test: `tests/test_forced_subs_common.sh`

**Interfaces:**
- Produces: `walk_films <root>` (prints one video file path per line, prunes `Our Family`), `normalize_title_from_path <path>` (prints a cleaned title guess), `extract_year_from_name <name>` (prints a 4-digit year or nothing), `imdb_tt_to_numeric <tt_id>` (prints digits only), `yaml_get_2level <file> <top_key> <sub_key>` (prints the value or nothing), `fid_cache_get_field <path> <field>` (field ∈ imdb_id/title/year/confidence/reason/last_checked; exits 1 if no row), `fid_cache_set <path> <imdb_id> <title> <year> <confidence> <reason> <checked>`, `file_stat_signature <path>` (prints `<size>:<mtime_epoch>`, portable across GNU/BSD `stat` — used by Task 7's scan cache to detect whether a file has changed since it was last checked).
- Consumes: env var `FID_CACHE` (path to the identity cache TSV; tests override it).

- [ ] **Step 1: Write the failing test**

```bash
# tests/test_forced_subs_common.sh
#!/bin/bash
set -uo pipefail
cd "$(dirname "$0")"
source test_helpers.sh

REPO_ROOT="$(cd .. && pwd)"
source "$REPO_ROOT/lib/forced_subs_common.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "== walk_films prunes 'Our Family' and finds video files =="
mkdir -p "$WORK/films/Star Wars" "$WORK/films/Our Family"
touch "$WORK/films/Star Wars/Phantom Menace.mp4"
touch "$WORK/films/Our Family/birthday.mp4"
touch "$WORK/films/Star Wars/notes.txt"
found=$(walk_films "$WORK/films" | sort)
assert_contains "finds the Star Wars mp4" "$found" "Phantom Menace.mp4"
assert_eq "does not descend into Our Family" "no" "$([[ "$found" == *"birthday.mp4"* ]] && echo yes || echo no)"
assert_eq "ignores non-video files" "no" "$([[ "$found" == *"notes.txt"* ]] && echo yes || echo no)"

echo "== extract_year_from_name =="
assert_eq "finds a parenthesized year" "2026" "$(extract_year_from_name "Moana (2026).mp4")"
assert_eq "finds a dashed year" "2026" "$(extract_year_from_name "Moana - 2026.mp4")"
assert_eq "no year present" "" "$(extract_year_from_name "Phantom Menace.mp4")"

echo "== normalize_title_from_path strips tags but the caller controls year handling =="
title=$(normalize_title_from_path "$WORK/films/Star Wars/Phantom.Menace.1080p.BluRay.x264.mp4")
assert_eq "strips extension/dots/quality/codec tags" "Phantom Menace" "$title"

echo "== imdb_tt_to_numeric =="
assert_eq "strips tt and leading zeros" "120915" "$(imdb_tt_to_numeric "tt0120915")"

echo "== yaml_get_2level reads a nested value =="
cat > "$WORK/sample.yaml" <<'EOF'
opensubtitles:
  api_key: "abc123"
  username: "iainbate"
secrets_backup:
  passphrase_hash: "deadbeef"
EOF
assert_eq "reads opensubtitles.api_key" "abc123" "$(yaml_get_2level "$WORK/sample.yaml" opensubtitles api_key)"
assert_eq "reads a different top-level block" "deadbeef" "$(yaml_get_2level "$WORK/sample.yaml" secrets_backup passphrase_hash)"
assert_eq "missing key prints nothing" "" "$(yaml_get_2level "$WORK/sample.yaml" opensubtitles password)"

echo "== file_stat_signature =="
echo "hello" > "$WORK/sig.txt"
sig1=$(file_stat_signature "$WORK/sig.txt")
sig1_again=$(file_stat_signature "$WORK/sig.txt")
assert_eq "signature is stable for an untouched file" "$sig1" "$sig1_again"
sleep 1
echo "hello world, this is longer" > "$WORK/sig.txt"
sig2=$(file_stat_signature "$WORK/sig.txt")
assert_eq "signature changes when the file's content/size changes" "no" "$([[ "$sig1" == "$sig2" ]] && echo yes || echo no)"

echo "== fid_cache round-trips a row =="
export FID_CACHE="$WORK/fid_cache"
fid_cache_set "/mnt/HDD/films/Moana (2016).mp4" "tt3521164" "Moana" "2016" "hash" "" "2026-09-14"
assert_eq "reads back imdb_id" "tt3521164" "$(fid_cache_get_field "/mnt/HDD/films/Moana (2016).mp4" imdb_id)"
assert_eq "reads back confidence" "hash" "$(fid_cache_get_field "/mnt/HDD/films/Moana (2016).mp4" confidence)"
fid_cache_set "/mnt/HDD/films/Moana (2016).mp4" "tt3521164" "Moana" "2016" "manual" "" "2026-09-15"
assert_eq "a later set for the same path replaces the row, not appends" "1" "$(grep -c "Moana (2016)" "$FID_CACHE")"
assert_eq "unknown path exits non-zero" "no" "$(fid_cache_get_field "/no/such/path.mp4" imdb_id >/dev/null 2>&1 && echo yes || echo no)"

test_summary_and_exit
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash /Users/ijb500/Home_PI4_bin/tests/test_forced_subs_common.sh`
Expected: FAIL (`lib/forced_subs_common.sh` doesn't exist).

- [ ] **Step 3: Write `lib/forced_subs_common.sh`**

```bash
# lib/forced_subs_common.sh - shared helpers for the forced_subs script.
# Sourced, never executed.

walk_films() {
    local root="$1"
    find "$root" -type d -name "Our Family" -prune -o -type f \
        \( -iname "*.mp4" -o -iname "*.mkv" -o -iname "*.m4v" -o -iname "*.avi" \) -print
}

# A 4-digit 19xx/20xx year token, if present (last one wins if several).
extract_year_from_name() {
    printf '%s' "$1" | grep -oE '(19|20)[0-9]{2}' | tail -1
}

# Cleaned title guess from a file's basename: extension, dots/underscores,
# a parenthesized or dashed year, and common quality/codec tags stripped.
# Year is deliberately NOT part of this function's output - callers that
# need it use extract_year_from_name separately (see forced_subs_common.sh
# design note in the spec: year disambiguates same-title films and must
# never be silently discarded).
normalize_title_from_path() {
    local base
    base=$(basename "$1")
    base="${base%.*}"
    base=$(printf '%s' "$base" | sed -E \
        -e 's/\((19|20)[0-9]{2}\)//g' \
        -e 's/[-_ ]+(19|20)[0-9]{2}([-_ ]|$)/ /g' \
        -e 's/[._]/ /g' \
        -e 's/\b(1080p|2160p|720p|4K|BluRay|BRRip|WEBRip|WEB-DL|x264|x265|HEVC|H264|H265|AAC|DTS)\b//Ig' \
        -e 's/[[:space:]]+/ /g' \
        -e 's/^[[:space:]]+|[[:space:]]+$//g')
    printf '%s' "$base"
}

imdb_tt_to_numeric() {
    printf '%s' "${1#tt}" | sed 's/^0*//'
}

# "<size>:<mtime_epoch>" for a file - portable across GNU stat (the Pi) and
# BSD stat (macOS, where these tests are run from during development).
file_stat_signature() {
    stat -c '%s:%Y' "$1" 2>/dev/null || stat -f '%z:%m' "$1"
}

# Reads a simple two-level "top_key:\n  sub_key: value" YAML file. Not a
# general YAML parser - deliberately limited to this fixed shape (see
# secrets.yaml/secrets.yaml.example), matching this repo's dependency-free
# convention.
yaml_get_2level() {
    local file="$1" top_key="$2" sub_key="$3"
    [ -f "$file" ] || return 0
    awk -v top="$top_key:" -v sub="$sub_key" '
        $0 == top { in_block=1; next }
        /^[^ \t]/ { in_block=0 }
        in_block {
            line=$0
            sub(/^[ \t]+/, "", line)
            if (line ~ "^" sub ":") {
                sub(/^[^:]*:[ \t]*/, "", line)
                gsub(/^"|"$/, "", line)
                print line
                exit
            }
        }
    ' "$file"
}

# forced_subs_file_ids row: path \t imdb_id \t title \t year \t confidence \t reason \t last_checked
fid_cache_get_field() {
    local file="$1" field="$2" cache="${FID_CACHE:-/home/pi/logs/forced_subs_file_ids}"
    [ -f "$cache" ] || return 1
    awk -F'\t' -v path="$file" -v field="$field" '
        BEGIN { cols["imdb_id"]=2; cols["title"]=3; cols["year"]=4; cols["confidence"]=5; cols["reason"]=6; cols["last_checked"]=7 }
        $1 == path { print $(cols[field]); found=1 }
        END { exit !found }
    ' "$cache"
}

fid_cache_set() {
    local file="$1" imdb_id="$2" title="$3" year="$4" confidence="$5" reason="$6" checked="$7"
    local cache="${FID_CACHE:-/home/pi/logs/forced_subs_file_ids}"
    mkdir -p "$(dirname "$cache")"
    touch "$cache"
    local tmp; tmp=$(mktemp)
    awk -F'\t' -v path="$file" '$1 != path' "$cache" > "$tmp"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$file" "$imdb_id" "$title" "$year" "$confidence" "$reason" "$checked" >> "$tmp"
    mv "$tmp" "$cache"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash /Users/ijb500/Home_PI4_bin/tests/test_forced_subs_common.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/forced_subs_common.sh tests/test_forced_subs_common.sh
git commit -m "Add forced_subs_common.sh: filesystem, naming, and identity-cache helpers"
```

---

### Task 4: `lib/ost.py` — moviehash + OpenSubtitles REST calls

Stdlib-only Python (no pip packages). Reads credentials from environment variables, never `argv`, so they never appear in `ps` output.

**Files:**
- Create: `lib/ost.py`
- Test: `tests/test_ost_hash.sh`

**Interfaces:**
- Produces (CLI, one subcommand per line): `hash <file>` → 16-hex-char moviehash; `login` (env `OST_API_KEY OST_USER_AGENT OST_USERNAME OST_PASSWORD`) → prints the JWT token; `identify_by_hash <hash>` (env `OST_API_KEY OST_USER_AGENT`) → `tt<imdb>\t<title>\t<year>` or nothing; `find_forced_by_hash <hash>` / `find_forced_by_imdb <imdb_numeric>` (same env) → `<file_id>\t<release>\t<language>` or nothing; `download <file_id> <output_path>` (env `OST_API_KEY OST_USER_AGENT OST_TOKEN`) → `<remaining>\t<message>`, writes the SRT to `<output_path>`.

- [ ] **Step 1: Write the failing test (hash only — the network subcommands are exercised indirectly in Tasks 6/8 via a stub, not tested live here per the Global Constraints)**

```bash
# tests/test_ost_hash.sh
#!/bin/bash
set -uo pipefail
cd "$(dirname "$0")"
source test_helpers.sh

REPO_ROOT="$(cd .. && pwd)"
OST_PY="$REPO_ROOT/lib/ost.py"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

dd if=/dev/zero bs=1024 count=200 2>/dev/null | tr '\0' 'A' > "$WORK/a.bin"
cp "$WORK/a.bin" "$WORK/a_copy.bin"
dd if=/dev/zero bs=1024 count=200 2>/dev/null | tr '\0' 'B' > "$WORK/b.bin"

h1=$(python3 "$OST_PY" hash "$WORK/a.bin")
h1_again=$(python3 "$OST_PY" hash "$WORK/a.bin")
h_copy=$(python3 "$OST_PY" hash "$WORK/a_copy.bin")
h_b=$(python3 "$OST_PY" hash "$WORK/b.bin")

echo "== format =="
assert_eq "hash is 16 lowercase hex chars" "yes" "$(printf '%s' "$h1" | grep -qE '^[0-9a-f]{16}$' && echo yes || echo no)"

echo "== deterministic =="
assert_eq "same file hashed twice matches" "$h1" "$h1_again"

echo "== identical content produces identical hash =="
assert_eq "copy matches original" "$h1" "$h_copy"

echo "== different content produces different hash =="
assert_eq "different content differs" "no" "$([[ "$h1" == "$h_b" ]] && echo yes || echo no)"

echo "== only head+tail 64KB are sampled: a middle-only edit doesn't change the hash =="
cp "$WORK/a.bin" "$WORK/a_middle_changed.bin"
dd if=/dev/zero bs=1 count=10 conv=notrunc of="$WORK/a_middle_changed.bin" seek=100000 2>/dev/null
h_middle=$(python3 "$OST_PY" hash "$WORK/a_middle_changed.bin")
assert_eq "middle-only edit leaves hash unchanged" "$h1" "$h_middle"

test_summary_and_exit
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash /Users/ijb500/Home_PI4_bin/tests/test_ost_hash.sh`
Expected: FAIL (`lib/ost.py` doesn't exist).

- [ ] **Step 3: Write `lib/ost.py`**

```python
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
  ost.py download <file_id> <output_path>          (env: OST_API_KEY OST_USER_AGENT OST_TOKEN)
"""
import json
import os
import struct
import sys
import urllib.error
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash /Users/ijb500/Home_PI4_bin/tests/test_ost_hash.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/ost.py tests/test_ost_hash.sh
git commit -m "Add ost.py: moviehash algorithm + OpenSubtitles REST calls"
```

---

### Task 5: `lib/known_films.py` + seeded `forced_subs_known_films.yaml`

The curated list uses a **flat, line-oriented** shape (not general YAML — this repo has no YAML library, and the shape is fixed by design): a `films:` list where each record runs from a `- title:` line to the next `- title:` (or EOF), with `aliases` and `editions` as single delimited scalar strings rather than nested lists, so a simple line-by-line reader suffices.

**Files:**
- Create: `lib/known_films.py`
- Create: `forced_subs_known_films.yaml`
- Test: `tests/test_known_films.sh`

**Interfaces:**
- Produces (CLI): `lookup <yaml_path> <imdb_id>` → `<title>\t<year>\t<editions>` (editions as `name:minutes,name:minutes`), exits 1 if not found; `find_by_title_year <yaml_path> <normalized_title> <year_or_empty>` → zero, one, or many `<imdb_id>\t<title>\t<year>` lines.

- [ ] **Step 1: Write the failing test**

```bash
# tests/test_known_films.sh
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash /Users/ijb500/Home_PI4_bin/tests/test_known_films.sh`
Expected: FAIL (`lib/known_films.py` doesn't exist).

- [ ] **Step 3: Write `lib/known_films.py`**

```python
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash /Users/ijb500/Home_PI4_bin/tests/test_known_films.sh`
Expected: PASS.

- [ ] **Step 5: Seed `forced_subs_known_films.yaml`**

Star Wars saga + LOTR trilogy, the two Moana entries from the design discussion (real IMDb IDs; runtimes are theatrical-release approximations — flag any that turn out wrong once `scan` starts reporting `unmatched_edition` for a real file, and correct them then):

```yaml
films:
  - title: "Star Wars: Episode I - The Phantom Menace"
    aliases: "Phantom Menace|Episode I"
    year: 1999
    imdb_id: "tt0120915"
    editions: "theatrical:133,2011_bluray:136"
  - title: "Star Wars: Episode II - Attack of the Clones"
    aliases: "Attack of the Clones|Episode II"
    year: 2002
    imdb_id: "tt0121765"
    editions: "theatrical:142"
  - title: "Star Wars: Episode III - Revenge of the Sith"
    aliases: "Revenge of the Sith|Episode III"
    year: 2005
    imdb_id: "tt0121766"
    editions: "theatrical:140"
  - title: "Star Wars: Episode IV - A New Hope"
    aliases: "A New Hope|Episode IV|Star Wars"
    year: 1977
    imdb_id: "tt0076759"
    editions: "theatrical:121"
  - title: "Star Wars: Episode V - The Empire Strikes Back"
    aliases: "The Empire Strikes Back|Empire Strikes Back|Episode V"
    year: 1980
    imdb_id: "tt0080684"
    editions: "theatrical:124"
  - title: "Star Wars: Episode VI - Return of the Jedi"
    aliases: "Return of the Jedi|Episode VI"
    year: 1983
    imdb_id: "tt0086190"
    editions: "theatrical:131"
  - title: "The Lord of the Rings: The Fellowship of the Ring"
    aliases: "Fellowship of the Ring"
    year: 2001
    imdb_id: "tt0120737"
    editions: "theatrical:178,extended:228"
  - title: "The Lord of the Rings: The Two Towers"
    aliases: "The Two Towers"
    year: 2002
    imdb_id: "tt0167261"
    editions: "theatrical:179,extended:235"
  - title: "The Lord of the Rings: The Return of the King"
    aliases: "The Return of the King"
    year: 2003
    imdb_id: "tt0167260"
    editions: "theatrical:201,extended:263"
  - title: "Moana"
    aliases: ""
    year: 2016
    imdb_id: "tt3521164"
    editions: "theatrical:107"
```

Note: the 2026 live-action Moana entry is deliberately **not** seeded here — I don't have a verified IMDb ID/runtime for it, and per the "no placeholders" rule for this plan I'm not fabricating one. Add it by hand the same way once you have both from IMDb, following the pattern above; that's exactly the curated-list growth path the spec describes.

- [ ] **Step 6: Commit**

```bash
git add lib/known_films.py forced_subs_known_films.yaml tests/test_known_films.sh
git commit -m "Add known_films.py reader and seed forced_subs_known_films.yaml"
```

---

### Task 6: `forced_subs identify` subcommand

**Files:**
- Create: `forced_subs` (only the `identify` path + shared setup for now — `scan`/`apply`/`report` are added in later tasks)
- Test: `tests/test_forced_subs_identify.sh`

**Interfaces:**
- Consumes: `walk_films`, `normalize_title_from_path`, `extract_year_from_name`, `fid_cache_get_field`, `fid_cache_set` (Task 3); `find_by_title_year`/`lookup` via `known_films.py` (Task 5); `hash`/`identify_by_hash` via `ost.py` (Task 4).
- Produces: `forced_subs identify [--rehash]`, `forced_subs identify --set <path> <imdb_id>`. Env overrides for testing: `FORCED_SUBS_LIBDIR` (default `<repo>/lib`), `FORCED_SUBS_KNOWN_FILMS` (default `<repo>/forced_subs_known_films.yaml`), `FID_CACHE`, `FORCED_SUBS_FILMS_ROOT` (default `/mnt/HDD/films`), `SCAN_CACHE` (default `/home/pi/logs/forced_subs_scan_cache`, used from Task 7 onward), `FORCED_SUBS_REPORT_FILE` (default `$FILMS_ROOT/_FORCED_SUBTITLES_REPORT.txt`, used from Task 9 onward).

- [ ] **Step 1: Write the failing test**

Uses a fake `ost.py` (env `FORCED_SUBS_LIBDIR` points at a scratch dir containing it) so no real network call happens, per the Global Constraints.

```bash
# tests/test_forced_subs_identify.sh
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
touch "$WORK/films/Moana Films/Moana - Unknown Year.mp4"

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
assert_eq "ambiguous file has no imdb_id" "" "$(fid_cache_get_field "$WORK/films/Moana Films/Moana - Unknown Year.mp4" imdb_id)"
assert_eq "reason recorded as ambiguous" "ambiguous_title_multiple_years" "$(fid_cache_get_field "$WORK/films/Moana Films/Moana - Unknown Year.mp4" reason)"

echo "== --set manually resolves an ambiguous file and is sticky =="
"$FORCED_SUBS" identify --set "$WORK/films/Moana Films/Moana - Unknown Year.mp4" tt9999999 >/dev/null
assert_eq "manually set imdb_id" "tt9999999" "$(fid_cache_get_field "$WORK/films/Moana Films/Moana - Unknown Year.mp4" imdb_id)"
assert_eq "confidence is manual" "manual" "$(fid_cache_get_field "$WORK/films/Moana Films/Moana - Unknown Year.mp4" confidence)"
"$FORCED_SUBS" identify --rehash >/dev/null
assert_eq "a later plain identify --rehash does not overwrite the manual entry" "manual" "$(fid_cache_get_field "$WORK/films/Moana Films/Moana - Unknown Year.mp4" confidence)"

test_summary_and_exit
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash /Users/ijb500/Home_PI4_bin/tests/test_forced_subs_identify.sh`
Expected: FAIL (`forced_subs` doesn't exist).

- [ ] **Step 3: Write `forced_subs` (identify path + shared setup)**

```bash
#!/bin/bash
# forced_subs - scan /mnt/HDD/films for missing forced-English subtitles,
# identify films via OpenSubtitles moviehash + a curated list, and fetch/
# remux matches within a daily API budget.
# Usage: forced_subs {identify|scan|apply|report} [options]
# See docs/superpowers/specs/2026-09-14-forced-subtitle-scanner-design.md.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIBDIR="${FORCED_SUBS_LIBDIR:-$REPO_ROOT/lib}"
CONVERT_VIDEO="${FORCED_SUBS_CONVERT_VIDEO:-$REPO_ROOT/convert_video}"
KNOWN_FILMS_YAML="${FORCED_SUBS_KNOWN_FILMS:-$REPO_ROOT/forced_subs_known_films.yaml}"
FILMS_ROOT="${FORCED_SUBS_FILMS_ROOT:-/mnt/HDD/films}"
FID_CACHE="${FID_CACHE:-/home/pi/logs/forced_subs_file_ids}"
UNAVAILABLE_CACHE="${UNAVAILABLE_CACHE:-/home/pi/logs/forced_subs_unavailable_cache}"
APPLY_LOG="${APPLY_LOG:-/home/pi/logs/forced_subs_apply_logfile}"
SCAN_LOG="${SCAN_LOG:-/home/pi/logs/forced_subs_scan_logfile}"
SCAN_CACHE="${SCAN_CACHE:-/home/pi/logs/forced_subs_scan_cache}"
REPORT_FILE="${FORCED_SUBS_REPORT_FILE:-$FILMS_ROOT/_FORCED_SUBTITLES_REPORT.txt}"
export FID_CACHE UNAVAILABLE_CACHE SCAN_CACHE

# shellcheck source=lib/forced_subs_common.sh
. "$LIBDIR/forced_subs_common.sh"

load_opensubtitles_creds() {
    OST_API_KEY=$(yaml_get_2level "$REPO_ROOT/secrets.yaml" opensubtitles api_key)
    OST_USERNAME=$(yaml_get_2level "$REPO_ROOT/secrets.yaml" opensubtitles username)
    OST_PASSWORD=$(yaml_get_2level "$REPO_ROOT/secrets.yaml" opensubtitles password)
    OST_USER_AGENT="forced_subs v1.0.0"
    export OST_API_KEY OST_USERNAME OST_PASSWORD OST_USER_AGENT
}

opensubtitles_login() {
    load_opensubtitles_creds
    OST_TOKEN=$(python3 "$LIBDIR/ost.py" login)
    export OST_TOKEN
}

# --- identify -----------------------------------------------------------

forced_subs_identify_one() {
    local file="$1"
    local existing_conf
    existing_conf=$(fid_cache_get_field "$file" confidence 2>/dev/null || true)
    if [ "$existing_conf" = "manual" ]; then
        return 0
    fi
    if [ -n "$existing_conf" ] && [ "${REHASH:-false}" != "true" ]; then
        return 0
    fi

    local hash hash_result imdb_id="" title="" year="" confidence reason=""
    hash=$(python3 "$LIBDIR/ost.py" hash "$file")
    hash_result=$(python3 "$LIBDIR/ost.py" identify_by_hash "$hash" 2>>"${SCAN_LOG:-/dev/null}" || true)

    if [ -n "$hash_result" ]; then
        IFS=$'\t' read -r imdb_id title year <<< "$hash_result"
        confidence="hash"
    else
        local norm_title year_guess fallback_result count
        norm_title=$(normalize_title_from_path "$file")
        year_guess=$(extract_year_from_name "$(basename "$file")")
        fallback_result=$(python3 "$LIBDIR/known_films.py" find_by_title_year "$KNOWN_FILMS_YAML" "$norm_title" "$year_guess")
        count=$(printf '%s\n' "$fallback_result" | grep -c . || true)
        if [ "$count" -eq 1 ]; then
            IFS=$'\t' read -r imdb_id title year <<< "$fallback_result"
            confidence="filename"
        elif [ "$count" -gt 1 ]; then
            confidence="unresolved"; reason="ambiguous_title_multiple_years"
        else
            confidence="unresolved"; reason="no_match"
        fi
    fi
    fid_cache_set "$file" "$imdb_id" "$title" "$year" "$confidence" "$reason" "$(date -I)"
}

cmd_identify_set() {
    local file="$1" imdb_id="$2" lookup title="" year=""
    lookup=$(python3 "$LIBDIR/known_films.py" lookup "$KNOWN_FILMS_YAML" "$imdb_id" 2>/dev/null || true)
    if [ -n "$lookup" ]; then
        IFS=$'\t' read -r title year _ <<< "$lookup"
    fi
    fid_cache_set "$file" "$imdb_id" "$title" "$year" "manual" "" "$(date -I)"
}

cmd_identify() {
    REHASH=false
    local set_path="" set_imdb=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --rehash) REHASH=true; shift ;;
            --set) set_path="$2"; set_imdb="$3"; shift 3 ;;
            *) shift ;;
        esac
    done
    if [ -n "$set_path" ]; then
        cmd_identify_set "$set_path" "$set_imdb"
        return 0
    fi
    while IFS= read -r file; do
        forced_subs_identify_one "$file"
    done < <(walk_films "$FILMS_ROOT")
}

# --- dispatch -------------------------------------------------------------

main() {
    local cmd="${1:-}"
    shift || true
    case "$cmd" in
        identify)
            load_opensubtitles_creds
            cmd_identify "$@"
            ;;
        *)
            echo "Usage: forced_subs {identify|scan|apply|report} [options]" >&2
            exit 2
            ;;
    esac
}

main "$@"
```

- [ ] **Step 4: Make it executable and run the test**

Run: `chmod +x /Users/ijb500/Home_PI4_bin/forced_subs && bash /Users/ijb500/Home_PI4_bin/tests/test_forced_subs_identify.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add forced_subs tests/test_forced_subs_identify.sh
git commit -m "Add forced_subs identify subcommand"
```

---

### Task 7: `forced_subs scan` subcommand

**Files:**
- Modify: `forced_subs` (add `cmd_scan`, `pick_edition`, the `scan` dispatch case)
- Test: `tests/test_forced_subs_scan.sh`

**Interfaces:**
- Consumes: `walk_films`, `forced_subs_identify_one`, `fid_cache_get_field`, `file_stat_signature` (Task 3); `convert_video --analyze-subs` (existing script); `known_films.py lookup`.
- Produces: `forced_subs scan` → prints and appends to `$SCAN_LOG` one line per file: `<bucket>\t<path>\t<imdb_id>\t<title>\t<edition>\t<coverage>\t<external_srt>\t<reason>`. `cmd_scan` (bash function) is reused as-is by `apply`/`report` in later tasks. Also produces `scan_cache_get`/`scan_cache_set` (bash functions) backing `$SCAN_CACHE` — see "Incremental scanning" in the spec: a file whose cached bucket was `HAS_FORCED` and whose `file_stat_signature` is unchanged is replayed from cache instead of re-run through `convert_video --analyze-subs`.

- [ ] **Step 1: Write the failing test**

```bash
# tests/test_forced_subs_scan.sh
#!/bin/bash
set -uo pipefail
cd "$(dirname "$0")"
source test_helpers.sh

REPO_ROOT="$(cd .. && pwd)"
FORCED_SUBS="$REPO_ROOT/forced_subs"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/lib" "$WORK/films/Star Wars" "$WORK/films/Unmatched"
cp "$REPO_ROOT/lib/forced_subs_common.sh" "$REPO_ROOT/lib/known_films.py" "$WORK/lib/"
cat > "$WORK/lib/ost.py" <<'PYEOF'
import sys
if sys.argv[1] == "hash":
    print("0000000000000000")
PYEOF

cat > "$WORK/films.yaml" <<'EOF'
films:
  - title: "Star Wars: Episode I - The Phantom Menace"
    aliases: "Phantom Menace"
    year: 1999
    imdb_id: "tt0120915"
    editions: "theatrical:133"
EOF

# has_forced.mkv: real forced English subtitle, high coverage -> HAS_FORCED
# needs_known.mp4: on the curated list, no subs at all -> NEEDS_FORCED_KNOWN
# needs_unknown.mp4: not on the curated list -> NEEDS_FORCED_UNKNOWN
ffmpeg -y -f lavfi -i testsrc=duration=10:size=320x180:rate=10 -f lavfi -i sine=duration=10 \
    -pix_fmt yuv420p "$WORK/base.mp4" -hide_banner -loglevel error
cat > "$WORK/high.srt" <<'EOF'
1
00:00:00,000 --> 00:00:05,000
Hola
EOF
ffmpeg -y -i "$WORK/base.mp4" -i "$WORK/high.srt" -map 0:v -map 0:a -map 1:s -c:v copy -c:a copy -c:s srt \
    -metadata:s:s:0 language=eng -disposition:s:0 forced "$WORK/films/Star Wars/has_forced.mkv" -hide_banner -loglevel error
ffmpeg -y -i "$WORK/base.mp4" -map 0:v -map 0:a -c copy "$WORK/films/Star Wars/Phantom Menace.mp4" -hide_banner -loglevel error
ffmpeg -y -i "$WORK/base.mp4" -map 0:v -map 0:a -c copy "$WORK/films/Unmatched/Some Random Film (2015).mp4" -hide_banner -loglevel error

export FORCED_SUBS_LIBDIR="$WORK/lib"
export FORCED_SUBS_KNOWN_FILMS="$WORK/films.yaml"
export FID_CACHE="$WORK/fid_cache"
export FORCED_SUBS_FILMS_ROOT="$WORK/films"
export SCAN_LOG="$WORK/scan_log"
export OST_API_KEY=test OST_USER_AGENT=test OST_USERNAME=test OST_PASSWORD=test

out=$("$FORCED_SUBS" scan)

echo "== HAS_FORCED for a file with a real forced track =="
assert_contains "has_forced.mkv bucketed HAS_FORCED" "$out" "$(printf 'HAS_FORCED\t%s/films/Star Wars/has_forced.mkv' "$WORK")"

echo "== NEEDS_FORCED_KNOWN for a curated, subtitle-less file =="
line=$(printf '%s\n' "$out" | grep "Phantom Menace.mp4")
assert_contains "bucketed NEEDS_FORCED_KNOWN" "$line" "NEEDS_FORCED_KNOWN"
assert_contains "carries the matched imdb_id" "$line" "tt0120915"
assert_contains "picks the theatrical edition" "$line" "theatrical"

echo "== NEEDS_FORCED_UNKNOWN for a file not on the curated list =="
line=$(printf '%s\n' "$out" | grep "Some Random Film")
assert_contains "bucketed NEEDS_FORCED_UNKNOWN" "$line" "NEEDS_FORCED_UNKNOWN"
assert_contains "reason is not_on_known_list" "$line" "not_on_known_list"

echo "== scan also appends to SCAN_LOG =="
assert_file_exists "scan log was written" "$SCAN_LOG"

echo "== incremental: an unchanged HAS_FORCED file is replayed from cache, not re-probed =="
export SCAN_CACHE="$WORK/scan_cache"
"$FORCED_SUBS" scan >/dev/null  # populate the cache
# Point CONVERT_VIDEO at a nonexistent path for this run only: if the cached
# HAS_FORCED file still reports correctly, it proves scan didn't need to
# call convert_video for it at all (the file genuinely can't be re-probed).
out2=$(FORCED_SUBS_CONVERT_VIDEO="$WORK/no-such-convert_video" "$FORCED_SUBS" scan 2>&1)
assert_contains "HAS_FORCED file still reported correctly with convert_video unavailable" "$out2" "$(printf 'HAS_FORCED\t%s/films/Star Wars/has_forced.mkv' "$WORK")"

test_summary_and_exit
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash /Users/ijb500/Home_PI4_bin/tests/test_forced_subs_scan.sh`
Expected: FAIL (`scan` subcommand not implemented).

- [ ] **Step 3: Add `pick_edition`, `cmd_scan`, and the `scan` dispatch case to `forced_subs`**

Insert after `cmd_identify` (before the `# --- dispatch ---` comment):

```bash
# --- scan -----------------------------------------------------------------

# Compares the file's actual duration (minutes) against an editions string
# ("name:minutes,name:minutes") and returns the closest name within a
# 3-minute tolerance, or "unmatched_edition".
pick_edition() {
    local file="$1" editions="$2"
    local duration_min
    duration_min=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null | awk '{printf "%d", $1/60}')
    local best="" best_diff=999999
    IFS=',' read -ra parts <<< "$editions"
    for part in "${parts[@]}"; do
        local name="${part%%:*}" minutes="${part##*:}"
        local diff=$(( duration_min > minutes ? duration_min - minutes : minutes - duration_min ))
        if [ "$diff" -lt "$best_diff" ]; then best_diff=$diff; best="$name"; fi
    done
    if [ -n "$best" ] && [ "$best_diff" -le 3 ]; then echo "$best"; else echo "unmatched_edition"; fi
}

# scan_cache row: path \t file_stat_signature \t <the 8-field result line>
# See "Incremental scanning" in the spec: lets scan skip re-probing a file
# whose last-known bucket was HAS_FORCED and whose size/mtime haven't
# changed since.
scan_cache_get() {
    local file="$1"
    [ -f "$SCAN_CACHE" ] || return 1
    awk -F'\t' -v p="$file" '$1==p {print; found=1} END{exit !found}' "$SCAN_CACHE"
}

scan_cache_set() {
    local file="$1" sig="$2" result_line="$3"
    mkdir -p "$(dirname "$SCAN_CACHE")"
    touch "$SCAN_CACHE"
    local tmp
    tmp=$(mktemp)
    awk -F'\t' -v p="$file" '$1 != p' "$SCAN_CACHE" > "$tmp"
    printf '%s\t%s\t%s\n' "$file" "$sig" "$result_line" >> "$tmp"
    mv "$tmp" "$SCAN_CACHE"
}

cmd_scan() {
    while IFS= read -r file; do
        local sig cached_row
        sig=$(file_stat_signature "$file")
        if cached_row=$(scan_cache_get "$file"); then
            local cached_sig cached_bucket
            cached_sig=$(printf '%s' "$cached_row" | cut -f2)
            cached_bucket=$(printf '%s' "$cached_row" | cut -f3)
            if [ "$cached_sig" = "$sig" ] && [ "$cached_bucket" = "HAS_FORCED" ]; then
                printf '%s\n' "$cached_row" | cut -f3-
                continue
            fi
        fi

        local analyze forced coverage external bucket imdb_id="" title="" edition="" reason=""
        analyze=$("$CONVERT_VIDEO" --analyze-subs "$file" 2>/dev/null)
        forced=$(printf '%s' "$analyze" | grep -oE 'FORCED=[0-9]+' | cut -d= -f2)
        coverage=$(printf '%s' "$analyze" | grep -oE 'COVERAGE=[0-9.]+' | cut -d= -f2)
        external=$(printf '%s' "$analyze" | grep -oE 'EXTERNAL_SRT=[0-9]+' | cut -d= -f2)

        local has_real_forced=false
        if [ "${forced:-0}" = "1" ] && awk -v c="${coverage:-0}" 'BEGIN{exit !(c>=15)}'; then
            has_real_forced=true
        fi

        if [ "${external:-0}" = "1" ] || [ "$has_real_forced" = "true" ]; then
            bucket="HAS_FORCED"
        else
            if ! fid_cache_get_field "$file" confidence >/dev/null 2>&1; then
                forced_subs_identify_one "$file"
            fi
            imdb_id=$(fid_cache_get_field "$file" imdb_id 2>/dev/null || true)
            title=$(fid_cache_get_field "$file" title 2>/dev/null || true)
            if [ -z "$imdb_id" ]; then
                bucket="NEEDS_FORCED_UNKNOWN"
                reason=$(fid_cache_get_field "$file" reason 2>/dev/null || echo "unresolved")
            else
                local lookup
                lookup=$(python3 "$LIBDIR/known_films.py" lookup "$KNOWN_FILMS_YAML" "$imdb_id" 2>/dev/null || true)
                if [ -z "$lookup" ]; then
                    bucket="NEEDS_FORCED_UNKNOWN"; reason="not_on_known_list"
                else
                    bucket="NEEDS_FORCED_KNOWN"
                    local editions
                    IFS=$'\t' read -r _ _ editions <<< "$lookup"
                    edition=$(pick_edition "$file" "$editions")
                fi
            fi
        fi
        local result_line
        result_line=$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' "$bucket" "$file" "$imdb_id" "$title" "$edition" "${coverage:-0}" "${external:-0}" "$reason")
        scan_cache_set "$file" "$sig" "$result_line"
        printf '%s\n' "$result_line"
    done < <(walk_films "$FILMS_ROOT")
}
```

Add the `scan` case to `main`'s dispatch:

```bash
        scan)
            load_opensubtitles_creds
            mkdir -p "$(dirname "$SCAN_LOG")" 2>/dev/null || true
            cmd_scan | tee -a "$SCAN_LOG"
            ;;
```

(Insert this case above the `*)` fallback, after `identify)`.)

- [ ] **Step 4: Run test to verify it passes**

Run: `bash /Users/ijb500/Home_PI4_bin/tests/test_forced_subs_scan.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add forced_subs tests/test_forced_subs_scan.sh
git commit -m "Add forced_subs scan subcommand"
```

---

### Task 8: `forced_subs apply` subcommand

**Files:**
- Modify: `forced_subs` (add `remux_forced_subtitle`, `find_sidecar_srt`, `unavailable_cache_is_fresh`, `unavailable_cache_set`, `log_apply`, `cmd_apply`, the `apply` dispatch case)
- Test: `tests/test_forced_subs_apply.sh`

**Interfaces:**
- Consumes: `cmd_scan` (Task 7); `ost.py hash/find_forced_by_hash/find_forced_by_imdb/download` (Task 4, stubbed in tests); `imdb_tt_to_numeric` (Task 3).
- Produces: `forced_subs apply [--max-downloads N] [--quiet]`. Appends to `$APPLY_LOG` (`<timestamp>\t<path>\t<status>\t<reason>`, status ∈ `success`/`unavailable`) and `$UNAVAILABLE_CACHE`.

- [ ] **Step 1: Write the failing test**

```bash
# tests/test_forced_subs_apply.sh
#!/bin/bash
set -uo pipefail
cd "$(dirname "$0")"
source test_helpers.sh

REPO_ROOT="$(cd .. && pwd)"
FORCED_SUBS="$REPO_ROOT/forced_subs"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/lib" "$WORK/films/Star Wars"
cp "$REPO_ROOT/lib/forced_subs_common.sh" "$REPO_ROOT/lib/known_films.py" "$WORK/lib/"

cat > "$WORK/films.yaml" <<'EOF'
films:
  - title: "Star Wars: Episode I - The Phantom Menace"
    aliases: "Phantom Menace"
    year: 1999
    imdb_id: "tt0120915"
    editions: "theatrical:0"
  - title: "No Subtitle Available Film"
    aliases: ""
    year: 2020
    imdb_id: "tt1111111"
    editions: "theatrical:0"
EOF

ffmpeg -y -f lavfi -i testsrc=duration=3:size=320x180:rate=10 -f lavfi -i sine=duration=3 \
    -pix_fmt yuv420p "$WORK/films/Star Wars/Phantom Menace.mp4" -hide_banner -loglevel error
cp "$WORK/films/Star Wars/Phantom Menace.mp4" "$WORK/films/Star Wars/No Subtitle Available Film.mp4"

cat > "$WORK/dummy.srt" <<'EOF'
1
00:00:00,000 --> 00:00:02,000
Bocce
EOF

# Fake ost.py: file 1 (Phantom Menace) gets a forced-hash match + a
# downloadable subtitle; file 2 (No Subtitle Available) gets nothing from
# either search, exercising the unavailable-cache path.
cat > "$WORK/lib/ost.py" <<PYEOF
import sys
cmd = sys.argv[1]
if cmd == "hash":
    print("0000000000000000")
elif cmd == "find_forced_by_hash":
    print("4461104\tPhantom.Menace.Forced\ten")
elif cmd == "find_forced_by_imdb":
    pass
elif cmd == "download":
    with open(sys.argv[3], "wb") as f:
        f.write(open("$WORK/dummy.srt", "rb").read())
    print("19\tok")
PYEOF

export FORCED_SUBS_LIBDIR="$WORK/lib"
export FORCED_SUBS_KNOWN_FILMS="$WORK/films.yaml"
export FID_CACHE="$WORK/fid_cache"
export FORCED_SUBS_FILMS_ROOT="$WORK/films"
export SCAN_LOG="$WORK/scan_log"
export APPLY_LOG="$WORK/apply_log"
export UNAVAILABLE_CACHE="$WORK/unavailable_cache"
export OST_API_KEY=test OST_USER_AGENT=test OST_USERNAME=test OST_PASSWORD=test OST_TOKEN=test

"$FORCED_SUBS" apply --max-downloads 5 >/dev/null

echo "== the matched file got a forced subtitle track muxed in =="
analyze=$("$REPO_ROOT/convert_video" --analyze-subs "$WORK/films/Star Wars/Phantom Menace.mp4")
assert_contains "FORCED=1 after apply" "$analyze" "FORCED=1"

echo "== the unmatched file was left untouched and logged unavailable =="
analyze2=$("$REPO_ROOT/convert_video" --analyze-subs "$WORK/films/Star Wars/No Subtitle Available Film.mp4")
assert_contains "still FORCED=0 (untouched)" "$analyze2" "FORCED=0"
assert_contains "logged as unavailable" "$(cat "$APPLY_LOG")" "unavailable"
assert_file_exists "unavailable cache written" "$UNAVAILABLE_CACHE"

echo "== apply log records the success =="
assert_contains "success logged for Phantom Menace" "$(cat "$APPLY_LOG")" "success"

test_summary_and_exit
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash /Users/ijb500/Home_PI4_bin/tests/test_forced_subs_apply.sh`
Expected: FAIL (`apply` subcommand not implemented).

- [ ] **Step 3: Add the apply-phase functions and dispatch case to `forced_subs`**

Insert after `cmd_scan` (before `# --- dispatch ---`):

```bash
# --- apply ------------------------------------------------------------

find_sidecar_srt() {
    local file="$1" dir base
    dir=$(dirname "$file")
    base=$(basename "$file")
    base="${base%.*}"
    find "$dir" -maxdepth 1 -iname "${base}.srt" -print -quit
}

remux_forced_subtitle() {
    local file="$1" srt="$2"
    local ext="${file##*.}"
    local sub_codec="mov_text"
    [ "$ext" = "mkv" ] && sub_codec="srt"
    local tmp_out
    tmp_out=$(mktemp --suffix=".$ext")

    if ! ffmpeg -y -i "$file" -i "$srt" -map 0:v -map 0:a -map 1:s \
        -c:v copy -c:a copy -c:s "$sub_codec" \
        -metadata:s:s:0 language=eng -disposition:s:0 forced \
        "$tmp_out" -hide_banner -loglevel error; then
        rm -f "$tmp_out"
        return 1
    fi

    local orig_dur new_dur has_forced
    orig_dur=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null | cut -d. -f1)
    new_dur=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$tmp_out" 2>/dev/null | cut -d. -f1)
    has_forced=$(ffprobe -v error -select_streams s -show_entries stream_disposition=forced -of csv=p=0 "$tmp_out" 2>/dev/null | grep -c '^1$' || true)

    if [ "$orig_dur" != "$new_dur" ] || [ "${has_forced:-0}" -lt 1 ]; then
        rm -f "$tmp_out"
        return 1
    fi
    mv "$tmp_out" "$file"
}

unavailable_cache_is_fresh() {
    local file="$1"
    [ -f "$UNAVAILABLE_CACHE" ] || return 1
    local last_checked
    last_checked=$(awk -F'\t' -v p="$file" '$1==p {v=$3} END{print v}' "$UNAVAILABLE_CACHE")
    [ -n "$last_checked" ] || return 1
    local age_days
    age_days=$(( ( $(date +%s) - $(date -d "$last_checked" +%s) ) / 86400 ))
    [ "$age_days" -lt 7 ]
}

unavailable_cache_set() {
    local file="$1" reason="$2"
    mkdir -p "$(dirname "$UNAVAILABLE_CACHE")"
    touch "$UNAVAILABLE_CACHE"
    local tmp
    tmp=$(mktemp)
    awk -F'\t' -v p="$file" '$1 != p' "$UNAVAILABLE_CACHE" > "$tmp"
    printf '%s\t%s\t%s\n' "$file" "$reason" "$(date -I)" >> "$tmp"
    mv "$tmp" "$UNAVAILABLE_CACHE"
}

log_apply() {
    mkdir -p "$(dirname "$APPLY_LOG")" 2>/dev/null || true
    printf '%s\t%s\t%s\t%s\n' "$(date -Iseconds)" "$1" "$2" "$3" >> "$APPLY_LOG"
}

cmd_apply() {
    local max_downloads="$1"
    local success_count=0
    while IFS=$'\t' read -r bucket file imdb_id title edition coverage external reason; do
        [ "$bucket" = "NEEDS_FORCED_KNOWN" ] || continue
        [ "$success_count" -lt "$max_downloads" ] || break
        unavailable_cache_is_fresh "$file" && continue

        local srt_path=""
        if [ "$external" = "1" ]; then
            srt_path=$(find_sidecar_srt "$file")
        else
            local hash result
            hash=$(python3 "$LIBDIR/ost.py" hash "$file")
            result=$(python3 "$LIBDIR/ost.py" find_forced_by_hash "$hash" 2>>"$APPLY_LOG" || true)
            if [ -z "$result" ]; then
                local imdb_numeric
                imdb_numeric=$(imdb_tt_to_numeric "$imdb_id")
                result=$(python3 "$LIBDIR/ost.py" find_forced_by_imdb "$imdb_numeric" 2>>"$APPLY_LOG" || true)
            fi
            if [ -z "$result" ]; then
                unavailable_cache_set "$file" "no_match_found"
                log_apply "$file" "unavailable" "no_match_found"
                continue
            fi
            local sub_file_id
            sub_file_id=$(printf '%s' "$result" | cut -f1)
            srt_path=$(mktemp --suffix=.srt)
            if ! python3 "$LIBDIR/ost.py" download "$sub_file_id" "$srt_path" >>"$APPLY_LOG" 2>&1 || [ ! -s "$srt_path" ]; then
                unavailable_cache_set "$file" "download_failed"
                log_apply "$file" "unavailable" "download_failed"
                rm -f "$srt_path"
                continue
            fi
        fi

        if [ -n "$srt_path" ] && remux_forced_subtitle "$file" "$srt_path"; then
            log_apply "$file" "success" "remuxed"
            success_count=$((success_count + 1))
        else
            unavailable_cache_set "$file" "remux_failed"
            log_apply "$file" "unavailable" "remux_failed"
        fi
    done < <(cmd_scan)
}
```

Add the `apply` case to `main`'s dispatch:

```bash
        apply)
            local max=5 quiet=false
            while [ $# -gt 0 ]; do
                case "$1" in
                    --max-downloads) max="$2"; shift 2 ;;
                    --quiet) quiet=true; shift ;;
                    *) shift ;;
                esac
            done
            opensubtitles_login
            if [ "$quiet" = "true" ]; then
                cmd_apply "$max" >>"$APPLY_LOG" 2>&1
            else
                cmd_apply "$max"
            fi
            ;;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash /Users/ijb500/Home_PI4_bin/tests/test_forced_subs_apply.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add forced_subs tests/test_forced_subs_apply.sh
git commit -m "Add forced_subs apply subcommand"
```

---

### Task 9: `forced_subs report` subcommand

**Files:**
- Modify: `forced_subs` (add `cmd_report`, the `report` dispatch case)
- Test: `tests/test_forced_subs_report.sh`

**Interfaces:**
- Consumes: `cmd_scan` (Task 7), `$APPLY_LOG`, `unavailable_cache_is_fresh`/`$UNAVAILABLE_CACHE` (Task 8).
- Produces: `forced_subs report [--verbose]` — three labelled sections, printed to stdout **and** written to `$REPORT_FILE` (default `$FILMS_ROOT/_FORCED_SUBTITLES_REPORT.txt` — see the spec's "Reporting" section: this puts it directly in the films share, not just the Pi's log directory). Overwritten each run, not appended.

- [ ] **Step 1: Write the failing test**

```bash
# tests/test_forced_subs_report.sh
#!/bin/bash
set -uo pipefail
cd "$(dirname "$0")"
source test_helpers.sh

REPO_ROOT="$(cd .. && pwd)"
FORCED_SUBS="$REPO_ROOT/forced_subs"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/lib" "$WORK/films/Star Wars"
cp "$REPO_ROOT/lib/forced_subs_common.sh" "$REPO_ROOT/lib/known_films.py" "$WORK/lib/"
cat > "$WORK/lib/ost.py" <<'PYEOF'
import sys
if sys.argv[1] == "hash":
    print("0000000000000000")
PYEOF

cat > "$WORK/films.yaml" <<'EOF'
films:
  - title: "Star Wars: Episode I - The Phantom Menace"
    aliases: "Phantom Menace"
    year: 1999
    imdb_id: "tt0120915"
    editions: "theatrical:0"
EOF

ffmpeg -y -f lavfi -i testsrc=duration=3:size=320x180:rate=10 -f lavfi -i sine=duration=3 \
    -pix_fmt yuv420p "$WORK/films/Star Wars/Phantom Menace.mp4" -hide_banner -loglevel error
ffmpeg -y -f lavfi -i testsrc=duration=3:size=320x180:rate=10 -f lavfi -i sine=duration=3 \
    -pix_fmt yuv420p "$WORK/films/Star Wars/Unmatched Obscure Film (2015).mp4" -hide_banner -loglevel error

export FORCED_SUBS_LIBDIR="$WORK/lib"
export FORCED_SUBS_KNOWN_FILMS="$WORK/films.yaml"
export FID_CACHE="$WORK/fid_cache"
export FORCED_SUBS_FILMS_ROOT="$WORK/films"
export SCAN_LOG="$WORK/scan_log"
export APPLY_LOG="$WORK/apply_log"
export UNAVAILABLE_CACHE="$WORK/unavailable_cache"
export OST_API_KEY=test OST_USER_AGENT=test OST_USERNAME=test OST_PASSWORD=test

# Simulate a prior apply run: Phantom Menace was already fixed.
printf '2026-09-14T00:00:00Z\t%s\tsuccess\tremuxed\n' "$WORK/films/Star Wars/Phantom Menace.mp4" > "$APPLY_LOG"

out=$("$FORCED_SUBS" report)

echo "== three sections are present =="
assert_contains "has the already-fine section" "$out" "Already fine"
assert_contains "has the added-by-script section" "$out" "Added by this script"
assert_contains "has the manual-attention section" "$out" "sort these out yourself"

echo "== the previously-applied file appears under added-by-script =="
assert_contains "Phantom Menace listed as added" "$out" "Phantom Menace.mp4"

echo "== the unmatched obscure film appears under manual attention =="
assert_contains "Unmatched Obscure Film listed for manual attention" "$out" "Unmatched Obscure Film"

echo "== the report is also written into the films root itself =="
assert_file_exists "report file written to the films root" "$WORK/films/_FORCED_SUBTITLES_REPORT.txt"
assert_eq "file content matches what was printed to stdout" "$out" "$(cat "$WORK/films/_FORCED_SUBTITLES_REPORT.txt")"

test_summary_and_exit
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash /Users/ijb500/Home_PI4_bin/tests/test_forced_subs_report.sh`
Expected: FAIL (`report` subcommand not implemented).

- [ ] **Step 3: Add `cmd_report` and its dispatch case to `forced_subs`**

Insert after `cmd_apply` (before `# --- dispatch ---`):

```bash
# --- report -----------------------------------------------------------

report_body() {
    local verbose="$1"
    local scan_output
    scan_output=$(cmd_scan)

    echo "=== Already fine ==="
    local has_forced_count
    has_forced_count=$(printf '%s\n' "$scan_output" | awk -F'\t' '$1=="HAS_FORCED"' | wc -l | tr -d ' ')
    echo "$has_forced_count file(s) already have forced subs."
    if [ "$verbose" = "true" ]; then
        printf '%s\n' "$scan_output" | awk -F'\t' '$1=="HAS_FORCED" {print "  " $2}'
    fi

    echo ""
    echo "=== Added by this script ==="
    if [ -f "$APPLY_LOG" ]; then
        awk -F'\t' '$3=="success" {print "  " $2}' "$APPLY_LOG" | sort -u
    fi

    echo ""
    echo "=== You'll need to sort these out yourself ==="
    printf '%s\n' "$scan_output" | awk -F'\t' '$1=="NEEDS_FORCED_UNKNOWN" {print "  " $2 " (" $8 ")"}'
    printf '%s\n' "$scan_output" | awk -F'\t' '$1=="NEEDS_FORCED_KNOWN"' | while IFS=$'\t' read -r bucket file imdb_id title edition coverage external reason; do
        if unavailable_cache_is_fresh "$file"; then
            local r
            r=$(awk -F'\t' -v p="$file" '$1==p {v=$2} END{print v}' "$UNAVAILABLE_CACHE")
            echo "  $file ($r)"
        fi
    done
}

cmd_report() {
    local verbose="$1"
    mkdir -p "$(dirname "$REPORT_FILE")" 2>/dev/null || true
    report_body "$verbose" | tee "$REPORT_FILE"
}
```

Add the `report` case to `main`'s dispatch:

```bash
        report)
            load_opensubtitles_creds
            local verbose=false
            [ "${1:-}" = "--verbose" ] && verbose=true
            cmd_report "$verbose"
            ;;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash /Users/ijb500/Home_PI4_bin/tests/test_forced_subs_report.sh`
Expected: PASS.

- [ ] **Step 5: Run the full test suite to confirm no regressions**

Run: `cd /Users/ijb500/Home_PI4_bin && for t in tests/test_*.sh; do echo "--- $t ---"; bash "$t" || exit 1; done`
Expected: every test file ends with `0 failed`.

- [ ] **Step 6: Commit**

```bash
git add forced_subs tests/test_forced_subs_report.sh
git commit -m "Add forced_subs report subcommand"
```

---

### Task 10: Cron wiring, fresh_install.sh, and first real run

Not TDD (this is deployment config + a manual verification pass, not new logic), but still ends in a concrete, checkable deliverable per the spec's "Deployment" section.

**Files:**
- Modify: `crontab.txt`
- Modify: `fresh_install.sh`

**Interfaces:**
- Consumes: `forced_subs` (Tasks 6-9), `scripts/decrypt_secrets.sh` (Task 2).

- [ ] **Step 1: Add cron entries to `crontab.txt`**

Append, following the existing comment style in the file:

```
# Forced-subtitle scanner (see docs/superpowers/specs/2026-09-14-forced-
# subtitle-scanner-design.md). identify is weekly - new films arrive rarely,
# and already-cached files are skipped, so this only has to pick up what's
# new since last time. apply is daily and rate-limited internally
# (--max-downloads) to stay within the OpenSubtitles free-tier quota.
0 4 * * Sun cd /home/pi/Home_PI4_bin && ./forced_subs identify --quiet >>/home/pi/logs/forced_subs_identify_logfile 2>&1
0 5 * * * cd /home/pi/Home_PI4_bin && ./forced_subs apply --quiet
```

(Adjust `/home/pi/Home_PI4_bin` if this repo is checked out elsewhere on the Pi — match whatever path `convert_video`/`films_backup` already use in the live crontab.)

- [ ] **Step 2: Add a fresh_install.sh checklist note**

Find fresh_install.sh's existing per-service checklist pattern (STEP 19's summary, per the Global Constraints / Task 2's ported secrets notes) and add, in the same style as the existing `secrets.yaml` recovery notes:

```
echo "  [ ] forced_subs: verify secrets.yaml has real opensubtitles.api_key/"
echo "      username/password (STEP 12-equivalent - same caveat as home_automation's"
echo "      secrets.yaml above). Run 'cd ~/Home_PI4_bin && ./forced_subs identify'"
echo "      once by hand against the full library before relying on the cron jobs,"
echo "      so any 'unresolved' entries can be reviewed/fixed with --set first."
```

- [ ] **Step 3: Commit**

```bash
git add crontab.txt fresh_install.sh
git commit -m "Wire forced_subs into crontab.txt and fresh_install.sh"
```

- [ ] **Step 4: First real run (manual, on the Pi — not part of this repo's automated tests)**

```bash
ssh pi@100.102.156.19
cd ~/Home_PI4_bin && git pull
./forced_subs identify          # full library, takes a while the first time
./forced_subs report --verbose  # see what needs manual attention right now
```

Review anything under "you'll need to sort these out yourself" with reason `ambiguous_title_multiple_years` or `no_match` — resolve genuine curated-list gaps with `--set`, or add missing titles/aliases/the 2026 Moana entry (once its IMDb ID/runtime are known) to `forced_subs_known_films.yaml`.

`report` also leaves `/mnt/HDD/films/_FORCED_SUBTITLES_REPORT.txt` on the share itself (Task 9), so this same summary is browsable without SSH-ing back in. `apply` is deliberately not run by hand here — it's rate-limited to `--max-downloads` per day by design (Task 8), so fixing the whole backlog happens gradually via the cron job over the following days/weeks, not in this one session.

---

## Self-Review Notes

- **Spec coverage:** Phase 0 identify → Task 6; Phase 1 scan → Task 7 (including the "Incremental scanning" cache: `scan_cache_get`/`scan_cache_set`, keyed on `file_stat_signature`, skips re-probing an unchanged `HAS_FORCED` file — verified in Task 7's test by disabling `convert_video` via `FORCED_SUBS_CONVERT_VIDEO` and confirming the cached file still reports correctly); Phase 2 apply → Task 8 (including sidecar-`.srt` shortcut, hash-then-imdb fallback, atomic swap, 7-day unavailable cache, rate limiting); Reporting → Task 9 (including writing `$REPORT_FILE`, default `$FILMS_ROOT/_FORCED_SUBTITLES_REPORT.txt`, alongside stdout); Secrets mechanism → Task 2; `.gitignore` → Task 1; Deployment → Task 10 (cron spreads `apply` over days automatically via its daily `--max-downloads` cap, per the user's "over a number of days" request — no separate scheduling logic needed beyond what Task 8 already does). All three of the spec's original "Open items" are resolved: known-films seed list (Task 5), `--max-downloads` default of 5 with a note to tune it (Task 8, Global Constraints), and the test-stubbing mechanism (fake `ost.py` swapped in via `FORCED_SUBS_LIBDIR`, used in Tasks 6/8).
- **Placeholder scan:** no TBD/"add error handling"/"similar to Task N" left in any step; the one deliberately-omitted value (the 2026 Moana IMDb ID/runtime in Task 5) is explicitly flagged as omitted-on-purpose with instructions for the user to fill it in, not a plan gap.
- **Type/name consistency checked:** `fid_cache_get_field`/`fid_cache_set` field order (imdb_id, title, year, confidence, reason, last_checked) matches between Task 3's implementation, Task 6's `forced_subs_identify_one`/`cmd_identify_set`, and Task 7's `cmd_scan`. `cmd_scan`'s eight-column TSV output order (`bucket, path, imdb_id, title, edition, coverage, external, reason`) matches how Task 8's `cmd_apply` and Task 9's `report_body` both destructure it with `IFS=$'\t' read -r bucket file imdb_id title edition coverage external reason`. `scan_cache_set`'s stored row (`path, sig, <result_line>`) matches what `scan_cache_get` + `cmd_scan`'s cache-hit branch expect (`cut -f2` for signature, `cut -f3` for bucket, `cut -f3-` to replay the original 8-field line). `known_films.py`'s `lookup`/`find_by_title_year` output shapes match every caller in Tasks 6/7/9. `ost.py`'s subcommand names/output shapes match every caller in Tasks 6/8. `cmd_report` (thin wrapper: `report_body | tee "$REPORT_FILE"`) is what Task 9's dispatch case and test both call — `report_body` itself is not called directly from `main`.
