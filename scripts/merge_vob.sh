#!/usr/bin/env bash
#
# This script merges DVD .VOB files together
#
# To get metadata about vob files:
#  - mkvmerge --identification-format json --identify VTS_01_1.VOB
# To get file duration, try:
#  - mediainfo --Inform="General;%Duration%" VTS_01_0.VOB
#  - ffprobe -v error -show_entries format=duration -of csv=p=0 VTS_01_0.VOB
########################################################

readonly SELF="${0##*/}"
DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"  # location of this script

ASSET="$1"
JOB_ID="$PPID"  # PID of the calling sync.sh process

OUTPUT="$ASSET/out.mkv"
MIN_DURATION=60   # ignore clips shorter than this (seconds)
MIN_FREE_SPACE_GB=${MIN_FREE_SPACE_GB:-2}  # in GB; we must estimate min. this amount of free disk space left _after_ vob merge, otherwise skip.


## ENTRY
#readarray -t VOBS < <(find "$ASSET" -type f -size +100M -name 'VTS_*.VOB' | sort -V)
readarray -t VOBS < <(find "$ASSET" -type f -name 'VTS_*.VOB' | sort -V)
[[ "${#VOBS[@]}" -eq 0 ]] && exit 0  # not processing a DVD input, bail

source /common.sh || { echo -e "    ERROR: failed to import /common.sh"; exit 1; }

[[ -e "$OUTPUT" ]] && fail "[$OUTPUT] output already exists"  # sanity
[[ -d "$ASSET" ]] || fail "input [$ASSET] is not a dir"
cd -- "$ASSET" || fail  # cd just in case, but should not be needed

declare -A VTS_ID_TO_DURATION
declare -a WHITELISTED_FILES  INPUT

# Step 1: group VOBs by VTS and sum durations.
#         usually VTS_01_* contains the main movie, but we'll select whatever
#         has the longest duration.
for f in "${VOBS[@]}"; do
    # Extract VTS ID (e.g. VTS_01):
    duration=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$f")
    is_decimal "$duration" || { err "[$f] duration looks off: [$duration]"; continue; }

    # Skip very short clips (menus/extras), e.g. VTS_01_0.VOB
    (( $(bc <<< "$duration < $MIN_DURATION") )) && { info "ignoring [$f] w/ duration of $(print_time "$duration")"; continue; }

    vts_root=$(cut -d'_' -f1-2 <<< "$(basename -- "$f")")  # or  `grep -Eo '^VTS_[0-9]+' <<< "$(basename -- "$f")"`
    VTS_ID_TO_DURATION["$vts_root"]=$(bc <<< "${VTS_ID_TO_DURATION[$vts_root]:-0} + $duration")
    WHITELISTED_FILES+=("$f")
done

# Step 2: find the longest VTS (likely VTS_01), and collect its valid files into INPUT array
unset MAX_VTS_ROOT
MAX_DURATION=0

for vts_root in "${!VTS_ID_TO_DURATION[@]}"; do
    dur=${VTS_ID_TO_DURATION[$vts_root]}
    if (( $(bc <<< "$dur > $MAX_DURATION") )); then
        MAX_DURATION=$dur
        MAX_VTS_ROOT=$vts_root
    fi
done

[[ -z "$MAX_VTS_ROOT" ]] && fail 'could not detect main movie'  # sanity
for f in "${WHITELISTED_FILES[@]}"; do
    [[ "$(basename -- "$f")" == "$MAX_VTS_ROOT"_* ]] && INPUT+=("$f")
done
info "main DVD movie detected: $MAX_VTS_ROOT (${#INPUT[@]} file(s), ~$(print_time "$MAX_DURATION") runtime)"

# Step 3: merge
info "merging DVD .VOB files in [$ASSET] into [$OUTPUT]..."
has_enough_space "$MIN_FREE_SPACE_GB" "${INPUT[@]}" || exit 1  # TODO: pushover? or is sync.sh sending pushover notif if this script fails?

case "${VOB_MERGE:-mkvmerge}" in
    ffmpeg)
        # option 1, using ffmpeg:
        # - see https://askubuntu.com/questions/804178/merge-vob-files-via-command-line
        #   - ffmpeg -i "concat:VTS_01_1.VOB|VTS_01_2.VOB|VTS_01_3.VOB|VTS_01_4.VOB" -f mpeg -c copy output.mpeg
        #   - ffmpeg -i "concat:VTS_01_1.VOB|VTS_01_2.VOB|VTS_01_3.VOB|VTS_01_4.VOB" -f dvd -c copy output.mpeg
        ffmpeg -loglevel error -i "concat:$(join_by '|' "${INPUT[@]}")" -f dvd \
                -c copy "$OUTPUT" || fail "ffmpeg merge failed w/ $?"
        #ffmpeg -y \
            #-loglevel error \
            #-i "concat:$(join_by '|' "${INPUT[@]}")" \
            #-map 0 \
            #-c copy \
            #-f dvd \
            #-map 0:v:0 \
            #-map 0:a? \
            #-map 0:s? \
            #"$OUTPUT"
        ;;
    mkvmerge)
        mkvmerge -o "$OUTPUT" '(' "${INPUT[@]}" ')'
        e=$?
        [[ "$e" -gt 1 ]] && fail "mkvmerge failed w/ $e"  # note exit 1 for mkvmerge means only a warning
        ;;
    *) fail "unknown VOB_MERGE value [$VOB_MERGE]" ;;
esac

info "merged into [$OUTPUT]"

# delete .VOB files:
if [[ -z "$SKIP_VOB_RM" ]]; then
    rm -- "${VOBS[@]}" || fail "deleting .VOB files in [$ASSET] failed w/ $?"
    info "removed ${#VOBS[@]} .VOB files"
    #find "$ASSET" -type f -name 'VTS_*.VOB' -delete \
        #|| fail "find-deleting VTS_*.VOB files in [$ASSET] failed w/ $?"
fi

exit 0

