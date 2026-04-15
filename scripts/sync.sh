#!/usr/bin/env bash

#####################################
readonly SELF="${0##*/}"
DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"  # location of this script
JOB_ID="sync-$$"
#####################################

_kill_other_process() {
    local opt OPTIND signal pids pid exit_code

    signal=SIGTERM
    while getopts 'k' opt; do
        case "$opt" in
            k) signal=SIGKILL ;;
            *) fail -N "$FUNCNAME called with unsupported flag(s) [$opt]" ;;
        esac
    done
    shift "$((OPTIND-1))"

    readarray -t pids < <(pgrep -fx "bash.*/$SELF" | grep -vFx "$$")  # to be more lenient, do   $ pgrep -fx ".*\bbash\b.*/$SELF" ;;;  or to be more exact, do   $ pgrep -fx "bash /usr/local/sbin/$SELF"  (note path is decided in Dockerfile)

    # sanity to detect process grep failures:
    [[ "${#pids[@]}" -eq 0 && "$signal" != SIGKILL ]] && fail 'no pids to kill found!'  # SIGKILL is a retry-killing, ok if no process found

    for pid in "${pids[@]}"; do
        is_digit "$pid" || fail "one of the found PIDs was not a digit: [$pid]"
        if kill -0 -- "$pid" 2>/dev/null; then  # if process still running, kill it:
            info "sending $signal to process group [$pid]..."
            kill -$signal -- -$pid || fail "sending $signal to process group [$pid] failed w/ $?"
            exit_code=0
        fi
    done

    return "${exit_code:-1}"  # whether process was killed
}


check_for_rclone_stall() {
    local size last_size last_time time time_d

    _write_state() {
        echo -n "${time}:$size" >| "$RCLONE_STATEFILE"
    }

    size="$(get_size -b "$DEST_INITIAL")"
    time="$(date +%s)"

    if ! check_connection; then
        _write_state  # update our timestamp as connection drop should reset it
        fail 'no internets & lockfile exists, skipping...'
    elif [[ -s "$RCLONE_STATEFILE" ]]; then
        IFS=':' read -r last_time last_size < "$RCLONE_STATEFILE"
        time_d="$((time - last_time))"

        if [[ "$(bc <<< "$size > $last_size")" -eq 1 ]]; then
            _write_state  # data transfer/unpacking is clearly working, update state
        elif [[ "$time_d" -ge "$PROCESS_STALL_THRESHOLD_SEC" ]]; then
            warn "$SELF has been running for at least $(print_time "$time_d") with constant [$DEST_INITIAL] size, suspecting rclone stall; killing its pgroup..."
            _kill_other_process && sleep 10
            # if process still running, nuke:
            _kill_other_process -k && sleep 2
            exlock_now && return 0  # post-kill lock succeeded, this instance may carry on
            fail 'exlock_now() still failed after killing!'
        fi
    else
        _write_state
    fi

    info 'unable to obtain lock, process already running'
    exit 0  # exit, not return
}


nuke_local_assets() {
    local rmt_nodes excluded_path i

    rmt_nodes=("$@")

    # exclude DEST_INITIAL in case it defaults to a dir under DEST_FINAL/:
    excluded_path="$DEST_INITIAL"
    [[ "$DEPTH" -gt 1 ]] && excluded_path+='/*'

    while IFS= read -r -d $'\0' i; do
        if ! contains "${i##"${DEST_FINAL}/"}" "${rmt_nodes[@]}"; then
            rm -rf -- "$i" \
                    && info "removed [$i] whose remote counterpart is gone" \
                    || err "[rm -rf $i] failed w/ $?"
        fi
    done< <(find -L "$DEST_FINAL" -mindepth "$DEPTH" -maxdepth "$DEPTH" -not \( -path "$excluded_path" -prune \) -print0)
}


# process assets.
# note we work on _all_ nodes in $DEST_INITIAL, not only ones
# that were pulled during this execution; this is essentially
# for retrying failures from previous runs:
post_process() {
    local i f_relative dest_dir

    while IFS= read -r -d $'\0' i; do
        f_relative="${i##"${DEST_INITIAL}/"}"
        dest_dir="$(dirname -- "$DEST_FINAL/$f_relative")"

        if [[ -z "$SKIP_EXTRACT" && ! -e "$DEST_FINAL/$SKIP_EXTRACT_MARKER_FILE" && ! -e "$dest_dir/$SKIP_EXTRACT_MARKER_FILE" ]]; then
            extract.sh "$i" || { err "[$i] extraction failed, see logs"; continue; }  # TODO: pushover!
        fi

        if [[ -e "$DEST_FINAL/$f_relative" ]]; then
            err "[$DEST_FINAL/$f_relative] already exists; cannot move [$i] into $dest_dir/"  # TODO: pushover!
            continue
        else
            if [[ "$DEPTH" -gt 1 ]]; then
                [[ -d "$dest_dir" ]] || mkdir -p "$dest_dir" || { err "[mkdir -p $dest_dir] failed w/ $?"; continue; }  # TODO: pushover!
            fi
            mv -- "$i" "$dest_dir/" || { err "[mv $i $dest_dir/] failed w/ $?"; continue; }  # TODO: pushover!
        fi
    done< <(find -L "$DEST_INITIAL" -mindepth "$DEPTH" -maxdepth "$DEPTH" -print0)
}


work() {
    local rmt_nodes add_filter to_download_list remote_nodes path_segments f_escaped s i

    rmt_nodes=()
    add_filter=()
    to_download_list=()

    # non-empty $DEST_INITIAL suggests issues during previous run(s):
    find -L "$DEST_INITIAL" -mindepth "$DEPTH" -maxdepth "$DEPTH" -print -quit | grep -q . && warn "expected DEST_INITIAL dir [$DEST_INITIAL] to be empty at depth=$DEPTH, but it's not"

    # move assets _to_ remote (.torrent files to watchdir):
    if [[ -d "$WATCHDIR_SRC" ]] && ! is_dir_empty "$WATCHDIR_SRC"; then
        rclone move --log-file "$LOG_ROOT/rclone-move.log" "${RCLONE_FLAGS[@]}" \
                "$WATCHDIR_SRC" "$REMOTE:$WATCHDIR_DEST" 2>"$LOG_ROOT/rclone-move.stderr.log" || err "rclone move from [$WATCHDIR_SRC] to [$WATCHDIR_DEST] failed w/ $?"  # TODO: pushover! but do _not_ fail out here
    fi

    # first list the remote source dir contents:
    #
    # note rclone doesn't implement --min-depth yet (see https://github.com/rclone/rclone/issues/6602);
    # but to cheat, you could do  | grep -P '^([^/]+/){'"$((DEPTH-1))"'}[^/]+/?$'
    remote_nodes="$(rclone lsf --log-file "$LOG_ROOT/rclone-lsf.log" \
        "${RCLONE_FLAGS[@]}" --max-depth "$DEPTH" -- "$REMOTE:$SRC_DIR" 2>"$LOG_ROOT/rclone-lsf.stderr.log")" || fail "rclone lsf failed w/ $?"  # TODO: pushover!
    readarray -t remote_nodes <<< "$remote_nodes"

    # ...then verify which assets we haven't already downloaded-processed, and
    # compile them into rclone '--filter' options:
    for i in "${remote_nodes[@]}"; do
        readarray -d / path_segments < <(printf '%s' "$i")  # process-substitution via printf is to prevent trailing newline that's produced by bash here-string (<<<)
        [[ "${#path_segments[@]}" -ne "$DEPTH" ]] && continue

        rmt_nodes+=("${i%/}")  # note we remove possible trailing slash; this way we can compare values to local nodes verbatim
        [[ -e "$DEST_FINAL/${i%/}" ]] && continue  # already been processed
        to_download_list+=("$i")
        add_filter+=('--filter')
        f_escaped="$(sed 's/[].\*^$()+?{}|[]/\\&/g' <<< "$i")"
        [[ "$f_escaped" == */ ]] && add_filter+=("+ /${f_escaped}**") || add_filter+=("+ /$f_escaped")
    done

    # ...nuke assets that have been removed on the remote:
    [[ -z "$SKIP_LOCAL_RM" ]] && nuke_local_assets "${rmt_nodes[@]}"

    # pull new assets:
    if [[ "${#to_download_list[@]}" -gt 0 ]]; then
        [[ "${#to_download_list[@]}" -gt 1 ]] && s=s
        info "going to copy following ${#to_download_list[@]} node$s from remote:"

        for i in "${to_download_list[@]}"; do
            info "  > $i"
        done

        rclone copy --log-file "$LOG_ROOT/rclone-copy.log" "${RCLONE_FLAGS[@]}" \
            "$REMOTE:$SRC_DIR" "$DEST_INITIAL" "${add_filter[@]}" --filter '- *' 2>"$LOG_ROOT/rclone-copy.stderr.log" || fail "rclone copy failed w/ $?"  # TODO: pushover!
    fi

    post_process

    [[ "${#to_download_list[@]}" -gt 0 ]] && return 0 || return 1
}


#### ENTRY
source /common.sh || { echo -e "    ERROR: failed to import /common.sh"; exit 1; }
_prepare_locking || fail "_prepare_locking() failed w/ $?"

[[ -s "$ENV_ROOT/pre-parse.sh" ]] && source "$ENV_ROOT/pre-parse.sh"

if [[ -n "${RCLONE_FLAGS[*]}" ]]; then
    IFS="$SEPARATOR" read -ra RCLONE_FLAGS <<< "$RCLONE_FLAGS"
else  # no rclone flags provided, define our set of defaults;
    # note if your seedbox had an nvme or a dedicated disk plan, then there
    # would be no need for bwlimit
    RCLONE_FLAGS=(
      --config "$RCLONE_CONF"
      --fast-list
      --bwlimit 20M
      --transfers 2
      --retries 6
      --retries-sleep 10s
    )
fi

if [[ -n "${RCLONE_OPTS[*]}" ]]; then
    IFS="$SEPARATOR" read -ra rclone_opts <<< "$RCLONE_OPTS"
    RCLONE_FLAGS+=("${rclone_opts[@]}")   # allow extending w/ user-provided opts
fi

[[ -s "$ENV_ROOT/post-parse.sh" ]] && source "$ENV_ROOT/post-parse.sh"
validate_config_common  # check after post-parse.sh sourcing to make sure nothing's been hecked up

# note we lock this late to ensure validate_config_common() has been executed beforehand
exlock_now || check_for_rclone_stall
[[ -f "$RCLONE_STATEFILE" ]] && rm -- "$RCLONE_STATEFILE"

check_connection || fail 'no internets'


# if some new files were downloaded, then immediately restart the process, as
# remote download client might've completed new assets in the meantime:
while true; do
    work || break
done

# cleanup empty parent dirs:
if [[ -n "$RM_EMPTY_PARENT_DIRS" && "$DEPTH" -gt 1 ]]; then
    find -L "$DEST_INITIAL" "$DEST_FINAL" -mindepth 1 -maxdepth "$((DEPTH-1))" \
        -not \( -path "$DEST_INITIAL" -prune \) -type d -empty -delete || err "find-deleting empty parent dirs failed w/ $?"
fi

exit 0

