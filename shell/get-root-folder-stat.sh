#!/bin/bash

if [ -z "$1" ]; then
    echo "[ERROR] Usage local/remote"
    exit 1
fi

validate() {
    echo "[INFO] Validating Ansible installation"

    ansible --version &> /dev/null

    if [ $? -ne 0 ]; then
        echo "[ERROR] You should install Ansible first: https://www.ansible.com/"
        exit 1
    fi

    echo "[INFO] Validating Ansible hosts group: $2"

    result=$(ansible $2 -m ping 2>&1)

    exists=$(echo $result | grep SUCCESS)

    if [[ $? -ne 0 || -z "$exists" ]]; then
        echo "[ERROR] Please check that your Ansible hosts group \"$2\" is configured inside '/etc/ansible/hosts'. More about groups: http://docs.ansible.com/ansible/latest/intro_inventory.html#hosts-and-groups"
        exit 1
    fi

    unreachable=$(echo $result | grep UNREACHABLE)

    if [ -n "$unreachable" ]; then
        echo "[ERROR] Some of the hosts from Ansible hosts group \"$2\" are unreachable: "
        echo ""
        echo "$unreachable"
        echo ""
        exit 1
    fi

    result=$(echo $result | tr ' ' '\n' | grep SUCCESS)
    arr=($result)

    HOSTS_COUNT=${#arr[@]}

    echo ""
    echo "[INFO] ---------------------------------------------------------"
    echo "[INFO] Ansible hosts group: $2"
    echo "[INFO] Number of hosts    : $HOSTS_COUNT"
    echo "[INFO] ---------------------------------------------------------"
    echo ""
}

case "$1" in

# Running tool locally
local)
    df -h | grep "/$"

    echo ''

    rootFolders=$(sudo ls -al / | awk "{print \$9}" | grep -v "^data$" | grep -v "^run$" | grep -v "^sys$" | grep -v "^\.$" | grep -v "^\.\.$" | awk "{print \"/\"\$1}" | grep -v "^\/$" | grep -v "/lost+found" | grep -v "/proc" | xargs) ; userFolders=$(sudo ls /home | awk "{print \"/home/\"\$1}" | xargs) ; folders="$rootFolders $userFolders" ; tmp=$(mktemp) ; for folder in $folders; do sudo du -s $folder >> $tmp ; done ; sudo du -s /opt/*/* >> $tmp ; echo "" ; cat $tmp | sort -k 1 -n -r | awk "{if(\$1>102400)print \$1\"    \" \$2}" ; rm -f $tmp

    ;;
# Running tools remotely on the hosts from specified Ansible group
remote)
    if [ -z "$2" ]; then
        echo "[ERROR] Ansible hosts group should be specified"
        exit 1

    fi

    validate $@

    HOSTS_GROUP=$2

    SCRIPT_FILE=$(basename $0)

    echo "[INFO] Coping shell script $SCRIPT_FILE to servers group: $HOSTS_GROUP"

    ansible $HOSTS_GROUP -m copy -a "src=$0 dest=~/$SCRIPT_FILE"

    if [ $? -ne 0 ]; then
        echo "[ERROR] Failed to copy shell script to servers"
        exit 1
    fi

    echo "[INFO] Granting exec permissions to shell script"

    ansible $HOSTS_GROUP -m shell -a "chmod a+x ~/$SCRIPT_FILE"

    if [ $? -ne 0 ]; then
        echo "[ERROR] Failed to set exec permissions to shell script"
        exit 1
    fi

    echo "[INFO] Getting root folder stat"

    ansible $HOSTS_GROUP -m shell -a "/home/$USER/$SCRIPT_FILE local" -b --ask-sudo-pass

    if [ $? -ne 0 ]; then
        echo "[ERROR] Failed to get root folder stat"
        exit 1
    fi

    ;;
*)
    echo "[ERROR] Usage local/remote"
    exit 1
    ;;
esac