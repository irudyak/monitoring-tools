#!/bin/bash

. $( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )/common.sh

# Ansible host group from /etc/ansible/hosts
HOSTS_GROUP="$1"

# Remote folder for flight recordings
RECORDING_ROOT_DIR="$2"

# Action
ACTION="$3"

if [ -z "$RECORDING_ROOT_DIR" ]; then
    logError "Remote recording root folder should be specified"
    exit 1
fi

if [ -z "$HOSTS_GROUP" ]; then
    logError "Ansible host group should be specified"
    exit 1
fi

shift 3

current_dir=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )

case "$ACTION" in

remote-start)
    $current_dir/flight-recording.sh remote-start $HOSTS_GROUP $RECORDING_ROOT_DIR $@
    ;;
remote-download)
    $current_dir/flight-recording.sh remote-download $HOSTS_GROUP $RECORDING_ROOT_DIR $@
    ;;
remote-status)
    $current_dir/flight-recording.sh remote-status $HOSTS_GROUP $RECORDING_ROOT_DIR $@
    ;;
remote-clean)
    $current_dir/flight-recording.sh remote-clean $HOSTS_GROUP $RECORDING_ROOT_DIR $@
    ;;
flamegraph)
    $current_dir/flight-recording.sh flamegraph $@
    ;;
*)
    logInfo "Usage remote-start/remote-download/remote-status/remote-clean/flamegraph"
    exit 1
    ;;
esac
