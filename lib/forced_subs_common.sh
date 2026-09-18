# lib/forced_subs_common.sh - shared helpers for the forced_subs script.
# Sourced, never executed.

walk_films() {
    local root="$1"
    find "$root" -type d -name "Our Family" -prune -o -type f \
        \( -iname "*.mp4" -o -iname "*.mkv" -o -iname "*.m4v" -o -iname "*.avi" \) \
        -not -name ".forced_subs_remux.*" -print
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
        -e 's/(^|[^A-Za-z0-9])(1080p)([^A-Za-z0-9]|$)/\1\3/gI' \
        -e 's/(^|[^A-Za-z0-9])(2160p)([^A-Za-z0-9]|$)/\1\3/gI' \
        -e 's/(^|[^A-Za-z0-9])(720p)([^A-Za-z0-9]|$)/\1\3/gI' \
        -e 's/(^|[^A-Za-z0-9])(4K)([^A-Za-z0-9]|$)/\1\3/gI' \
        -e 's/(^|[^A-Za-z0-9])(BluRay)([^A-Za-z0-9]|$)/\1\3/gI' \
        -e 's/(^|[^A-Za-z0-9])(BRRip)([^A-Za-z0-9]|$)/\1\3/gI' \
        -e 's/(^|[^A-Za-z0-9])(WEBRip)([^A-Za-z0-9]|$)/\1\3/gI' \
        -e 's/(^|[^A-Za-z0-9])(WEB-DL)([^A-Za-z0-9]|$)/\1\3/gI' \
        -e 's/(^|[^A-Za-z0-9])(x264)([^A-Za-z0-9]|$)/\1\3/gI' \
        -e 's/(^|[^A-Za-z0-9])(x265)([^A-Za-z0-9]|$)/\1\3/gI' \
        -e 's/(^|[^A-Za-z0-9])(HEVC)([^A-Za-z0-9]|$)/\1\3/gI' \
        -e 's/(^|[^A-Za-z0-9])(H264)([^A-Za-z0-9]|$)/\1\3/gI' \
        -e 's/(^|[^A-Za-z0-9])(H265)([^A-Za-z0-9]|$)/\1\3/gI' \
        -e 's/(^|[^A-Za-z0-9])(AAC)([^A-Za-z0-9]|$)/\1\3/gI' \
        -e 's/(^|[^A-Za-z0-9])(DTS)([^A-Za-z0-9]|$)/\1\3/gI' \
        -e 's/[[:space:]]+/ /g' \
        -e 's/ [-_]([A-Za-z0-9])/ \1/g' \
        -e 's/^[[:space:]]+|[[:space:]]+$//g')
    printf '%s' "$base"
}

imdb_tt_to_numeric() {
    printf '%s' "${1#tt}" | sed 's/^0*//'
}

# Shared by forced_subs and convert_video - both read the same
# secrets.yaml/opensubtitles credentials and talk to the same OpenSubtitles
# account, so neither should have its own copy of this. load_opensubtitles_creds
# never fails on its own (callers that need real credentials check for
# empty values, or use opensubtitles_login below which does that check).
load_opensubtitles_creds() {
    local secrets_yaml="$1"
    OST_API_KEY=$(yaml_get_2level "$secrets_yaml" opensubtitles api_key)
    OST_USERNAME=$(yaml_get_2level "$secrets_yaml" opensubtitles username)
    OST_PASSWORD=$(yaml_get_2level "$secrets_yaml" opensubtitles password)
    OST_USER_AGENT="forced_subs v1.0.0"
    export OST_API_KEY OST_USERNAME OST_PASSWORD OST_USER_AGENT
}

# Returns 1 (does not exit the caller's process - this is a library
# function, shared by a batch script and an interactive one with very
# different failure-handling needs) if credentials are missing or login
# fails; prints an explanatory message to stderr either way.
opensubtitles_login() {
    local secrets_yaml="$1" libdir="$2"
    load_opensubtitles_creds "$secrets_yaml"
    if [ -z "$OST_API_KEY" ] || [ -z "$OST_USERNAME" ] || [ -z "$OST_PASSWORD" ]; then
        echo "ERROR: OpenSubtitles credentials missing from $secrets_yaml (opensubtitles.api_key/username/password)." >&2
        return 1
    fi
    OST_TOKEN=$(python3 "$libdir/ost.py" login)
    if [ -z "$OST_TOKEN" ]; then
        echo "ERROR: OpenSubtitles login failed - check credentials/network." >&2
        return 1
    fi
    export OST_TOKEN
}

# Checks a subtitle search result's release-name string against a
# resolved curated edition name (e.g. "extended", "theatrical") for an
# EXPLICIT conflict, using a small closed vocabulary of English edition-
# distinguishing terms rather than the video's own duration: a forced-
# subtitle track only covers foreign-language dialogue scenes, so its
# last cue can legitimately sit long before the credits even for a
# correctly-matched candidate (proven directly against a real
# OpenSubtitles response for The Fellowship of the Ring's extended cut,
# whose last forced cue lands 46 minutes before the film's actual end -
# a naive "last cue vs video duration" comparison rejected that exact,
# correctly-labelled ("...[Extended]...") candidate). Deliberately NOT
# derived from the curated YAML edition names themselves, which
# sometimes mix in unrelated source-format tokens (e.g. "2011_bluray")
# that would false-positive against an ordinary BluRay-sourced release
# regardless of its actual cut. Prints "1" (conflict - do not trust this
# candidate) if the release name contains one of these terms other than
# the one already established for this file; "0" otherwise.
edition_label_conflict() {
    local resolved_lc release_lc kw
    resolved_lc=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    release_lc=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')
    for kw in extended director unrated theatrical; do
        case "$resolved_lc" in *"$kw"*) continue ;; esac
        case "$release_lc" in *"$kw"*) echo "1"; return ;; esac
    done
    echo "0"
}

# Searches for and downloads a forced-English subtitle for one file:
# edition-exact moviehash search first, falling back to the runtime-
# unfiltered IMDb search (guarded by edition_label_conflict for titles
# with real multiple cuts - see known_films.yaml). Shared by forced_subs's
# cmd_apply (which wraps this with its own rate-limiting/consecutive-error
# bookkeeping for a whole-library run) and convert_video's single-file,
# interactive fetch - neither duplicates this logic.
#
# Prints "status\tsrt_path" on stdout - srt_path is only populated when
# status is "success" (a temp file the caller owns and must clean up).
# status is one of: success, no_match_found, ambiguous, download_failed,
# hash_search_failed, imdb_search_failed. Returns 0 for success, 1
# otherwise. err_log receives ost.py's own stderr (pass /dev/null to
# discard it).
find_forced_subtitle() {
    local file="$1" imdb_id="$2" edition="$3" known_films_yaml="$4" libdir="$5" err_log="${6:-/dev/null}"
    local hash result
    hash=$(python3 "$libdir/ost.py" hash "$file")
    result=$(python3 "$libdir/ost.py" find_forced_by_hash "$hash" 2>>"$err_log")
    if [ $? -ne 0 ]; then
        printf 'hash_search_failed\t'
        return 1
    fi

    local edition_count=0
    if [ -z "$result" ]; then
        # Bounded sanity check (spec: "sanity-checked against the matched
        # edition's expected runtime... if still ambiguous, log as
        # ambiguous") - the IMDb fallback has no release/runtime
        # filtering at all, so for a film with multiple curated editions
        # (e.g. theatrical vs extended) it could mux a wrong-cut subtitle
        # in permanently. If scan couldn't confidently resolve which cut
        # THIS file actually is either (edition="unmatched_edition"),
        # there's no basis to verify anything - bail now rather than
        # spend an API call. Otherwise, verify the candidate's own
        # release name below once it's in hand.
        local lookup editions_str
        lookup=$(python3 "$libdir/known_films.py" lookup "$known_films_yaml" "$imdb_id" 2>/dev/null || true)
        IFS=$'\t' read -r _ _ editions_str <<< "$lookup"
        edition_count=$(printf '%s' "$editions_str" | tr ',' '\n' | grep -c .)
        if [ "$edition_count" -gt 1 ] && { [ -z "$edition" ] || [ "$edition" = "unmatched_edition" ]; }; then
            printf 'ambiguous\t'
            return 1
        fi

        local imdb_numeric
        imdb_numeric=$(imdb_tt_to_numeric "$imdb_id")
        result=$(python3 "$libdir/ost.py" find_forced_by_imdb "$imdb_numeric" 2>>"$err_log")
        if [ $? -ne 0 ]; then
            printf 'imdb_search_failed\t'
            return 1
        fi

        if [ -z "$result" ]; then
            printf 'no_match_found\t'
            return 1
        fi

        # This candidate came from the runtime-unfiltered IMDb fallback
        # (never the hash path, which is already edition-exact) - for a
        # multi-edition title, confirm its release name doesn't
        # explicitly claim to be a different cut than the one scan
        # already determined this file to be, before spending a download
        # on it.
        if [ "$edition_count" -gt 1 ]; then
            local release_name
            release_name=$(printf '%s' "$result" | cut -f2)
            if [ "$(edition_label_conflict "$edition" "$release_name")" = "1" ]; then
                printf 'ambiguous\t'
                return 1
            fi
        fi
    fi

    local sub_file_id srt_path
    sub_file_id=$(printf '%s' "$result" | cut -f1)
    srt_path="$(mktemp -u "${TMPDIR:-/tmp}/forced_subs_sub.XXXXXX").srt"
    if ! python3 "$libdir/ost.py" download "$sub_file_id" "$srt_path" >>"$err_log" 2>&1 || [ ! -s "$srt_path" ]; then
        rm -f "$srt_path"
        printf 'download_failed\t'
        return 1
    fi
    printf 'success\t%s' "$srt_path"
}

# The shared three-tier identification chain: hash match, then the curated
# known_films.yaml filename fallback, then OpenSubtitles' own title-search
# as a last resort. Pure - no caching, no side effects - so both
# forced_subs (which wraps this with fid_cache reads/writes) and
# convert_video (which calls this directly for a single file, no cache)
# can share exactly the same logic. Prints
# "imdb_id\ttitle\tyear\tconfidence\treason" (reason only set when
# confidence is "unresolved"); imdb_id/title/year are empty when
# unresolved.
identify_film_from_file() {
    local file="$1" libdir="$2" known_films_yaml="$3"
    local imdb_id="" title="" year="" confidence reason=""
    local hash hash_result
    hash=$(python3 "$libdir/ost.py" hash "$file")
    hash_result=$(python3 "$libdir/ost.py" identify_by_hash "$hash" 2>/dev/null || true)

    if [ -n "$hash_result" ]; then
        IFS=$'\t' read -r imdb_id title year <<< "$hash_result"
        confidence="hash"
    else
        local norm_title year_guess fallback_result count
        norm_title=$(normalize_title_from_path "$file")
        year_guess=$(extract_year_from_name "$(basename "$file")")
        fallback_result=$(python3 "$libdir/known_films.py" find_by_title_year "$known_films_yaml" "$norm_title" "$year_guess")
        count=$(printf '%s\n' "$fallback_result" | grep -c . || true)
        if [ "$count" -eq 1 ]; then
            IFS=$'\t' read -r imdb_id title year <<< "$fallback_result"
            confidence="filename"
        elif [ "$count" -gt 1 ]; then
            confidence="unresolved"; reason="ambiguous_title_multiple_years"
        else
            # Neither the hash match nor the curated known_films.yaml
            # list resolved this file - try OpenSubtitles' own movie
            # title-search as a last resort before giving up. This is
            # exact-match only (see ost.py's pick_title_match) and never
            # guesses, so it's safe to fall back to unconditionally.
            local search_result
            search_result=$(python3 "$libdir/ost.py" search_by_title "$norm_title" "$year_guess" 2>/dev/null || true)
            if [ -n "$search_result" ]; then
                IFS=$'\t' read -r imdb_id title year <<< "$search_result"
                confidence="title_search"
            else
                confidence="unresolved"; reason="no_match"
            fi
        fi
    fi
    printf '%s\t%s\t%s\t%s\t%s' "$imdb_id" "$title" "$year" "$confidence" "$reason"
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
    awk -v top="$top_key:" -v subkey="$sub_key" '
        $0 == top { in_block=1; next }
        /^[^ \t]/ { in_block=0 }
        in_block {
            line=$0
            sub(/^[ \t]+/, "", line)
            pattern = "^" subkey ":"
            if (line ~ pattern) {
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
