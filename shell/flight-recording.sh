#!/bin/bash

. $( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )/common.sh

#############################################################################################################
# Helper functions #
####################

# Initializes recording filter
initRecordingFilter() {
    if [ -z "$RECORDING_FILTER" ]; then
        return
    fi

    if [ "$IS_RECORDING_FILTER_FILE" != "true" ]; then
        RECORDING_FILTER="$RECORDING_FILTER"
    else
        if [ -f "$RECORDING_FILTER" ]; then
            filter=$(cat $RECORDING_FILTER)

            if [ $? -ne 0 ]; then
                logError "Failed to read recording filter from file: $RECORDING_FILTER"
                exit 1
            fi

            RECORDING_FILTER=$filter
        else
            logError "Specified recording filter file doesn't exist: $RECORDING_FILTER"
            exit 1
        fi
    fi

    val=$(echo $RECORDING_FILTER | grep 'grep')

    if [ -z "$val" ]; then
        RECORDING_FILTER="grep '$RECORDING_FILTER'"
    fi

    logInfo "Using recording filter: $RECORDING_FILTER"
}

# Creates recording directory
createRecordingDir() {
    logInfo "Using recording directory: $RECORDING_DIR"

    val=$(echo $RECORDING_DIR | tr '/' ' ')
    arr=($val)

    dir=""

    for folder in "${arr[@]}"
    do
        dir="$dir/$folder"

        if [ -d "$dir" ]; then
            continue
        fi

        mkdir $dir

        if [ $? -ne 0 ]; then
            logError "Failed to create directory '$dir' which is a part of recording directory: $RECORDING_DIR"
            exit 1
        fi

        chmod a+rwx $dir

        if [ $? -ne 0 ]; then
            logError "Failed to 'chmod a+rwx' for directory '$dir' which is a part of recording directory: $RECORDING_DIR"
            exit 1
        fi
    done

    LOG_FILE="$RECORDING_DIR/recording.log"
}

# Validates provided arguments
validate() {
    if [ -z "$RECORDING_ROOT_DIR" ]; then
        logError "Root recording directory should be specified"
        exit 1
    fi

    if [ -z "$RECORDING_TS" ]; then
        logError "Recording timestamp should be specified"
        exit 1
    fi

    val=$(echo $RECORDING_TS | tr '/' ' ')
    arr=($val)

    len=${#arr[@]}

    if [ $len -ne 6 ]; then
        logError "Incorrect recording timestamp specified: $RECORDING_TS. Timestamp should have format: YYYY/mm/dd/HH/MM/SS."
        exit 1
    fi

    RECORDING_DIR_POSTFIX="${arr[0]}/${arr[1]}/${arr[2]}/${arr[3]}-${arr[4]}-${arr[5]}"
    RECORDING_DIR="$RECORDING_ROOT_DIR/$RECORDING_DIR_POSTFIX"

    createRecordingDir

    if [ -z "$RECORDING_DURATION" ]; then
        logInfo "Using default recording duration: 60s"
        RECORDING_DURATION="60s"
    else
        logInfo "Recording duration: $RECORDING_DURATION"
    fi
}

# Obtains list of processes for which to turn on flight recording
getProcessesToRecord() {
    cmd="ps -ef | grep java | grep -v '/bin/bash' | grep '\-XX:+FlightRecorder'"

    if [ -n "$RECORDING_FILTER" ]; then
        cmd="$cmd | $RECORDING_FILTER"
    fi

    logInfo "Getting list of processes to record:"
    logInfo ""
    logInfo "$cmd"
    logInfo ""

    eval "$cmd" > $RECORDING_DIR/processes.log

    if [ $? -ne 0 ]; then
        logError "Failed to get list of processes to log"
        exit 1
    fi

    unset PROCESSES

    val=$(cat $RECORDING_DIR/processes.log | awk '{print $2}' | xargs)

    if [ -z "$val" ]; then
        logInfo "There are no processes for flight recording"
    else
        PROCESSES=($val)
        count=${#PROCESSES[@]}

        if [ "$count" != "0" ]; then
            logInfo "Found $count processes for flight recording"
        else
            logInfo "There are no processes for flight recording"
        fi
    fi
}

# Runs recording for the found processes
runRecording() {
    count=${#PROCESSES[@]}

    if [ "$count" == "0" ]; then
        return
    fi

    tmpFile=$(mktemp)

    if [ $? -ne 0 ]; then
        logError "Failed to create temp file"
        exit 1
    fi

    failedCount=0
    failedPids=""

    succeedCount=0
    succeedPids=""

    for ((i=0; i<$count; i++)); do
        PID=${PROCESSES[$i]}
        RECORDING_FILE="${RECORDING_DIR}/${PID}.jfr"

        logInfo "Starting recording for process $PID into file: $RECORDING_FILE"

        uid=$(awk '/^Uid:/{print $2}' /proc/$PID/status)

        if [[ $? -ne 0 || -z "$uid" ]]; then
            logError "Failed to get user id for the process: $PID"
            failedCount=$((failedCount + 1))
            failedPids="$failedPids $PID"
            continue
        fi

        logInfo "Process UID: $uid"

        user_name=$(getent passwd "$uid" | awk -F: '{print $1}')

        if [[ $? -ne 0 || -z "$user_name" ]]; then
            logError "Failed to get user name for the process: $PID"
            failedCount=$((failedCount + 1))
            failedPids="$failedPids $PID"
            continue
        fi

        logInfo "Process user: $user_name"

        #cmd="jcmd $PID JFR.start duration=$RECORDING_DURATION filename=$RECORDING_FILE dumponexit=true > $tmpFile"
        #logInfo "RECORDING CMD: $cmd"

        sudo -u $user_name jcmd $PID JFR.start duration=$RECORDING_DURATION filename=$RECORDING_FILE dumponexit=true &> $tmpFile

        if [ $? -ne 0 ]; then
            val=$(cat $tmpFile)
            logError "Failed to start recording for process $PID:"
            logError "$val"
            failedCount=$((failedCount + 1))
            failedPids="$failedPids $PID"
        else
            logInfo "Successfully started recording for process $PID:"
            succeedCount=$((succeedCount + 1))
            succeedPids="$succeedPids $PID"
        fi
    done

    rm -f $tmpFile

    if [ -n "$succeedPids" ]; then
        logInfo "Started recording for $succeedCount processes: $succeedPids"
    fi

    if [ -n "$failedPids" ]; then
        logInfo "Failed to start recording for $failedCount processes: $failedPids"
    fi

    if [[ -z "$succeedPids" && -n "$failedPids" ]]; then
        logError "Failed to start recording for all found processes"
        exit 1
    fi
}

# Return latest remote recording directory
getLatestRecordingDir() {
    RECORDING_ROOT_DIR=$1

    if [ -z "$RECORDING_ROOT_DIR" ]; then
        logError "Recording root directory should be specified"
        exit 1
    fi

    if [ ! -d "$RECORDING_ROOT_DIR" ]; then
        logError "Recording root directory doesn't exist: $RECORDING_ROOT_DIR"
        exit 1
    fi

    errorMsg="Recording root directory structure doesn't correspond to YYYY/mm/dd/HH-MM-SS"

    year=$(ls $RECORDING_ROOT_DIR | sort | tail -1)

    if [ -z "$year" ]; then
        logError $errorMsg
        exit 1
    fi

    month=$(ls $RECORDING_ROOT_DIR/$year | sort | tail -1)

    if [ -z "$month" ]; then
        logError $errorMsg
        exit 1
    fi

    day=$(ls $RECORDING_ROOT_DIR/$year/$month | sort | tail -1)

    if [ -z "$day" ]; then
        logError $errorMsg
        exit 1
    fi

    ts=$(ls $RECORDING_ROOT_DIR/$year/$month/$day | sort | tail -1)

    if [ -z "$ts" ]; then
        logError $errorMsg
        exit 1
    fi

    rec_folder=$RECORDING_ROOT_DIR/$year/$month/$day/$ts

    echo $rec_folder
}

# Prints information about latest recording directory
printLatestRecordingStatus() {
    # Root directory for recording
    RECORDING_ROOT_DIR=$1

    if [ -z "$RECORDING_ROOT_DIR" ]; then
        logError "Recording root directory should be specified"
        exit 1
    fi

    if [ ! -d "$RECORDING_ROOT_DIR" ]; then
        logError "Recording root directory doesn't exist: $RECORDING_ROOT_DIR"
        exit 1
    fi

    tmpFile=$(mktemp)

    if [ $? -ne 0 ]; then
        logError "Failed to create temporary file"
        exit 1
    fi

    rec_folder=$(getLatestRecordingDir $RECORDING_ROOT_DIR)

    logInfo "Folder: $rec_folder"

    ls -alh $rec_folder > $tmpFile

    if [ $? -ne 0 ]; then
        echo ""
        logError "Failed to get list of files in flight recording folder"
        exit 1
    fi

    errorMsg=

    val=$(cat $tmpFile | grep '\.jfr$' | awk '{print $(NF-4)}')

    if [ -n "$val" ]; then
        val=$(cat $tmpFile | grep '\.jfr$' | awk '{print $(NF-4)}' | grep '^0$')

        if [ -n "$val" ]; then
            status="RUNNING"
        else
            status="COMPLETED"
        fi
    else
        status="INVALID"
        errorMsg="!!! There are no flight recording files !!!"
    fi

    logInfo "Status: $status"

    echo ""

    if [ -n "$errorMsg" ]; then
        logError $errorMsg
        echo ""
    fi

    cat $tmpFile
    rm -f $tmpFile

    if [ -n "$errorMsg" ]; then
        exit 1
    fi
}

# Archiving last flight recording directory
archive() {
    # Root directory for recording
    RECORDING_ROOT_DIR=$1

    # Folder to archive recording to
    ARCHIVE_DIR=$2

    if [ -z "$RECORDING_ROOT_DIR" ]; then
        logError "Recording root directory should be specified"
        exit 1
    fi

    if [ ! -d "$RECORDING_ROOT_DIR" ]; then
        logError "Recording root directory doesn't exist: $RECORDING_ROOT_DIR"
        exit 1
    fi

    if [ -z "$ARCHIVE_DIR" ]; then
        logError "Archive directory should be specified"
        exit 1
    fi

    if [ ! -d "$ARCHIVE_DIR" ]; then
        mkdir -p $ARCHIVE_DIR

        if [ $? -ne 0 ]; then
            logError "Failed to create archive directory: $ARCHIVE_DIR"
            exit 1
        fi
    fi

    rec_folder=$(getLatestRecordingDir $RECORDING_ROOT_DIR)

    val=$(ls $rec_folder | tail -1)

    if [ -z "$val" ]; then
        logError "Nothing to archive inside last flight recording folder: $rec_folder"
        exit 1
    fi

    rm -f $ARCHIVE_DIR/jfr-archived.zip

    if [ $? -ne 0 ]; then
        logError "Failed to remove previously existing recording archive: $ARCHIVE_DIR/jfr-archived.zip"
        exit 1
    fi

    pushd $rec_folder

    zip -r -9 $ARCHIVE_DIR/jfr-archived.zip *

    code=$?

    popd

    if [ $code -ne 0 ]; then
        logError "Failed to archive folder $rec_folder into: $ARCHIVE_DIR/jfr-archived.zip"
    fi

    logInfo "Successfully archived folder $rec_folder into: $ARCHIVE_DIR/jfr-archived.zip"
}

# Checks that flamegraph tools installed
checkFlameGraphTools() {
    if [ -z "$FLAMEGRAPH_CMD" ]; then
        logError "Flamegraph tools should be installed and FLAMEGRAPH_CMD env variable should be defined: https://github.com/chrishantha/jfr-flame-graph"
        exit 1
    fi

    $FLAMEGRAPH_CMD &> /dev/null

    if [[ $? -ne 0 && $? -ne 1 ]]; then
        logError "Flamegraph tools should be installed: https://github.com/chrishantha/jfr-flame-graph"
        exit 1
    fi
}

# Generates flame graphs for all recording files in specified directory
generateFlameGraphs() {
    checkFlameGraphTools

    RECORDING_DIR=$1
    THREADS_COUNT=$2

    if [ -z "$THREADS_COUNT" ]; then
        cpu_cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null || getconf NPROCESSORS_ONLN 2>/dev/null || echo 1)

        if [ $? -ne 0 ]; then
            THREADS_COUNT=8
        else
            THREADS_COUNT=$((cpu_cores * 2))
        fi
    fi

    logInfo "Using $THREADS_COUNT threads to generate flame graphs"

    if [ -z "$RECORDING_DIR" ]; then
        logError "Directory with flight recordings should be specified"
        exit 1
    fi

    if [ ! -d "$RECORDING_DIR" ]; then
        logError "Specified directory with flight recordings doesn't exist: $RECORDING_DIR"
        exit 1
    fi

    val=$(find $RECORDING_DIR -type f -name "*.jfr" | grep -v ".svg" | xargs)

    if [ -z "$val" ]; then
        logInfo "There are no flight recordings in the directory: $RECORDING_DIR"
        exit 0
    fi

    tmpDir=$(mktemp -d)

    if [ $? -ne 0 ]; then
        logError "Failed to create temp directory"
        exit 1
    fi

    recordings=($val)

    count=${#recordings[@]}

    logInfo "There are $count flight recordings in the directory: $RECORDING_DIR"

    for ((i=0; i<$count; i++)); do
        recording=${recordings[$i]}

        logInfo "Generating flame graph for recording: $recording"

        cmd="$FLAMEGRAPH_CMD -f $recording -i > ${recording}.svg"
        cmd="$cmd ; if [ \$? -ne 0 ]; then echo '[ERROR] Failed to generate flame graph for recording: ${recording}'; echo '' > ${tmpDir}/${i}.txt"
        cmd="$cmd ; else echo '[INFO] Successfully generated flame graph for recording: ${recording}' ; fi"

        jobsCount=$(jobs | grep Running | wc -l | xargs)

        while [ $jobsCount -ge $THREADS_COUNT ]; do
            logInfo "Waiting for previously started $jobsCount flame graph generation jobs to complete"
            jobs
            sleep 2s
            jobsCount=$(jobs | grep Running | wc -l | xargs)
        done

        eval "$cmd" &
    done

    jobsCount=$(jobs | grep Running | wc -l | xargs)

    while [ $jobsCount -ne 0 ]; do
        logInfo "Waiting for previously started $jobsCount flame graph generation jobs to complete"
        jobs
        sleep 2s
        jobsCount=$(jobs | grep Running | wc -l | xargs)
    done

    failedCount=$(ls -al $tmpDir | grep "\.txt" | wc -l | xargs)
    succeedCount=$((count - failedCount))

    rm -Rf $tmpDir

    echo ""

    if [ $succeedCount -ne 0 ]; then
        logInfo "Successfully generated flame graphs for $succeedCount recordings"
    fi

    if [ $failedCount -ne 0 ]; then
        logInfo "Failed to generate flame graphs for $failedCount recordings"
        exit 1
    fi
}

# Checking Ansible tools
checkAnsible() {
    HOSTS_GROUP=$1

    logInfo "Validating Ansible installation"

    ansible --version &> /dev/null

    if [ $? -ne 0 ]; then
        logError "You should install Ansible first: https://www.ansible.com/"
        exit 1
    fi

    logInfo "Validating Ansible hosts group: $HOSTS_GROUP"

    result=$(ansible $HOSTS_GROUP -m ping 2>&1)

    exists=$(echo $result | grep SUCCESS)

    if [[ $? -ne 0 || -z "$exists" ]]; then
        logError "Please check that your Ansible hosts group \"$HOSTS_GROUP\" is configured inside '/etc/ansible/hosts'. More about groups: http://docs.ansible.com/ansible/latest/intro_inventory.html#hosts-and-groups"
        exit 1
    fi

    unreachable=$(echo $result | grep UNREACHABLE)

    if [ -n "$unreachable" ]; then
        logError "Some of the hosts from Ansible hosts group \"$HOSTS_GROUP\" are unreachable: "
        echo ""
        echo "$unreachable"
        echo ""
        exit 1
    fi

    result=$(echo $result | tr ' ' '\n' | grep SUCCESS)
    arr=($result)

    HOSTS_COUNT=${#arr[@]}

    echo ""
    logInfo "---------------------------------------------------------"
    logInfo "Ansible hosts group: $HOSTS_GROUP"
    logInfo "Number of hosts    : $HOSTS_COUNT"
    logInfo "---------------------------------------------------------"
    echo ""
}

# Running remote flight recording
runRemoteRecording() {
    HOSTS_GROUP=$1
    RECORDING_ROOT_DIR=$2
    RECORDING_DURATION=$3
    RECORDING_FILTER=$4

    if [ -z "$HOSTS_GROUP" ]; then
        logError "Ansible hosts group should be specified"
        exit 1
    fi

    checkAnsible $HOSTS_GROUP

    if [ -z "$RECORDING_DURATION" ]; then
        logError "Recording duration should be specified"
        exit 1
    fi

    if [ -z "$RECORDING_ROOT_DIR" ]; then
        logError "Recording root directory should be specified"
        exit 1
    fi

    RECORDING_ROOT_DIR="${RECORDING_ROOT_DIR}/${USER}"

    logInfo "Root folder for flight recording: $RECORDING_ROOT_DIR"

    if [ -n "$RECORDING_FILTER" ]; then
        logInfo "Recording filter: $RECORDING_FILTER"
    fi

    logInfo "Recording duration: $RECORDING_DURATION"

    echo
    echo -n [INFO] Press any key if you are going to proceed or Ctrl+C to terminate:
    read anyKey
    echo

    filterFile=

    if [ -n "$RECORDING_FILTER" ]; then
        filterFile=$(mktemp)
        echo $RECORDING_FILTER > $filterFile
    fi

    echo -n [INFO] Please provide sudo password for servers:
    read -s sudoPass
    echo

    recordingTs=$(date '+%Y/%m/%d/%H/%M/%S')
    scriptFile="${BASH_SOURCE[${#BASH_SOURCE[@]} - 1]}"

    logInfo "Coping flight recording script to servers"

    ansible $HOSTS_GROUP -m copy -a "src=$scriptFile dest=~/flight-recording.sh"

    if [ $? -ne 0 ]; then
        logError "Failed to copy flight recording script to servers"
        exit 1
    fi

    if [ -n "$filterFile" ]; then
        logInfo "Coping recording filter file to servers"

        ansible $HOSTS_GROUP -m copy -a "src=$filterFile dest=~/flight-recording-filter.txt"

        if [ $? -ne 0 ]; then
            logError "Failed to copy flight recording filter file to servers"
            exit 1
        fi
    fi

    logInfo "Starting flight recording on servers"

    if [ -n "$filterFile" ]; then
        ansible $HOSTS_GROUP -m shell -a "echo '---------------------------------------------------------------' ; home_dir=\$(echo ~${USER}) ; chmod a+x \$home_dir/flight-recording.sh ; \$home_dir/flight-recording.sh start $RECORDING_ROOT_DIR $recordingTs $RECORDING_DURATION \$home_dir/flight-recording-filter.txt true" -b -e "ansible_sudo_pass=$sudoPass"
        code=$?
        rm -f $filterFile
    else
        ansible $HOSTS_GROUP -m shell -a "echo '---------------------------------------------------------------' ; home_dir=\$(echo ~${USER}) ; chmod a+x \$home_dir/flight-recording.sh ; \$home_dir/flight-recording.sh start $RECORDING_ROOT_DIR $recordingTs $RECORDING_DURATION"  -b -e "ansible_sudo_pass=$sudoPass"
        code=$?
    fi

    if [ $code -ne 0 ]; then
        logError "Failed to start remote flight recording on servers"
        exit 1
    fi

    logInfo "Started remote flight recording on servers"
}

# Prints information about latest recording
printRemoteStatus() {
    HOSTS_GROUP=$1
    RECORDING_ROOT_DIR=$2
    STATUS_ALL=$3

    if [ -z "$HOSTS_GROUP" ]; then
        logError "Ansible hosts group should be specified"
        exit 1
    fi

    checkAnsible $HOSTS_GROUP

    if [ -z "$RECORDING_ROOT_DIR" ]; then
        logError "Recording root directory should be specified"
        exit 1
    fi

    RECORDING_ROOT_DIR="${RECORDING_ROOT_DIR}/${USER}"

    logInfo "Root folder for flight recording: $RECORDING_ROOT_DIR"

    logInfo "Coping flight recording script to servers"

    scriptFile="${BASH_SOURCE[${#BASH_SOURCE[@]} - 1]}"

    ansible $HOSTS_GROUP -m copy -a "src=$scriptFile dest=~/flight-recording.sh"

    if [ $? -ne 0 ]; then
        logError "Failed to copy flight recording script to servers"
        exit 1
    fi

    if [ "$STATUS_ALL" != "all" ]; then
        logInfo "Getting latest recording status from servers"

        ansible $HOSTS_GROUP -m shell -a "echo '---------------------------------------------------------------' ; chmod u+x ~/flight-recording.sh ; ~/flight-recording.sh status $RECORDING_ROOT_DIR"

        if [ $? -ne 0 ]; then
            logError "Failed to get latest recording status from servers"
            exit 1
        fi
    else
        logInfo "Getting summary information about all remote recordings"

        ansible $HOSTS_GROUP -m shell -a "echo '---------------------------------------------------------------' ; chmod u+x ~/flight-recording.sh ; if [ -d $RECORDING_ROOT_DIR ]; then cd $RECORDING_ROOT_DIR ; echo 'All recordings inside folder: $RECORDING_ROOT_DIR' ; echo '' ; find . -type d | grep '-' | sed -r 's/\.\///g' ; else echo '' ; fi"

        if [ $? -ne 0 ]; then
            logError "Failed to get summary information about all remote recordings"
            exit 1
        fi
    fi
}

# Archives and downloads latest remote recordings from servers
downloadRemoteRecordings() {
    HOSTS_GROUP=$1
    RECORDING_ROOT_DIR=$2
    DOWNLOAD_DIR=$3
    DOWNLOAD_ALL=$4

    if [ -z "$HOSTS_GROUP" ]; then
        logError "Ansible hosts group should be specified"
        exit 1
    fi

    checkAnsible $HOSTS_GROUP

    if [ -z "$RECORDING_ROOT_DIR" ]; then
        logError "Recording root directory should be specified"
        exit 1
    fi

    RECORDING_ROOT_DIR="${RECORDING_ROOT_DIR}/${USER}"

    logInfo "Root folder for flight recording: $RECORDING_ROOT_DIR"

    if [ -z "$DOWNLOAD_DIR" ]; then
        if [ "$DOWNLOAD_ALL" != "all" ]; then
            DOWNLOAD_DIR="latest-remote-recording"
        else
            DOWNLOAD_DIR="all-remote-recordings"
        fi
    fi

    logInfo "Download directory: $DOWNLOAD_DIR"

    if [ ! -d "$DOWNLOAD_DIR" ]; then
        mkdir -p $DOWNLOAD_DIR

        if [ $? -ne 0 ]; then
            logError "Failed to create download directory: $DOWNLOAD_DIR"
            exit 1
        fi
    fi

    rm -Rf $DOWNLOAD_DIR/*

    if [ $? -ne 0 ]; then
        logError "Failed to cleanup download directory: $DOWNLOAD_DIR"
        exit 1
    fi

    logInfo "Coping flight recording script to servers"

    scriptFile="${BASH_SOURCE[${#BASH_SOURCE[@]} - 1]}"

    ansible $HOSTS_GROUP -m copy -a "src=$scriptFile dest=~/flight-recording.sh"

    if [ $? -ne 0 ]; then
        logError "Failed to copy flight recording script to servers"
        exit 1
    fi

    if [ "$DOWNLOAD_ALL" != "all" ]; then
        logInfo "Archiving latest flight recording files on servers"

        ansible $HOSTS_GROUP -m shell -a "chmod u+x ~/flight-recording.sh ; ~/flight-recording.sh archive $RECORDING_ROOT_DIR ~"

        if [ $? -ne 0 ]; then
            logError "Failed to archive latest flight recording files on servers"
            exit 1
        fi
    else
        logInfo "Archiving all flight recording files on servers"

        ansible $HOSTS_GROUP -m shell -a "if [ -d $RECORDING_ROOT_DIR ]; then cd $RECORDING_ROOT_DIR ; rm -f ~/jfr-archived.zip ; zip -r -9 ~/jfr-archived.zip * ; else echo '[INFO] There are no flight recordings to archive'; fi"

        if [ $? -ne 0 ]; then
            logError "Failed to archive all flight recording files on servers"
            exit 1
        fi
    fi

    logInfo "Downloading flight recording archives from servers"

    ansible $HOSTS_GROUP -m fetch -a "src=~/jfr-archived.zip dest='$DOWNLOAD_DIR' fail_on_missing=no"

    if [ $? -ne 0 ]; then
        logError "Failed to download flight recording archives from servers"
        exit 1
    fi

    logInfo "Flattening download directories structure"

    host_dirs=$(ls $DOWNLOAD_DIR)
    host_dirs=($host_dirs)

    for host_dir in "${host_dirs[@]}"
    do
        logInfo "Flattening host download directory: $DOWNLOAD_DIR/$host_dir"

        zipArchive=$(find $DOWNLOAD_DIR/$host_dir -type f -name "*.zip")

        logInfo "Moving zip archive $zipArchive to $DOWNLOAD_DIR/$host_dir"

        mv $zipArchive $DOWNLOAD_DIR/$host_dir

        logInfo "Removing all subfolders inside $DOWNLOAD_DIR/$host_dir"

        subdirs=$(find $DOWNLOAD_DIR/$host_dir -type d | xargs);
        subdirs=($subdirs)

        for subdir in "${subdirs[@]}"
        do
            if [ "$subdir" != "$DOWNLOAD_DIR/$host_dir" ]; then
                logInfo "Removing subdir: $subdir"
                rm -Rf $subdir
            fi
        done
    done

    logInfo "Unzipping flight recording archives"

    val=$(find $DOWNLOAD_DIR -type f -name "*.zip" | xargs)

    if [ -z "$val" ]; then
        logError "There are no flight recording archives were actually downloaded into dir: $DOWNLOAD_DIR"
        exit 1
    fi

    arr=($val)

    len=${#arr[@]}

    logInfo "Unzipping $len flight recording archives"

    for archive in "${arr[@]}"
    do
        logInfo "Unzipping flight recording archive: $archive"

        unzip_dir=$(dirname "$archive")

        unzip $archive -d $unzip_dir

        if [ $? -ne 0 ]; then
            logError "Failed to unzip flight recording archive: $archive"
            exit 1
        fi

        rm -f $archive
    done

    logInfo "Successfully unzipped all flight recording archives"

    echo ""

    logInfo "Flight recording files are available in folder: $DOWNLOAD_DIR"
}

# Cleans all remote recordings
cleanRemoteRecordings() {
    HOSTS_GROUP=$1
    RECORDING_ROOT_DIR=$2

    if [ -z "$HOSTS_GROUP" ]; then
        logError "Ansible hosts group should be specified"
        exit 1
    fi

    checkAnsible $HOSTS_GROUP

    if [ -z "$RECORDING_ROOT_DIR" ]; then
        logError "Recording root directory should be specified"
        exit 1
    fi

    RECORDING_ROOT_DIR="${RECORDING_ROOT_DIR}/${USER}"

    logInfo "Root folder for flight recording: $RECORDING_ROOT_DIR"

    echo
    echo -n [INFO] Press any key if you are going to proceed or Ctrl+C to terminate:
    read anyKey
    echo

    echo -n [INFO] Please provide sudo password for servers:
    read -s sudoPass
    echo

    ansible $HOSTS_GROUP -m shell -a "rm -Rf ~/flight-recording.sh ~/jfr-archived.zip $RECORDING_ROOT_DIR" -b -e "ansible_sudo_pass=$sudoPass"

    if [ $? -ne 0 ]; then
        logInfo "Failed to clean remote recordings"
        exit 1
    fi
}

#############################################################################################################
# Script logic #
################

case "$1" in

start)

    logInfo "Running local flight recording"

    # Root directory for recording
    RECORDING_ROOT_DIR=$2

    # Recording timestamp
    RECORDING_TS=$3

    # Recording duration
    RECORDING_DURATION=$4

    # Recording filter for processes to be recorded
    RECORDING_FILTER=$5

    # Flag indicating that recording filter should be read from file
    IS_RECORDING_FILTER_FILE=$6

    validate
    initRecordingFilter
    getProcessesToRecord
    runRecording

    ;;

archive)

    logInfo "Locally archiving last flight recording"

    # Root directory for recording
    RECORDING_ROOT_DIR=$2

    # Folder to archive recording to
    ARCHIVE_DIR=$3

    archive $RECORDING_ROOT_DIR $ARCHIVE_DIR

    ;;

flamegraph)

    logInfo "Generating Flame Graphs for flight recordings in directory: $2"

    # Local directory with flight recordings
    LOCAL_DIR=$2

    # Number of threads to generate flame graphs in parallel
    THREADS_COUNT=$3

    generateFlameGraphs $LOCAL_DIR $THREADS_COUNT

    ;;

status)

    RECORDING_ROOT_DIR=$2

    printLatestRecordingStatus $RECORDING_ROOT_DIR

    ;;

remote-start)

    logInfo "Running remote flight recordings for user: $USER"

    # Ansible host group
    HOSTS_GROUP=$2

    # Root remote directory for recording
    RECORDING_ROOT_DIR=$3

    # Recording duration
    RECORDING_DURATION=$4

    # Recording filter
    if [ -n "$5" ]; then
        shift 4
        RECORDING_FILTER=$@
    fi

    runRemoteRecording $HOSTS_GROUP $RECORDING_ROOT_DIR $RECORDING_DURATION "$RECORDING_FILTER"

    ;;

remote-download)

    # Ansible host group
    HOSTS_GROUP=$2

    # Root directory for recording
    RECORDING_ROOT_DIR=$3

    # Download dir
    DOWNLOAD_DIR=$4

    # Download all recordings
    DOWNLOAD_ALL=$5

    if [ "$DOWNLOAD_ALL" == "all" ]; then
        logInfo "Downloading all remote recording files for the user: $USER"
    else
        logInfo "Downloading latest remote recording files for user: $USER"
    fi

    downloadRemoteRecordings $HOSTS_GROUP $RECORDING_ROOT_DIR $DOWNLOAD_DIR $DOWNLOAD_ALL

    ;;

remote-status)

    # Ansible host group
    HOSTS_GROUP=$2

    # Root directory for recording
    RECORDING_ROOT_DIR=$3

    # Summary status for all recordings
    STATUS_ALL=$4

    if [ "$STATUS_ALL" == "all" ]; then
        logInfo "Getting summary information about all remote recording for user: $USER"
    else
        logInfo "Getting status for the latest remote recordings for user: $USER"
    fi

    printRemoteStatus $HOSTS_GROUP $RECORDING_ROOT_DIR $STATUS_ALL

    ;;

remote-clean)

    logInfo "Cleaning all remote recordings for user: $USER"

    # Ansible host group
    HOSTS_GROUP=$2

    # Root directory for recording
    RECORDING_ROOT_DIR=$3

    cleanRemoteRecordings $HOSTS_GROUP $RECORDING_ROOT_DIR

    ;;

*)

    logInfo "[INFO] Usage start/archive/flamegraph/status/remote-start/remote-download/remote-status/remote-clean"

    exit 1

    ;;
esac
