#!/usr/bin/env bash
#
# This script extracts completed archives.
########################################################
readonly SELF="${0##*/}"
DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"  # location of this script

ASSET="$1"  # file/dir to extract
JOB_ID="$PPID"  # PID of the calling sync.sh process

# TODO: consider global extract command such as        /usr/bin/7z x "%F/*.rar" -o"%F/"
declare -A FORMAT_TO_COMMAND=(
    [zip]='unzip -u'
    [rar]='unrar -o- e'
    [tgz]='tar zxvf'
)
EXTRACTION_SUBDIR="${EXTRACTION_SUBDIR:-extracted}"  # content will be extracted into this to-be-created subfolder; no slashes!
                                                     # note if this dir already exists, we modify this value.
EXTRACT_DISK_THRESHOLD_GB=${EXTRACT_DISK_THRESHOLD_GB:-30}  # in GB; we must estimate min. this amount of free disk space left _after_ extraction, otherwise skip.


enough_space_for_extraction() {
    local f free_disk size free_disk_after_gb

    f="$1"

    free_disk="$(space_left -b "$f")" || fail "space_left() returned w/ $?"  # bytes
    size="$(get_size -b "$f")" || fail "get_size() returned w/ $?"  # bytes; note we estimate unpacked $f size to equal its size in packed state

    free_disk_after_gb="$(bc <<< "($free_disk - $size) * 0.000000001")"  # byte -> GB
    LC_ALL=C printf -v free_disk_after_gb '%.0f' "$free_disk_after_gb"

    [[ "$free_disk_after_gb" -ge "$EXTRACT_DISK_THRESHOLD_GB" ]] && return 0
    err "skipping [$f] extraction - final free disk would be ~ [${free_disk_after_gb}GB], below our threshold of [${EXTRACT_DISK_THRESHOLD_GB}GB]"
    return 1
}



## ENTRY
source /common.sh || { echo -e "    ERROR: failed to import /common.sh"; exit 1; }
unset ERR

for format in "${!FORMAT_TO_COMMAND[@]}"; do
    while IFS= read -r -d $'\0' file; do
        ft="$(file --brief "$file")"
        if ! grep -qiE 'archive|compressed' <<< "$ft"; then
            err "file [$file] is not an archive: filetype is [$ft]"
            continue
        fi

        filename="$(basename -- "$file")"

        cd -- "$(dirname -- "$file")" || { err "cd to [$file] containing dir failed w/ $?"; ERR=1; continue; }

        # handle special case where $ASSET itself is the archive file, ie it's not in its own directory:
        # (note this case could be avoided with a plugin that force-creates a root-dir, see https://forum.deluge-torrent.org/viewtopic.php?f=9&t=51839)
        if [[ "$file" == "$ASSET" ]]; then
            # TODO note unsure whether servarrs are happy with this solution or not;
            #      maybe pushover so we can see how it fares in real life?
            file="${ASSET}.${RANDOM}.tmp"
            mv -- "$ASSET" "$file" || { err "[mv $ASSET $file] failed w/ $?"; ERR=1; continue; }
            mkdir -- "$ASSET" || { err "[mkdir $ASSET] failed w/ $?; we're currently in [$(pwd)]"; ERR=1; continue; }
            mv -- "$file" "$ASSET/$filename" || { err "[mv $file $ASSET/$filename] failed w/ $?"; ERR=1; continue; }
            cd -- "$ASSET" || { err "cd to $ASSET failed w/ $?"; ERR=1; continue; }
            file="./$filename"
        else
            ext_dir="$EXTRACTION_SUBDIR"
            [[ -e "$ext_dir" ]] && ext_dir+="-$filename"  # sanity check to make sure the original copy doesn't already contain $ext_dir node
            mkdir -- "$ext_dir" || { err "[mkdir $ext_dir] failed w/ $?; we're currently in [$(pwd)]"; ERR=1; continue; }
            cd -- "$ext_dir" || { err "cd to $ext_dir failed w/ $?"; ERR=1; continue; }
            file="../$filename"
        fi

        enough_space_for_extraction "$file" || { ERR=1; continue; }  # TODO: pushover? or is sync.sh sending pushover notif when extract.sh exits w/ err?

        info "extracting [$ASSET] file [$filename] into [$(pwd)]..."

        start="$(date +%s)"
        ${FORMAT_TO_COMMAND[$format]} "$file"
        e="$?"
        duration="$(print_time "$(($(date +%s) - start))")"

        if [[ "$e" -eq 0 ]]; then
            info "OK extraction of [$file] in $duration"

            if [[ -z "$SKIP_ARCHIVE_RM" ]]; then
                rm -- "$file" || { err "[rm $file] failed w/ $?"; continue; }  # TODO: should we set ERR=1?
                info "removed extracted archive [$file]"
                # delete also rar part files:
                if [[ "$format" == rar && "$file" == '../'* ]]; then
                    find ../ -maxdepth 1 -mindepth 1 -type f -iregex '^\.\./.*\.r[0-9]+$' -delete \
                        || err "find-deleting .r\d+ files in [$(dirname -- "$PWD")] failed w/ $?"  # TODO: should we set ERR=1?
                fi
            fi
        else
            err "[${FORMAT_TO_COMMAND[$format]} '$file'] failed w/ [$e] in $duration"
            # TODO: should we try and remove the created extraction output dir here?
            ERR=1
            continue
        fi
    done < <(find "$ASSET" -type f -iname "*.${format}" -print0)
done

exit "${ERR:-0}"

