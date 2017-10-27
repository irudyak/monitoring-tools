#!/bin/bash

# Error logging
logError() {
    if [ -n "$LOG_FILE" ]; then
        echo "[ERROR] $@" | tee -a $LOG_FILE
    else
        echo "[ERROR] $@"
    fi
}

# Info logging
logInfo() {
    if [ -n "$LOG_FILE" ]; then
        echo "[INFO] $@" | tee -a $LOG_FILE
    else
        echo "[INFO] $@"
    fi
}