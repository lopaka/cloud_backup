#!/bin/bash -e
#
# b2_backup.sh - backup directories using restic to backblaze b2 cloud storage
#
# usage: b2_backup.sh /path/to/config/file
#
# config file example - order does not matter:
#   # REQUIRED:
#   B2_ACCOUNT_ID=983ea7b52837
#   B2_ACCOUNT_KEY=0005c8c4555555555555555555ffffffffffffdddd
#   RESTIC_PASSWORD=password123
#   B2_BUCKET=mybucket
#   LOG_DIR=/var/log/b2backup
#
#   # source hash with dir as key and space delimited
#   # list of directories to exclude
#   SOURCE_DIRS_REXCLUDE["/home"]='/home/tmp'
#   SOURCE_DIRS_REXCLUDE["/var"]='/var/cache /var/lock /var/run /var/tmp'
#   SOURCE_DIRS_REXCLUDE["/etc"]=''
#
#   # OPTIONAL:
#   RESTIC_PATH=/usr/local/bin/restic
#

# Read in required config file
if [[ $# -ne 1 ]]; then
  echo "CONFIG FILE ARG REQUIRED"
  exit 1
fi
if [[ ! -e $1 ]]; then
  echo "'$1' DOES NOT EXIST"
  exit 1
fi

# Initialize associative array (aka hash) before reading config
declare -A SOURCE_DIRS_EXCLUDE
set -a
source "$1"
set +a

# Verify all required vars
REQUIRED_VARS="B2_ACCOUNT_ID \
  B2_ACCOUNT_KEY \
  RESTIC_PASSWORD \
  B2_BUCKET \
  LOG_DIR"
for check_var in ${REQUIRED_VARS}; do
  if [[ -z ${!check_var+x} ]]; then
    echo "$check_var does not exist - exiting"
    exit 1
  fi
done

# Verify source dirs provided
if [[ ${#SOURCE_DIRS_EXCLUDE[@]} -eq 0 ]]; then
  echo "SOURCE_DIRS_EXCLUDE required to set source directories - exiting"
  exit 1
fi

# verify restic is installed
if [ -z ${RESTIC_PATH+x} ]; then
  restic=$(which restic || echo '/bin/false')
else
  restic=$RESTIC_PATH
fi
$restic version > /dev/null 2>&1 || (echo "restic not found" && exit 1)

# Check if we can connect, if we can authenticate, and if bucket has been initialized
initial_connection=$($restic -r b2:${B2_BUCKET} list snapshots --quiet || echo "fail")
if [[ $initial_connection == "fail" ]]; then
  echo "ERROR: check to see if bucket has been initialized (restic -r b2:${B2_BUCKET} init)"
  exit 1
fi

# redirect STDOUT and STDERR to logfile
mkdir -p "${LOG_DIR}"
logfile="${LOG_DIR}/b2backup-$(date +%Y%m%d-%H%M%S).log"
exec > "$logfile" 2>&1

start_time=$(date +%s)
echo "Starting time: ${start_time}"

# check for lock file and if backup already running
lockfile=/var/run/b2_backup.lock
if [ -e ${lockfile} ]; then
  echo "Lock file exists - ${lockfile} - verifying pid"
  old_pid=$(cat ${lockfile})
  pid_check=$(ps -h -p "${old_pid}" || echo 'fail')
  if [[ "${pid_check}" == 'fail' ]]; then
    echo "Lock file does not contain active pid (${old_pid}) - continuing"
  else
    echo "Backup already running - $pid_check - exiting"
    exit 1
  fi
fi
echo "Creating lock file"
echo "$$" > ${lockfile}

# Verify each dir in directory list
for source_dir in ${!SOURCE_DIRS_EXCLUDE[@]}; do
  if [ ! -d "${source_dir}" ]; then
    echo "ERROR: SOURCE DIRECTORY, ${source_dir}, IS NOT A DIRECTORY - EXITING"
    exit 1
  fi
done

# Iterate backup of each directory in SOURCE_DIRS_EXCLUDE
for source_dir in ${!SOURCE_DIRS_EXCLUDE[@]}; do
  # Remove trailing slash if exists
  source_dir=$([ "${source_dir}" == "/" ] && echo "/" || echo "${source_dir%/}")

  # Generate --exclude flags
  exclude_flags=""
  for exclude_value in ${SOURCE_DIRS_EXCLUDE[$source_dir]}; do
    exclude_flags+=" --exclude='${exclude_value}'"
  done

  echo "------ BACKING UP: ${source_dir}"
  # Return true in the event restic fails in order to continue with other backups
  # Remember, STDOUT and STDERR are sent to logfile
  # Ex: restic --repo b2:bucketname backup --exclude='/var/cache' --exclude='/var/lock' --one-file-system /var
  eval $restic --repo b2:${B2_BUCKET} backup \
    $exclude_flags \
    --one-file-system \
    ${source_dir} || true
done

rm ${lockfile}
total_time=$(($(date +%s)-start_time))
echo "Total time: ${total_time} seconds"
