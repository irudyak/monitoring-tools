#!/bin/bash

. $( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )/common.sh

HOSTS_GROUP=$1

if [ -z "$HOSTS_GROUP" ]; then
    logError "Ansible hosts group should be specified"
    exit 1
fi

ansible $HOSTS_GROUP -m shell -a "echo '---------------------------------------------------------------' ; echo 'Top:' ; top -b -n1 -p 310 | head -5 ; echo '########################' ; echo 'Free:' ; free -m ; echo '########################' ; echo 'Iostat:' ; iostat -mx ; echo '########################' ; echo 'Vmstat:' ; vmstat ; echo '########################' ; echo 'Context switching:' ; sar -w 1 3 ; echo '########################' ; echo 'Network utilization:' ; sar -n DEV 1 3 ; echo '########################'"
