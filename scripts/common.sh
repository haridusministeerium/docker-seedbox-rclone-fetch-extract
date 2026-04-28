#!/usr/bin/env bash
#
# common vars & functions

set -o noglob
set -o pipefail

readonly CONF_ROOT='/config'
readonly LOG_ROOT="$CONF_ROOT/logs"  # note path is also tied to logrotate config
readonly ENV_ROOT="$CONF_ROOT/env"
#readonly SCRIPT_ROOT="$CONF_ROOT/scripts"
readonly RCLONE_CONF="$CONF_ROOT/rclone.conf"
readonly SKIP_EXTRACT_MARKER_FILE='.skip-extract'  # file marking everything under its containing path shall be left un-extracted
readonly RCLONE_STATEFILE='/tmp/rclone-state'
[[ "$SEPARATOR" == space ]] && SEPARATOR=' '
[[ "$SEPARATOR" == comma ]] && SEPARATOR=','
[[ "$SEPARATOR" == colon ]] && SEPARATOR=':'
[[ "$SEPARATOR" == semicolon ]] && SEPARATOR=';'
readonly SEPARATOR="${SEPARATOR:-;}"  # default to semicolon


LOG="$LOG_ROOT/${SELF}.log"

#readonly ENV_ROOT="$CONF_ROOT/env"
LOG_TIMESTAMP_FORMAT='+%F %T'

HC_HEAD='https://hc-ping.com'

CURL_FLAGS=(
    -w '\n'
    --output /dev/null
    --max-time 6
    --connect-timeout 3
    -s -S --fail -L
)

LOCKFILE="/tmp/${SELF:-$(basename -- "$0")}"  # note $SELF is defined by importing script
LOCKFD=9

# locking logic (from https://stackoverflow.com/a/1985512/3344729):
# PRIVATE
_lock()             { flock -$1 $LOCKFD; }
_no_more_locking()  { _lock u; _lock xn && rm -f -- "$LOCKFILE"; }
_prepare_locking()  { eval "exec $LOCKFD>\"$LOCKFILE\""; }
_prepare_locking_trap()  { _prepare_locking; trap _no_more_locking EXIT; }

# PUBLIC
exlock_now()        { _lock xn; }  # obtain an exclusive lock immediately or fail
exlock()            { _lock x; }   # obtain an exclusive lock
exlock_wait()       { flock -x -w ${1:-10} $LOCKFD; }   # obtain an exclusive lock, wait for x sec
shlock()            { _lock s; }   # obtain a shared lock
unlock()            { _lock u; }   # drop a lock


# dir existence needs to be verified by the caller!
is_dir_empty() {
    local dir="$1"
    [[ -d "$dir" ]] || fail "[$dir] is not a valid dir."
    find -L "$dir" -mindepth 1 -maxdepth 1 -print -quit | grep -q . && return 1 || return 0
}


is_function() {
    typeset -f "$1" > /dev/null
}


check_connection() {
    ping -W 10 -c 1 -- 1.1.1.1 > /dev/null 2>&1
}


fail_from_borg() {
    err -F "$@"
    err -N " - ABORTING -"
    exit 1
}

# info lvl logging
#
# note this fun is exported
log() {
    local msg
    readonly msg="$1"
    echo -e "[$(date "$LOG_TIMESTAMP_FORMAT")] [$JOB_ID]\tINFO  $msg" | tee -a "$LOG"
    return 0
}


#
# note this fun is exported
err_from_borg() {  # TODO rename back to err() if/when we start using the built-in notifications
    local opt msg f no_notif OPTIND no_mail_orig

    no_mail_orig="$NO_SEND_MAIL"

    while getopts 'FNM' opt; do
        case "$opt" in
            F) f='-F' ;;  # only to be provided by fail(), ie do not pass -F flag to err() yourself!
            N) no_notif=1 ;;
            M) NO_SEND_MAIL=true ;;  # note this would be redundant if -N is already given
            *) fail -N "$FUNCNAME called with unsupported flag(s) [$opt]" ;;
        esac
    done
    shift "$((OPTIND-1))"

    readonly msg="$1"
    echo -e "[$(date "$LOG_TIMESTAMP_FORMAT")] [$JOB_ID]\t    ERROR  $msg" | tee -a "$LOG" >&2
    [[ "$no_notif" -ne 1 ]] && notif $f "$msg"

    NO_SEND_MAIL="$no_mail_orig"  # reset to previous value
}


# note no notifications are generated if shell is in interactive mode
#
# note this fun is exported
notif() {
    local msg f msg_tail

    [[ "$1" == '-F' ]] && { f='-F'; shift; }
    [[ "$-" == *i* || "$NO_NOTIF" == true ]] && return 0

    msg="$1"

    if [[ "${ADD_NOTIF_TAIL:-true}" == true ]]; then
        msg_tail="$(echo -e "${NOTIF_TAIL_MSG:-$DEFAULT_NOTIF_TAIL_MSG}")"
        msg+="$msg_tail"
    fi

    # if this function was called from a script that accesses this function via exported vars:
    [[ -n "${ERR_NOTIF[*]}" && "${#ERR_NOTIF[@]}" -eq 1 && "${ERR_NOTIF[*]}" == *"$SEPARATOR"* ]] && IFS="$SEPARATOR" read -ra ERR_NOTIF <<< "$ERR_NOTIF"

    if contains mail "${ERR_NOTIF[@]}" && [[ "$NO_SEND_MAIL" != true ]]; then
        mail $f -t "$MAIL_TO" -f "$MAIL_FROM" -s "$NOTIF_SUBJECT" -a "$SMTP_ACCOUNT" -b "$msg" &
    fi

    if contains pushover "${ERR_NOTIF[@]}"; then
        pushover $f -s "$NOTIF_SUBJECT" -b "$msg" &
    fi

    if contains healthchecksio "${ERR_NOTIF[@]}"; then
        hcio $f -b "$msg" &
    fi
}


#
# note this fun is exported
mail() {
    local opt to from subj acc body is_fail err_code account OPTIND

    while getopts 'Ft:f:s:b:a:' opt; do
        case "$opt" in
            F) is_fail=true ;;
            t) to="$OPTARG" ;;
            f) from="$OPTARG" ;;
            s) subj="$OPTARG" ;;
            b) body="$OPTARG" ;;
            a) acc="$OPTARG" ;;
            *) fail -M "$FUNCNAME called with unsupported flag(s) [$opt]" ;;
        esac
    done
    shift "$((OPTIND-1))"

    [[ -n "$acc" ]] && declare -a account=('-a' "$acc")

    msmtp "${account[@]}" --read-envelope-from -t <<EOF
To: $to
From: $(expand_placeholders "${from:-$DEFAULT_MAIL_FROM}" "$is_fail")
Subject: $(expand_placeholders "${subj:-$DEFAULT_NOTIF_SUBJECT}" "$is_fail")

$(expand_placeholders "${body:-NO MESSAGE BODY PROVIDED}" "$is_fail")
EOF

    err_code="$?"
    [[ "$err_code" -ne 0 ]] && err -M "sending mail failed w/ [$err_code]"
}


#
# note this fun is exported
pushover() {
    local opt is_fail subj body prio retry expire hdrs OPTIND

    while getopts 'Fs:b:p:r:e:' opt; do
        case "$opt" in
            F) is_fail=true ;;
            s) subj="$OPTARG" ;;
            b) body="$OPTARG" ;;
            p) prio="$OPTARG" ;;
            r) retry="$OPTARG" ;;
            e) expire="$OPTARG" ;;
            *) fail -N "$FUNCNAME called with unsupported flag(s) [$opt]" ;;
        esac
    done
    shift "$((OPTIND-1))"

    [[ -z "$prio" ]] && prio="${PUSHOVER_PRIORITY:-1}"

    declare -a hdrs
    if [[ "$prio" -eq 2 ]]; then  # emergency priority
        [[ -z "$retry" ]] && retry="${PUSHOVER_RETRY:-60}"
        [[ "$retry" -lt 30 ]] && retry=30  # as per pushover docs

        [[ -z "$expire" ]] && expire="${PUSHOVER_EXPIRE:-3600}"
        [[ "$expire" -gt 10800 ]] && expire=10800  # as per pushover docs

        hdrs+=(
            --form-string "retry=$retry"
            --form-string "expire=$expire"
        )
    fi

    # if this function was called from a script that accesses this function via exported vars:
    [[ -n "${CURL_FLAGS[*]}" && "${#CURL_FLAGS[@]}" -eq 1 && "${CURL_FLAGS[*]}" == *"$SEPARATOR"* ]] && IFS="$SEPARATOR" read -ra CURL_FLAGS <<< "$CURL_FLAGS"

    curl "${CURL_FLAGS[@]}" \
        --retry 2 \
        --form-string "token=$PUSHOVER_APP_TOKEN" \
        --form-string "user=$PUSHOVER_USER_KEY" \
        --form-string "title=$(expand_placeholders "${subj:-$DEFAULT_NOTIF_SUBJECT}" "$is_fail")" \
        --form-string "message=$(expand_placeholders "${body:-NO MESSAGE BODY PROVIDED}" "$is_fail")" \
        --form-string "priority=$prio" \
        "${hdrs[@]}" \
        --form-string "timestamp=$(date +%s)" \
        "https://api.pushover.net/1/messages.json" || err -N "sending pushover notification failed w/ [$?]"
}


#
# note this fun is exported
hcio() {
    local opt is_fail body OPTIND url

    while getopts 'Fb:' opt; do
        case "$opt" in
            F) is_fail=true ;;
            b) body="$OPTARG" ;;
            *) fail -N "$FUNCNAME called with unsupported flag(s) [$opt]" ;;
        esac
    done
    shift "$((OPTIND-1))"

    url="$HC_URL"
    [[ "$url" != */ ]] && url+='/'
    url+='fail'

    # if this function was called from a script that accesses this function via exported vars:
    [[ -n "${CURL_FLAGS[*]}" && "${#CURL_FLAGS[@]}" -eq 1 && "${CURL_FLAGS[*]}" == *"$SEPARATOR"* ]] && IFS="$SEPARATOR" read -ra CURL_FLAGS <<< "$CURL_FLAGS"

    curl "${CURL_FLAGS[@]}" \
        --retry 5 \
        --user-agent "$HOST_ID" \
        --data-raw "$(expand_placeholders "${body:-NO MESSAGE BODY PROVIDED}" "$is_fail")" \
        "$url" || err -N "pinging healthchecks.io endpoint [$url] failed w/ [$?]"
}


add_remote_to_known_hosts_if_missing() {
    local input host

    input="$1"
    [[ -z "$input" ]] && return 0

    host="${input#*@}"  # everything after '@'
    host="${host%%:*}"  # everything before ':'

    [[ -z "$host" ]] && fail "could not extract host from remote [$input]"

    if [[ -z "$(ssh-keygen -F "$host")" ]]; then
        ssh-keyscan -H "$host" >> "$HOME/.ssh/known_hosts" || fail "adding host [$host] to ~/.ssh/known_hosts failed w/ [$?]"
    fi
}


vars_defined() {
    local i val

    for i in "$@"; do
        val="$(eval echo "\$$i")" || fail "evaling [echo \"\$$i\"] failed w/ [$?]"
        [[ -z "$val" ]] && fail "[$i] is not defined"
    done
}


validate_true_false() {
    local i val

    for i in "$@"; do
        val="$(eval echo "\$$i")" || fail "evaling [echo \"\$$i\"] failed w/ [$?]"
        is_true_false "$val" || fail "$i value, when given, can be either [true] or [false]"
    done
}


is_true_false() {
    [[ "$*" =~ ^(true|false)$ ]]
}


# Verifies given string/input is truthy.
#
# @param {string}  s  string to validate.
#
# @returns {bool}  true, if passed param is of truthy bool nature, ie it's
#                  {true,y,yes,1}
is_truthy() {
    local i

    i="$(tr '[:upper:]' '[:lower:]' <<< "$*")"
    [[ "$i" == 1 ]] && i=true

    [[ "$i" =~ ^(true|y|yes)$ ]]
}


# Verifies given string/input is falsy.
#
# @param {string}  s  string to validate.
#
# @returns {bool}  true, if passed param is of falsy bool nature, ie it's
#                  {false,n,no,1}
is_falsy() {
    ! is_truthy "$*"
}


# Checks whether given url is a valid one.
#
# @param {string}  url   url which validity to test.
#
# @returns {bool}  true, if provided url was a valid url.
#
# note this fun is exported
is_valid_url() {
    local regex

    readonly regex='^(https?|ftp|file)://[-A-Za-z0-9\+&@#/%?=~_|!:,.;]*[-A-Za-z0-9\+&@#/%=~_|]'

    [[ "$1" =~ $regex ]]
}


ping_healthcheck() {
    local id url

    id="$1"
    [[ -z "$id" ]] && return 0

    is_valid_url "$id" && url="$id" || url="$HC_HEAD/$id"

    curl "${CURL_FLAGS[@]}" \
        --retry 5 \
        --user-agent "$HOST_ID" \
        "$url" || err "pinging healthcheck service at [$url] failed w/ [$?]"
}


#
# note this fun is exported
contains() {
    local src i

    [[ "$#" -lt 2 ]] && { err "at least 2 args needed for $FUNCNAME"; return 2; }

    src="$1"
    shift

    for i in "$@"; do
        [[ "$i" == "$src" ]] && return 0
    done

    return 1
}


# see https://stackoverflow.com/a/17841619/1803648
join_by() {
    local d=${1-} f=${2-}
    if shift 2; then
        printf %s "$f" "${@/#/$d}"
    fi
}


join() {
    local opt OPTIND sep list i

    sep="$SEPARATOR"  # default

    while getopts 's:' opt; do
        case "$opt" in
            s) sep="$OPTARG" ;;
            *) fail "$FUNCNAME called with unsupported flag(s) [$opt]" ;;
        esac
    done
    shift "$((OPTIND-1))"

    for i in "$@"; do
        [[ -z "$i" ]] && continue
        list+="${i}$sep"
    done

    echo "${list:0:$(( ${#list} - ${#sep} ))}"
}


#
# note this fun is exported
print_time() {
    local sec tot r

    LC_ALL=C printf -v sec '%.0f' "$1"  # round to int

    tot=$((sec%60))
    r="${tot}s"

    if [[ "$sec" -gt "$tot" ]]; then
        r="$((sec%3600/60))m:$r"
        let tot+=$((sec%3600))
    fi

    if [[ "$sec" -gt "$tot" ]]; then
        r="$((sec%86400/3600))h:$r"
        let tot+=$((sec%86400))
    fi

    if [[ "$sec" -gt "$tot" ]]; then
        r="$((sec/86400))d:$r"
    fi

    echo -n "$r"
}


#### following from/for seedbox-fetcher scripts

_log() {
    local lvl msg
    readonly lvl="$1"
    readonly msg="$2"
    echo -e "[$(date "$LOG_TIMESTAMP_FORMAT")] [$JOB_ID]\t$lvl  $msg" | tee -a "$LOG" >&2
    return 0
}


fail() {
    err "$@"
    exit 1
}


info() {
    _log INFO "$*"
}


err() {
    _log ERROR "$*"
}


warn() {
    _log WARN "$*"
}


debug() {
    _log DEBUG "$*"
}


suffix() {
    local s sfx
    s="$1"

    case "$s" in
        11|12|13) sfx=th ;;
        *1) sfx=st ;;
        *2) sfx=nd ;;
        *3) sfx=rd ;;
        *)  sfx=th ;;
    esac

    echo "${s}$sfx"
}


# edit PATH so systemd finds our programs
set_path() {
    local j i

    j=''
    for i in \
            /usr/local/sbin \
            /usr/sbin \
            /sbin \
            "$HOME/bin" \
            "$HOME/.local/bin" \
            "$HOME/.rbenv/bin" \
            "$HOME/.yarn/bin" \
            /usr/local/go/bin \
                ; do
        if [[ :$PATH: != *:"$i":* && -d "$i" ]]; then
            j+="$i:"
        fi
    done
    [[ -n "$j" ]] && export PATH="${j}$PATH"
}


is_digit() {
    [[ "$*" =~ ^[0-9]+$ ]]
}


# Checks whether the argument is a digit, sign prefix allowed.
#
# @param {number}  arg   argument to check.
#
# @returns {bool}  true if argument is a valid, optionally signed, digit.
is_digit_signed() {
    [[ "$*" =~ ^[-+]?[0-9]+$ ]]
}


# Checks whether the argument is a non-negative decimal (ie allows fractionals).
#
# @param {decimal}  arg   argument to check.
#
# @returns {bool}  true if argument is a valid (and non-negative) digit, possibly fractional.
is_decimal() {
    [[ "$*" =~ ^[0-9]+(\.[0-9]+)?$ ]]
}


# Checks whether the argument is a (possibly decimal) digit, sign prefix allowed.
#
# @param {number}  arg   argument to check.
#
# @returns {bool}  true if argument is a valid, optionally fractional and/or signed, digit.
is_decimal_signed() {
    [[ "$*" =~ ^[-+]?[0-9]+(\.[0-9]+)?$ ]]
}


has_enough_space() {
    local f i free_space_threshold_gb free_disk size free_disk_after_gb sum m

    free_space_threshold_gb="$1"
    shift
    f=("$@")

    sum=0
    for i in "${f[@]}"; do
        size="$(get_size -b "$i")" || fail "get_size() for [$i] returned w/ $?"  # bytes
        (( sum+=size ))
    done

    # note space left is calculated for the first passed file filesystem:
    free_disk="$(space_left -b "${f[0]}")" || fail "space_left() returned w/ $?"  # bytes

    free_disk_after_gb="$(bc <<< "($free_disk - $sum) * 0.000000001")"  # byte -> GB
    (( $(bc <<< "$free_disk_after_gb >= $free_space_threshold_gb") )) && return 0

    m="$(basename -- "${f[0]}")"
    [[ "${#f[@]}" -gt 1 ]] && m+="... (${#f[@]} files in total)"
    err "skipping [$m] process -- final free disk would be ~${free_disk_after_gb}GB, below our threshold of [${free_space_threshold_gb}GB]"
    return 1
}


# Finds the remaining free space in requested units for the filesystem the given node resides on.
# !! Note this is highly platform-dependant, this particular has been tested on Alpine.
#
# @param   {string}  node   full path to the node whose filesystem free space we're querying.
#
# @returns {digit}  remaining free space in megas of the hosting filesystem.
space_left() {
    local opt coef round OPTIND node space_avail

    coef=0.0009765625  # note we default $coef to return in KiB
    while getopts 'Gkbr' opt; do
        case "$opt" in
           G) coef=0.000000001 ;;  # bytes -> GB, ie in GigaBytes
           k) coef=0.0009765625 ;;  # bytes -> KiB, ie in kibibytes
           b) coef=1 ;;  # bytes -> bytes
           r) round=1 ;;  # if result should be rounded to nearest integer
           *) return 1 ;;
        esac
    done
    shift "$((OPTIND-1))"

    node="$1"

    [[ $# -ne 1 ]] && { err_display "exactly 1 argument (node name) required." "$FUNCNAME"; return 1; }
    # do not do existence check before dir check/dirname resolving!
    [[ -e "$node" ]] || node="$(dirname -- "$node")"
    [[ -r "$node" ]] || { err "containing dir [$node] is not readable or doesn't exist." "$FUNCNAME"; return 1; }

    # du reports in mebybytes/kibibytes; -B1 would give bytes
    # as said, this command is highly os/platform dependent!:
    space_avail="$(df -B1 -- "$node" | sed -n 2p | awk '{ print $4 }')"  # free space left of filesystem in bytes
    is_digit "$space_avail" || { err_display "found available free space on [$node] was not a digit: [$space_avail]" "$FUNCNAME"; return 1; }

    [[ "$coef" == 1 ]] || space_avail="$(bc <<< "$space_avail * $coef")" || return 1
    [[ "$round" == 1 ]] && LC_ALL=C printf -v space_avail '%.0f' "$space_avail"
    echo -n "$space_avail"
    return 0
}


# note we use du here, and it's highly platform/os dependant!
get_size() {
    local opt coef round OPTIND file size

    coef=0.0009765625  # note we default $coef to return in KiB
    while getopts 'Gkbr' opt; do
        case "$opt" in
           G) coef=0.000000001 ;;  # bytes -> GB, ie in GigaBytes
           k) coef=0.0009765625 ;;  # bytes -> KiB, ie in kibibytes
           b) coef=1 ;;  # bytes -> bytes
           r) round=1 ;;  # if result should be rounded to nearest integer
           *) return 1 ;;
        esac
    done
    shift "$((OPTIND-1))"

    readonly file="$1"

    [[ $# -ne 1 ]] && { err "file/dir whose size to calculate needed"; return 1; }
    [[ ! -r "$file" ]] && { err "[$file] is not readable or doesn't exist"; return 1; }

    # TODO: add --apparent-size  option? (note long options not supported on alpine!)
    size="$(du -sLb -- "$file" 2>/dev/null | cut -f1 | tr -d '[:space:]')"  # bytes
    is_digit "$size" || { err "[$file] size was not valid: [$size]"; return 1; }

    [[ "$coef" == 1 ]] || size="$(bc <<< "$size * $coef")" || return 1
    [[ "$round" == 1 ]] && LC_ALL=C printf -v size '%.0f' "$size"
    echo -n "$size"
}


# Blocks until the provided PIDs have finished.
# If max wait time has passed and some processes are still running, then
# kill the pids (to avoid hung scripts) and return false.
#
#   TODO: do we want to invoke kill_pids() from here? shouldn't the invoker decide
#         over that?
#
# @opt   -t {digit}         countdown       OPTIONAL. max seconds to wait for termination.
#
# @param {digit list}    pidlist         digit list of PIDs to wait after.
#
# @returns {bool}  false, if processes didn't finish within our wait time. true otherwise.
block_until_pids_finish() {
    local opt OPTIND i pidlist countdown counter_limit sleep_cycle e ee

    e=0  # default errcode to 0
    while getopts 't:' opt; do
        case "$opt" in
           t) countdown="$OPTARG" ;;
           *) return 1 ;;
        esac
    done
    shift "$((OPTIND-1))"

    declare -a pidlist=("$@")

    sleep_cycle=1      # loop cycle duration in seconds; !! if you change to something else than 1, then
                       # the contract is no longer valid, as in we won't wait for the provided nr of seconds,
                       # but for the provided nr of sleep_cycle's.
    counter_limit=700  # default nr of sleep_cycles to wait for the processes to finish until calling it.

    if [[ -n "$countdown" ]]; then
        if ! is_digit "$countdown"; then
            err "provided [countdown] was not a digit: [$countdown]. waiting for the default value instead, which is [$counter_limit] sec"
            countdown=$counter_limit
        fi
        readonly counter_limit="$countdown"  # so the error reporting below would state correctly how long did the logic wait for;
    else
        countdown=$counter_limit
    fi

    while [[ -n "${pidlist[*]}" ]]; do
        # safety measure to avoid hung processes:
        if [[ "$countdown" -le 0 ]]; then
            err "waited for approx [$counter_limit] seconds for these unfinished subshells to finish: ${pidlist[*]}"
            err "named processes as viewed by ps:"

            for i in "${pidlist[@]}"; do
                err "$(ps -ef | grep -v '\bgrep\b' | grep -- "\b$i\b")"
            done

            err "killing those processes..."
            kill_pids "${pidlist[@]}"

            return 97
        fi

        for i in "${!pidlist[@]}"; do
            if ! kill -0 "${pidlist[i]}" 2>/dev/null; then
                wait -f "${pidlist[i]}"  # to get the exit status
                ee="$?"
                [[ "$ee" -gt "$e" ]] && e="$ee"
                unset pidlist[i]
            fi
        done

        sleep $sleep_cycle
        (( countdown-- )) || true
    done

    return $e
}


# Kills the provided pids. Note that it tries to kill them by sending SIGTERM first,
# but if it won't work, pids get sent SIGKILL.
#
# @param {digit...}    pidlist   list of PIDs to kill.
#
# @returns {void}
kill_pids() {
    local pidlist i

    declare -ar pidlist=("$@")

    # first kill nicely:
    if [[ -n "${pidlist[*]}" ]]; then
        kill -15 "${pidlist[@]}" && sleep 3
    fi

    # verify processes are terminated; if not, kill 'em brutally:
    for i in "${pidlist[@]}"; do
        if kill -0 "$i" 2>/dev/null; then
            sleep 2  # give some additional time to pack stuff up;
            if kill -0 "$i" 2>/dev/null; then  # if process still running, kill it
                err "SIGTERM didn't do the trick for PID [$i], sending SIGKILL..."
                if ! kill -9 "$i"; then
                    err "failed to send SIGKILL to process [$i]; perhaps process ended before?"
                fi
            fi
        fi
    done
}


validate_config_common() {
    local i

    mkdir_w_rights "$LOG_ROOT"

    [[ -d "$CONF_ROOT" ]] || fail "[$CONF_ROOT] needs to be a valid dir - missing mount?"

    vars_defined  REMOTE  SRC_DIR  DEST_FINAL

    [[ -f "$RCLONE_CONF" && -r "$RCLONE_CONF" ]] || fail "RCLONE_CONF [$RCLONE_CONF] needs to be a valid readable file"
    [[ -d "$DEST_FINAL" ]] || fail "DEST_FINAL [$DEST_FINAL] needs to be a valid dir - missing mount?"
    [[ -w "$DEST_FINAL" ]] || fail "DEST_FINAL [$DEST_FINAL] is not writable"
    DEST_FINAL="$(trim_trailing_slashes "$DEST_FINAL")"

    [[ -w "$LOG_ROOT" ]] || fail "[$LOG_ROOT] is not writable"

    if [[ -n "$DEST_INITIAL" ]]; then
        [[ -d "$DEST_INITIAL" ]] || fail "DEST_INITIAL [$DEST_INITIAL] needs to be a valid dir - missing mount?"
        [[ -w "$DEST_INITIAL" ]] || fail "DEST_INITIAL [$DEST_INITIAL] is not writable"
    else
        DEST_INITIAL="$DEST_FINAL/.rclone-intermediary"  # default
    fi

    DEST_INITIAL="$(trim_trailing_slashes "$DEST_INITIAL")"
    mkdir_w_rights "$DEST_INITIAL"
    mkdir_w_rights "$DEST_FINAL"  # dir exists, but ensure correct ownership

    [[ -n "$WATCHDIR_DEST" && -z "$WATCHDIR_SRC" ]] && fail "if WATCHDIR_DEST is defined, then WATCHDIR_SRC needs to be defined as well"
    [[ -z "$WATCHDIR_DEST" && -n "$WATCHDIR_SRC" ]] && fail "if WATCHDIR_SRC is defined, then WATCHDIR_DEST needs to be defined as well"
    if [[ -n "$WATCHDIR_SRC" ]]; then
        [[ -d "$WATCHDIR_SRC" ]] || fail "WATCHDIR_SRC [$WATCHDIR_SRC], when defined, needs to be a valid dir - missing mount?"
        [[ -w "$WATCHDIR_SRC" ]] || fail "WATCHDIR_SRC [$WATCHDIR_SRC] is not writable"  # needs to be writable as we 'rclone move' files away, ie effectively deletion in SRC is needed
    fi
    [[ -z "$EXTRACT_DISK_THRESHOLD_GB" ]] || is_digit "$EXTRACT_DISK_THRESHOLD_GB" || fail "EXTRACT_DISK_THRESHOLD_GB [$EXTRACT_DISK_THRESHOLD_GB], when defined, needs to be a digit"
    [[ -z "$MIN_FREE_SPACE_GB" ]] || is_digit "$MIN_FREE_SPACE_GB" || fail "MIN_FREE_SPACE_GB [$MIN_FREE_SPACE_GB], when defined, needs to be a digit"

    [[ -z "$DEPTH" ]] && DEPTH=1  # default
    is_digit "$DEPTH" && [[ "$DEPTH" -ge 1 ]] || fail "DEPTH, when defined, needs to be digit >= 1, but is [$DEPTH]"

    [[ -z "$PROCESS_STALL_THRESHOLD_SEC" ]] && PROCESS_STALL_THRESHOLD_SEC=600  # default
    is_digit "$PROCESS_STALL_THRESHOLD_SEC" && [[ "$PROCESS_STALL_THRESHOLD_SEC" -ge 1 ]] || fail "PROCESS_STALL_THRESHOLD_SEC, when defined, needs to be digit >= 1, but is [$PROCESS_STALL_THRESHOLD_SEC]"

    [[ "$RCLONE_FLAGS" =~ (^|[^a-zA-Z0-9_])--(exclude|include)($|[^a-zA-Z0-9_]) ]] && warn 'replace [--{exclude*,include*}] flags with --filter ones; see https://rclone.org/filtering/#filter-add-a-file-filtering-rule'

    export DEST_INITIAL  DEST_FINAL  DEPTH  PROCESS_STALL_THRESHOLD_SEC
}


mkdir_w_rights() {
    local d="$1"

    [[ -d "$d" ]] || mkdir -p -- "$d" || fail "[mkdir -p $d] failed w/ $?"
    if [[ "$EUID" -eq 0 && -n "$PUID" && -n "$PGID" ]]; then
        chown -R "${PUID}:${PGID}" "$d" || fail "[chown -R $PUID:$PGID $d] failed w/ $?"
    fi
}


# alternatively, "${i%%+(/)}", but requires `shopt -s extglob`
trim_trailing_slashes() {
    sed 's:/*$::' <<< "$*"
}


#[[ -f "${ENV_ROOT}/common-env.conf" ]] && source "${ENV_ROOT}/common-env.conf"

mkdir_w_rights "$LOG_ROOT"
set_path

if [[ -n "$HC_ID" && "$EUID" -ne 0 ]]; then  # note we don't run if root (likely at startup/init phase of container)
    ping_healthcheck "$HC_ID" &  # note we background not to hinder main workflow
fi

if [[ "$DEBUG" == true ]]; then
    set -x
    printenv
    echo
fi

true  # always exit common w/ good code

