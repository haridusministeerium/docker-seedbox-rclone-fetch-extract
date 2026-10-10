#!/usr/bin/env bash
#
# This script remuxes blu-ray folder into an mkv.
#
# NOTE: optionally might consider re-encoding to shrink the file:
#    ffmpeg -i "$OUTPUT" -map 0 -c:v libx265 -crf 20 -preset slow \
#           -c:a copy -c:s copy "${OUTPUT}.x265.mkv"
#
########################################################

readonly SELF="${0##*/}"
DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"  # location of this script

#ASSET="$(realpath -- "$1")"
ASSET="$1"
JOB_ID="$PPID"  # PID of the calling sync.sh process

OUTPUT="$ASSET/out.mkv"
#MIN_FREE_SPACE_GB=${MIN_FREE_SPACE_GB:-2}  # in GB; we must estimate min. this amount of free disk space left _after_ vob merge, otherwise skip.


## ENTRY
readarray -t BR_PLAYLISTS < <(find "$ASSET/BDMV/PLAYLIST" -type f -iname '*.mpls' 2>/dev/null)
[[ "${#BR_PLAYLISTS[@]}" -eq 0 ]] && exit 0  # not processing a BR input, bail

source /common.sh || { echo -e "    ERROR: failed to import /common.sh"; exit 1; }

[[ -e "$OUTPUT" ]] && fail "[$OUTPUT] output already exists"  # sanity
[[ -d "$ASSET" ]] || fail "input [$ASSET] is not a dir"
cd -- "$ASSET" || fail  # cd just in case, but should not be needed

# list all playlists with their durations in minutes:
info '-> playlist files by duration in minutes:'
for f in "${BR_PLAYLISTS[@]}"; do
  mkvmerge -J "$f" | jq -r --arg f "$f" \
    '"\((.container.properties.playlist_duration // 0) / 6e10 | floor) min\t\($f)"'
done | sort -nr | while IFS= read -r line; do
  info "  - $line"
done

# It sorts by duration descending, then by size as a tiebreaker, and takes the top entry:
best=$(for f in "${BR_PLAYLISTS[@]}"; do
         mkvmerge -J "$f" 2>/dev/null \
           | jq -r --arg f "$f" \
             '[.container.properties.playlist_duration // 0,
               .container.properties.playlist_size // 0,
               $f] | @tsv'
       done | sort -t$'\t' -k1,1nr -k2,2nr | head -1 | cut -f3)
[[ -s "$best" ]] || fail "couldn't find the best playlist in [$ASSET]"  # sanity

info "main BluRay playlist detected: $best"
info "merging BR files in [$ASSET] into [$OUTPUT]..."

mkvmerge -o "$OUTPUT" "$best"
e=$?
[[ "$e" -gt 1 ]] && fail "mkvmerge failed w/ $e"  # note exit 1 for mkvmerge means only a warning

info "merged into [$OUTPUT]"

# delete BR files:
if [[ -z "$SKIP_BR_RM" ]]; then
    while IFS= read -r -d $'\0' f; do
        [[ "$f" != "$OUTPUT" ]] && rm -rf -- "$f"
    done < <(find "$ASSET" -maxdepth 1 -mindepth 1 -print0)
fi

exit 0

