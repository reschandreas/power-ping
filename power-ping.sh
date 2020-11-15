#!/usr/bin/env bash

LOCK_FILE=/var/tmp/power-ping.lock
ENV_FILE_LOCATION=/etc/power-ping/.env

#let the script exit if a command fails
set -o nounset
# set -o xtrace
IFS='|'

# load all needed variables from the given location
read_env_variables () {
    . "${ENV_FILE_LOCATION}"
}

# scan the network using arp-scan, the user that runs this script needs
# to be in the sudoers group
# output is the return value of the grep command, which filters the
# output of arp-scan with the mac address of our target
scan_network () {
    sudo arp-scan -q -l --interface ${INTERFACE} | grep ${TARGET_MAC} > /dev/null
    echo $?
}

# reads the creation time of the lock-file and returns said time
# converted to minutes
# $1 time of lock file generation
# returns the age of the lock-file in minutes
get_downtime_in_minutes () {
    local _downtime_start="${1}"
    local _seconds="$(($(date '+%s') - $(date -d "${_downtime_start}" '+%s')))"
    local _minutes=$((_seconds / 60))
    echo $_minutes
}

#### SONOFF COMMANDS ####
_SONOFF_POWER_ON="Power%20ON"
_SONOFF_POWER_OFF="Power%20OFF"
_SONOFF_POWER_STATUS="Power%20STATUS"

# execute a sonoff command using curl and return the response in json
# $1 is command
# returns response of the smart plug
sonoff_cmd () {
    local _cmd="${1}"
    local _response=$(curl http://${SONOFF_IPv4}/cm?cmnd=${_cmd} 2>&1 | grep '{')
    echo $_response
}

# switches the smart plug on if the previous state was ON, and deletes
# the lockfile
sonoff_on () {
    if [[ -f ${LOCK_FILE} ]]
    then
        local _status=$(cat ${LOCK_FILE})
        if [[ $_status == *"ON"* ]]
        then
            rm ${LOCK_FILE}
            sonoff_cmd ${_SONOFF_POWER_ON} > /dev/null
        fi
    fi
}

# turns off the smart plug
sonoff_off () {
    sonoff_cmd ${_SONOFF_POWER_OFF} > /dev/null
}

# checks the power status of the smart plug
# returns power status of the smart plug
sonoff_status () {
    local _response=$(sonoff_cmd ${_SONOFF_POWER_STATUS} | sed -e 's|{"POWER":"||g' | sed -e 's|"}||g')
    echo $_response
}

# creates the lock-file with the content indicating the power status to switch
# back to when the target is reachable again
create_lock_file () {
    echo "create lock file"
    local _status=$(sonoff_status)
    if [[ -f "${LOCK_FILE}" ]]
    then
        rm ${LOCK_FILE}
    fi
    echo $_status > ${LOCK_FILE}
}

# if the smart plug is already switched off, there is no need to bother
# the NIC with not needed scan
# outputs 0 if this run can be skipped to save cpu-time, 1 if we need to check
is_run_skippable () {
    if [[ -f "${LOCK_FILE}" ]]
    then
        local _status=$(cat ${LOCK_FILE})
        if [[ ${_status} == "OFF" ]]
        then
            local _lockfile_date=$(stat -c %y ${LOCK_FILE})
            local _lockfile_age=$(get_downtime_in_minutes ${_lockfile_date})
            if [[ "${_lockfile_age}" -ge ${DOWNTIME_LIMIT} ]]
            then
                rm ${LOCK_FILE}
            fi
            echo 0
        else
            echo 1
        fi
    else
        echo 1
    fi
}

# checks the age of the lockfile and if the file is older than
# allowed, turn off the smart plug, else just create the lock-file
log_unreachable () {
    if [[ -f "${LOCK_FILE}" ]]
    then
        local _downtime_start=$(stat -c %y ${LOCK_FILE})
        local _downtime=$(get_downtime_in_minutes ${_downtime_start})
        echo "Target is away since ${_downtime} minute/s"
        if [ "${_downtime}" -ge ${DOWNTIME_LIMIT} ]
        then
            sonoff_off
        fi
    else
        create_lock_file
    fi
}

# switch on the smart plug
log_reachable () {
    sonoff_on
}

# can the network 10 times and if the target seems to be out and about,
# execute log_unreachable, otherwise execute log_reachable
check_target_reachability () {
    for try in 1 2 3 4 5 6 7 8 9 10
    do
        local _is_home=$(scan_network)
        if [[ "${_is_home}" -eq 0 ]]
        then
            echo "Target is home, found with scan #${try}"
            log_reachable
            exit 0
        fi
    done
    log_unreachable
}

# main function that initializes the environemnt variables
# and decides whether we can skip this run or not
main () {
    read_env_variables
    local _skippable=$(is_run_skippable)
    if [[ ${_skippable} -eq 0 ]]
    then
        echo "skipping this run"
        exit 0
    fi
    check_target_reachability
    exit 0
}

main
