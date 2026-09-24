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

# Compares the file's actual duration (minutes) against an editions string
# ("name:minutes,name:minutes") and returns the closest name within a
# 3-minute tolerance, or "unmatched_edition". Shared by forced_subs's
# cmd_scan and convert_video, so the "which cut is this file really" logic
# behind find_forced_subtitle's edition-safety check is identical either
# way it gets triggered.
pick_edition() {
    local file="$1" editions="$2"
    # An empty editions string is routine (any resolved-but-uncurated film
    # reaches here with no curated edition data at all) - bail before the
    # array split below, which under `set -u` treats a fully-empty
    # herestring as leaving "parts" undeclared rather than a one-element
    # empty array, and "${parts[@]}" on that is an unbound-variable error.
    [ -z "$editions" ] && { echo "unmatched_edition"; return; }
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

# TMDB (see lib/tmdb.py) is entirely optional - it only powers identify's
# 4th, last-resort tier, and identify_film_from_file already checks
# TMDB_API_KEY is non-empty before ever attempting to use it. A
# secrets.yaml with no `tmdb:` section at all just means that tier never
# fires, same as any other missing optional credential.
load_tmdb_creds() {
    local secrets_yaml="$1"
    TMDB_API_KEY=$(yaml_get_2level "$secrets_yaml" tmdb api_key)
    export TMDB_API_KEY
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
# quota_exceeded, hash_search_failed, imdb_search_failed. Returns 0 for success, 1
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
    python3 "$libdir/ost.py" download "$sub_file_id" "$srt_path" >>"$err_log" 2>&1
    local download_rc=$?
    if [ "$download_rc" -eq 3 ]; then
        # ost.py's QUOTA_EXIT_CODE: the daily download quota is used up.
        # Says nothing about this film, so it must not be cached as one.
        rm -f "$srt_path"
        printf 'quota_exceeded\t'
        return 1
    fi
    if [ "$download_rc" -ne 0 ] || [ ! -s "$srt_path" ]; then
        rm -f "$srt_path"
        printf 'download_failed\t'
        return 1
    fi
    printf 'success\t%s' "$srt_path"
}

# Sums each SRT cue's (end - start) duration from its timestamp lines
# (HH:MM:SS,mmm --> HH:MM:SS,mmm), converts to seconds, and returns that
# total as a percentage of the given video duration (also in seconds).
# Mirrors convert_video's own forced-vs-full-track coverage heuristic,
# applied here to a standalone sidecar/downloaded file instead of an
# embedded stream. If video_duration isn't a positive number, coverage
# can't be computed - default to "100" (i.e. treat it as a full/
# untrustworthy track) rather than divide by zero.
srt_coverage_percent() {
    local srt_file="$1" video_duration="$2"
    [ -f "$srt_file" ] || { echo "100"; return; }
    awk -F' --> ' -v dur="$video_duration" '
        function to_seconds(t,   h, m, s) {
            gsub(",", ".", t)
            split(t, parts, ":")
            h = parts[1]; m = parts[2]; s = parts[3]
            return h * 3600 + m * 60 + s
        }
        /-->/ {
            total += to_seconds($2) - to_seconds($1)
        }
        END {
            if (dur + 0 > 0) {
                printf "%.2f", (total / dur) * 100
            } else {
                printf "100"
            }
        }
    ' "$srt_file"
}

# Muxes a forced-English subtitle into an existing video file: stream-copy
# only (no re-encode), verifies the result before committing (duration
# unchanged, a real forced-disposition stream present, non-trivial cue
# coverage), and preserves the original file's mtime across the swap -
# adding a subtitle track isn't a meaningful content change from the
# user's point of view (media-server "recently added" sorting, backup
# tooling, etc. shouldn't treat it as one). Shared by forced_subs's
# cmd_apply (a whole-library batch) and convert_video's own post-encode
# fetch (a single file, right after conversion finishes).
remux_forced_subtitle() {
    local file="$1" srt="$2"
    local ext="${file##*.}"
    local sub_codec="mov_text"
    [ "$ext" = "mkv" ] && sub_codec="srt"
    local tmp_out
    tmp_out="$(mktemp -u "$(dirname "$file")/.forced_subs_remux.XXXXXX").$ext"
    # Belt-and-suspenders: covers a killed process (kill -9 on the whole
    # tree) leaves this cleanup unrun, but any normal return path (error or
    # success) from this function cleans up the temp file here. Bash's
    # RETURN trap is NOT function-scoped in practice - once set, it keeps
    # firing on every later function return up the call stack (the
    # caller's own return) unless explicitly disarmed - so every exit path
    # below disarms it (`trap - RETURN`) right before returning.
    trap 'rm -f "$tmp_out"' RETURN

    # </dev/null is required: forced_subs's cmd_apply calls this from
    # inside its own `while read ... done < <(cmd_scan)` loop, and without
    # it ffmpeg would treat that inherited pipe as an interactive control
    # channel and compete with the read loop for the same data (see the
    # matching note in convert_video's analyze_subtitles, where this was
    # first found).
    if ! ffmpeg -y -i "$file" -i "$srt" \
        -map 0:v -map 0:a -map 1:s -map 0:s? -map 0:t? \
        -c copy -c:s:0 "$sub_codec" \
        -metadata:s:s:0 language=eng -disposition:s:0 forced \
        "$tmp_out" -hide_banner -loglevel error </dev/null; then
        rm -f "$tmp_out"
        trap - RETURN
        return 1
    fi

    local orig_dur new_dur has_forced
    orig_dur=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null | cut -d. -f1)
    new_dur=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$tmp_out" 2>/dev/null | cut -d. -f1)
    has_forced=$(ffprobe -v error -select_streams s -show_entries stream_disposition=forced -of csv=p=0 "$tmp_out" 2>/dev/null | grep -c '^1$' || true)

    if [ "$orig_dur" != "$new_dur" ] || [ "${has_forced:-0}" -lt 1 ]; then
        rm -f "$tmp_out"
        trap - RETURN
        return 1
    fi

    # A stream can be flagged "forced" with essentially no actual timed
    # content (a bad/near-empty subtitle match) - cmd_scan's own
    # has_real_forced check requires >0% coverage before it will ever call
    # a file HAS_FORCED, so accepting a genuinely-empty (0%) match here as
    # "success" would leave the file endlessly re-selected as a
    # NEEDS_FORCED_KNOWN candidate on every future run - silently burning
    # a real, rate-limited download credit each time with no way to ever
    # actually finish. Requiring the same >0% floor here, before the swap,
    # is what makes apply's success and scan's HAS_FORCED agree. (Not a
    # higher floor like 15%: genuine forced-subtitle content is typically
    # well under 10% of a film's runtime - see the matching note on
    # cmd_scan's has_real_forced check.)
    local video_duration coverage_pct
    video_duration=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$tmp_out" 2>/dev/null)
    coverage_pct=$(srt_coverage_percent "$srt" "$video_duration")
    if ! awk -v c="$coverage_pct" 'BEGIN{exit !(c>0)}'; then
        rm -f "$tmp_out"
        trap - RETURN
        return 1
    fi

    touch -r "$file" "$tmp_out" 2>/dev/null || true
    mv "$tmp_out" "$file"
    trap - RETURN
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
            elif [ -n "${TMDB_API_KEY:-}" ]; then
                # Last resort: TMDB has runtime data OpenSubtitles'
                # search doesn't, which lets it safely tell apart a
                # title collision (a remake/sequel sharing the exact
                # same name, e.g. "Jurassic Park" vs "Jurassic World",
                # "The Lion King" 1994 vs 2019) that ost.py's
                # search_by_title could only ever call ambiguous. See
                # tmdb.py's pick_candidate for the exact-title+runtime
                # matching discipline - it never guesses either.
                local file_duration_min tmdb_result
                file_duration_min=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null | awk '{printf "%d", $1/60}')
                tmdb_result=$(python3 "$libdir/tmdb.py" identify "$norm_title" "$year_guess" "$file_duration_min" 2>/dev/null || true)
                if [ -n "$tmdb_result" ]; then
                    IFS=$'\t' read -r imdb_id title year <<< "$tmdb_result"
                    confidence="tmdb"
                else
                    confidence="unresolved"; reason="no_match"
                fi
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

# scan_cache row: path \t file_stat_signature \t <the 8-field result line> \t
# checked_date. See "Incremental scanning" in the spec: lets cmd_scan skip
# re-probing a file whose size/mtime haven't changed since it was last
# checked. A HAS_FORCED result is trusted indefinitely on that basis alone;
# any other bucket is also trusted, but only for SCAN_FRESHNESS_DAYS (see
# cmd_scan) - or until fid_cache_set below invalidates it directly, for a
# file whose *identify* result changed underneath an otherwise-untouched
# scan_cache entry (the file itself has the same stat signature either
# way, so that alone would never notice).
scan_cache_get() {
    local file="$1" cache="${SCAN_CACHE:-/home/pi/logs/forced_subs_scan_cache}"
    [ -f "$cache" ] || return 1
    awk -F'\t' -v p="$file" '$1==p {print; found=1} END{exit !found}' "$cache"
}

scan_cache_set() {
    local file="$1" sig="$2" result_line="$3" checked_date="${4:-$(date -I)}"
    local cache="${SCAN_CACHE:-/home/pi/logs/forced_subs_scan_cache}"
    mkdir -p "$(dirname "$cache")"
    touch "$cache"
    local tmp; tmp=$(mktemp)
    awk -F'\t' -v p="$file" '$1 != p' "$cache" > "$tmp"
    printf '%s\t%s\t%s\t%s\n' "$file" "$sig" "$result_line" "$checked_date" >> "$tmp"
    mv "$tmp" "$cache"
}

# Drops a file's scan_cache row entirely (as opposed to scan_cache_set,
# which replaces it) - the next cmd_scan call for this file re-probes it
# from scratch regardless of freshness, since there's nothing cached to
# replay. A no-op if the file has no cached row or SCAN_CACHE doesn't
# exist yet.
scan_cache_invalidate() {
    local file="$1" cache="${SCAN_CACHE:-/home/pi/logs/forced_subs_scan_cache}"
    [ -f "$cache" ] || return 0
    local tmp; tmp=$(mktemp)
    awk -F'\t' -v p="$file" '$1 != p' "$cache" > "$tmp"
    mv "$tmp" "$cache"
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
    # If this identify result actually changed the imdb_id (most notably
    # unresolved -> resolved, e.g. a later --rehash succeeding where an
    # earlier attempt didn't), any scan_cache row for this file is now
    # answering a question that's no longer true - the file's own stat
    # signature never changed, so scan's freshness check would otherwise
    # keep replaying the stale bucket for up to SCAN_FRESHNESS_DAYS
    # regardless. Read the previous value with the OLD cache contents,
    # before they're overwritten below.
    local previous_imdb_id
    previous_imdb_id=$(fid_cache_get_field "$file" imdb_id 2>/dev/null || true)
    local tmp; tmp=$(mktemp)
    awk -F'\t' -v path="$file" '$1 != path' "$cache" > "$tmp"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$file" "$imdb_id" "$title" "$year" "$confidence" "$reason" "$checked" >> "$tmp"
    mv "$tmp" "$cache"
    if [ "$previous_imdb_id" != "$imdb_id" ]; then
        scan_cache_invalidate "$file"
    fi
}

# Called by convert_video once conversion finishes, only when nothing else
# already provided a subtitle for that file. Identifies the film via the
# same three-tier chain forced_subs uses (hash match, curated filename
# fallback, OpenSubtitles title-search) and, on a confident match, fetches
# and muxes in a forced-English subtitle. When identification is ambiguous
# or fails outright, prompts interactively - unlike forced_subs's own
# unattended batch runs, a person is right here to resolve it. Purely a
# bonus step: never fails the caller's conversion, and any outcome (or
# skip) is just reported to the user via stdout.
maybe_fetch_forced_subtitle() {
    local file="$1" libdir="$2" known_films_yaml="$3" secrets_yaml="$4"

    load_opensubtitles_creds "$secrets_yaml"
    if [ -z "$OST_API_KEY" ] || [ -z "$OST_USERNAME" ] || [ -z "$OST_PASSWORD" ]; then
        echo "(Skipping forced-subtitle fetch: OpenSubtitles credentials not configured in $secrets_yaml.)"
        return 0
    fi
    load_tmdb_creds "$secrets_yaml"

    echo ""
    echo "Checking OpenSubtitles for a forced-English subtitle..."
    local identified imdb_id title year confidence reason
    identified=$(identify_film_from_file "$file" "$libdir" "$known_films_yaml")
    imdb_id=$(printf '%s' "$identified" | cut -f1)
    title=$(printf '%s' "$identified" | cut -f2)
    year=$(printf '%s' "$identified" | cut -f3)
    confidence=$(printf '%s' "$identified" | cut -f4)
    reason=$(printf '%s' "$identified" | cut -f5)

    if [ -n "$imdb_id" ]; then
        echo "Identified as: ${title:-$imdb_id} ${year:+($year)} [$confidence]"
    else
        local norm_title year_guess
        norm_title=$(normalize_title_from_path "$file")
        year_guess=$(extract_year_from_name "$(basename "$file")")
        if [ "$reason" = "ambiguous_title_multiple_years" ]; then
            echo "Multiple curated titles match \"$norm_title\" and no year in the filename disambiguates:"
            local candidates candidate_ids=() i=0
            candidates=$(python3 "$libdir/known_films.py" find_by_title_year "$known_films_yaml" "$norm_title" "$year_guess")
            while IFS=$'\t' read -r cand_id cand_title cand_year; do
                [ -n "$cand_id" ] || continue
                i=$((i + 1))
                candidate_ids+=("$cand_id")
                echo "  $i) $cand_title ($cand_year) - $cand_id"
            done <<< "$candidates"
            read -p "Pick a number, type an IMDb ID directly (e.g. tt1234567), or press enter to skip: " pick
            if [[ "$pick" =~ ^[0-9]+$ ]] && [ "$pick" -ge 1 ] && [ "$pick" -le "${#candidate_ids[@]}" ]; then
                imdb_id="${candidate_ids[$((pick - 1))]}"
            elif [[ "$pick" =~ ^tt[0-9]+$ ]]; then
                imdb_id="$pick"
            fi
        else
            read -p "Couldn't identify this film automatically. Type an IMDb ID (e.g. tt1234567) to fetch a forced subtitle, or press enter to skip: " pick
            [[ "$pick" =~ ^tt[0-9]+$ ]] && imdb_id="$pick"
        fi
        if [ -z "$imdb_id" ]; then
            echo "Skipping forced-subtitle fetch."
            return 0
        fi
        # A manual resolution is sticky and shared with forced_subs's own
        # fid_cache, exactly like `forced_subs identify --set` - a later
        # `forced_subs identify` won't redundantly re-attempt this file.
        fid_cache_set "$file" "$imdb_id" "" "" "manual" "" "$(date +%Y-%m-%d)"
    fi

    local lookup editions_str edition
    lookup=$(python3 "$libdir/known_films.py" lookup "$known_films_yaml" "$imdb_id" 2>/dev/null || true)
    IFS=$'\t' read -r _ _ editions_str <<< "$lookup"
    edition=$(pick_edition "$file" "$editions_str")

    if ! opensubtitles_login "$secrets_yaml" "$libdir"; then
        echo "(Could not log in to OpenSubtitles - skipping forced-subtitle fetch.)"
        return 0
    fi

    local find_result status srt_path
    find_result=$(find_forced_subtitle "$file" "$imdb_id" "$edition" "$known_films_yaml" "$libdir" /dev/null)
    status=$(printf '%s' "$find_result" | cut -f1)
    srt_path=$(printf '%s' "$find_result" | cut -f2)

    case "$status" in
        success)
            if remux_forced_subtitle "$file" "$srt_path"; then
                echo "Forced-English subtitle added."
            else
                echo "(Found a forced subtitle but muxing it in failed - left as-is.)"
            fi
            rm -f "$srt_path"
            ;;
        no_match_found)
            echo "(No forced-English subtitle available on OpenSubtitles for this film.)"
            ;;
        ambiguous)
            echo "(Found a subtitle candidate but couldn't safely confirm it matches this file's edition - skipped.)"
            ;;
        download_failed)
            echo "(Found a forced subtitle but downloading it failed - skipped.)"
            ;;
        quota_exceeded)
            echo "(Found a forced subtitle but today's OpenSubtitles download quota is used up - try again tomorrow.)"
            ;;
        hash_search_failed|imdb_search_failed)
            echo "(OpenSubtitles search failed - network or API issue. Skipped.)"
            ;;
    esac
}
