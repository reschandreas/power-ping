#!/usr/bin/env sh

 #let the script exit if a command fails
set -o nounset
# set -o xtrace
IFS='|'
LOCK_FILE=/var/tmp/power-ping.sh
read_env_variables () {
    . /etc/power-ping/.env
}

scan_network () {
    sudo arp-scan -q -l --interface ${INTERFACE} | grep ${TARGET_MAC} > /dev/null
    echo $?
}

# $1 time of lock file generation
get_downtime_in_minutes () {
    local _downtime_start="${1}"
    local _seconds="$(($(date '+%s') - $(date -d "${_downtime_start}" '+%s')))"
    local _minutes=$((_seconds / 60))
    echo $_minutes
}

# $1 is command (ON or OFF)
sonoff_cmd () {
    local _cmd="${1}"
    curl http://${SONOFF_IPv4}/cm?cmnd=Power%20${_cmd} > /dev/null
}

sonoff_on () {
    sonoff_cmd "ON"
}

sonoff_off () {
    sonoff_cmd "OFF"
}

log_unreachable () {
    if [ -f "${LOCK_FILE}" ]
    then
        local _downtime_start=$(stat -c %y ${LOCK_FILE})
        local _downtime=$(get_downtime_in_minutes ${_downtime_start})
        echo "Target is away since ${_downtime} minute/s"
        if [ "${_downtime}" -ge ${DOWNTIME_LIMIT} ]
        then
            sonoff_off
        fi
    else
        echo "create lock file"
        touch ${LOCK_FILE}
    fi
}

log_reachable () {
    if [ -f "${LOCK_FILE}" ]
    then
        rm "${LOCK_FILE}"
        sonoff_on
    fi
}

check_target_reachability () {
    for try in 1 2 3 4 5 6 7 8 9 10
    do
        local _is_home=$(scan_network)
        if [ "${_is_home}" -eq 0 ]
        then
            echo "Target is home ${try}"
            log_reachable
            exit 0
        fi
    done
    log_unreachable
    echo "Target seems to be away"
}

main () {
    read_env_variables
    check_target_reachability
    exit 0
}

main
