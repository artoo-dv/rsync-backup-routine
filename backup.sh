#!/bin/bash

# A script to perform incremental backups using rsync

set -o errexit
set -o nounset
set -o pipefail

# Configuration
readonly SOURCE_SERVER="x.x.x.x"
readonly SOURCE_PARENT_DIR="some_username@${SOURCE_SERVER}:/source/directory/"
readonly DIRECTORIES=("dir1" "dir2")  # Array of directories to back up
readonly BACKUP_DIR="/backup/directory"
readonly LOG_DIR="/var/log"
readonly DATETIME="$(date '+%Y-%m-%d_%H:%M:%S')"
readonly LOG_FILE="${LOG_DIR}/backup.log"
readonly LOCK_FILE="/var/run/backup.lock"
readonly DISK="/dev/sdX"  # this is the disk where backup is done
# END of config #######################

# Ensure the backup directory exists and is a valid mount point
if ! mountpoint -q "${BACKUP_DIR}"; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') - ERROR: ${BACKUP_DIR} is not a valid mount point. Exiting." | tee -a "${LOG_FILE}"
  exit 1
fi

# Create a lock file to prevent overlapping executions using flock
exec 200>"${LOCK_FILE}"
if ! flock -n 200; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') - ERROR: Backup script is already running. Exiting." | tee -a "${LOG_FILE}"
  exit 1
fi

# Logging function
log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "${LOG_FILE}"
}

# Function to log the current spin-up count
log_spinup_count() {
  if command -v smartctl &> /dev/null; then
    SPINUP_COUNT=$(smartctl -A "$DISK" | awk '/Start_Stop_Count/ {print $NF}')
    if [ -n "$SPINUP_COUNT" ]; then
      log "Disk Spin-Up Count: $SPINUP_COUNT"
    else
      log "Unable to retrieve spin-up count. Attribute not found."
    fi
  else
    log "smartctl not installed or unavailable. Unable to retrieve spin-up count."
  fi
}


log "Starting backup process."

# Disable spindown during backup
log "Temporarily disabling hard drive spindown"
hdparm -S 0 "${DISK}" >> "${LOG_FILE}" 2>&1

# Log the spin-up count before starting the backup
log_spinup_count

# Loop through each directory to back up
for DIR in "${DIRECTORIES[@]}"; do
  log "Processing directory: ${DIR}"

  # Define paths for this specific directory
  BACKUP_PATH="${BACKUP_DIR}/${DIR}/${DATETIME}"
  LATEST_LINK="${BACKUP_DIR}/${DIR}/latest"

  # Most recent COMPLETE backup (the one 'latest' points to). A resumed backup
  # must hard-link against this, not against its own half-finished directory.
  PREV_COMPLETE=""
  if [ -L "${LATEST_LINK}" ] && [ -d "$(readlink -f "${LATEST_LINK}")" ]; then
    PREV_COMPLETE="$(readlink -f "${LATEST_LINK}")"
  fi

  # Ensure the backup directory for this specific directory exists
  mkdir -p "$(dirname "${BACKUP_PATH}")"

  # Find the most recent backup directory
  LAST_BACKUP=$(find "${BACKUP_DIR}/${DIR}" -maxdepth 1 -type d -name "20*" | sort -r | head -n 1 || true)

  if [ -n "${LAST_BACKUP}" ]; then
    # Check if the last backup directory is incomplete
    if [ -f "${LAST_BACKUP}/.incomplete" ]; then
      log "Resuming interrupted backup in ${LAST_BACKUP}."
      BACKUP_PATH="${LAST_BACKUP}"
      LINK_DEST_OPTION="${PREV_COMPLETE:+--link-dest=${PREV_COMPLETE}}"
    else
      # Fallback: Assume the last backup is incomplete if no `.incomplete` exists but `latest` is missing
      if [ ! -L "${LATEST_LINK}" ]; then
        log "No '.incomplete' marker found, but 'latest' is missing. Assuming ${LAST_BACKUP} is incomplete."
        BACKUP_PATH="${LAST_BACKUP}"
        LINK_DEST_OPTION="${PREV_COMPLETE:+--link-dest=${PREV_COMPLETE}}"
      else
        log "Last backup directory ${LAST_BACKUP} is complete. Starting a new backup."
        BACKUP_PATH="${BACKUP_DIR}/${DIR}/${DATETIME}"
        LINK_DEST_OPTION="--link-dest=${LAST_BACKUP}"
      fi
    fi
  else
    # No previous backups found
    log "No previous backup found for ${DIR}. Performing a full backup."
    BACKUP_PATH="${BACKUP_DIR}/${DIR}/${DATETIME}"
    LINK_DEST_OPTION=""
  fi

  # Create an incomplete marker before starting the backup
  mkdir -p "${BACKUP_PATH}"  # Ensure the backup directory exists
  touch "${BACKUP_PATH}/.incomplete"

  # Perform the backup (use -av for verbose output in the log)
  if rsync -a --delete \
    ${LINK_DEST_OPTION} \
    --exclude=".cache" \
    --exclude="thumbs/**" \
    "${SOURCE_PARENT_DIR}/${DIR}/" \
    "${BACKUP_PATH}" >> "${LOG_FILE}" 2>&1; then
    log "Backup for ${DIR} completed successfully."
    # Remove the incomplete marker after a successful backup
    rm -f "${BACKUP_PATH}/.incomplete"
  else
    log "Backup for ${DIR} failed. Check the log for details."
    continue
  fi

  # Update the latest symlink for this directory
  rm -rf "${LATEST_LINK}"
  ln -s "${BACKUP_PATH}" "${LATEST_LINK}"
  log "Updated latest symlink for ${DIR} to ${BACKUP_PATH}."
done

log "Backup process finished."

log "Spinning down backup disk"
hdparm -y "${DISK}" 

# The lock is released automatically when fd 200 closes on exit
