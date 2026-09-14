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
