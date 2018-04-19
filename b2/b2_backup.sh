#!/bin/bash
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

# Error out immediatly upon error
set -e

# Function to prevent simultaneous executions of script
lock() {
  local -r script_name="$(basename "$0")"
  local -r lock_file="/var/lock/${script_name%.*}"

  # File descriptor/handle 200 used
  exec 200>"$lock_file"
  if ! flock -n 200; then
    echo "Unable to obtain lock - exiting"
    exit 1
  fi
}

# Load command line args
args=( "$@" )

# Check config file was passed to command
if [[ ${args[0]} == '' ]]; then
  echo "ERROR: CONFIG FILE ARG REQUIRED"
  exit 1
fi
config_file=${args[0]}

# Check config file exists
if [[ ! -f $config_file ]]; then
  echo "ERROR: Config file does not exist: $config_file"
  exit 1
fi

# Initialize associative array (aka hash) before reading config
declare -A SOURCE_DIRS_EXCLUDE
set -a
source "$1"
set +a

# Verify all required vars
REQUIRED_VARS=(
  B2_ACCOUNT_ID
  B2_ACCOUNT_KEY
  RESTIC_PASSWORD
  B2_BUCKET
  LOG_DIR
)
for check_var in "${REQUIRED_VARS[@]}"; do
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
if [[ -z ${RESTIC_PATH+x} ]]; then
  restic=$(which restic || echo '/bin/false')
else
  restic=$RESTIC_PATH
fi
$restic version > /dev/null 2>&1 || (echo "restic not found" && exit 1)

# Check if we can connect, if we can authenticate, and if bucket has been initialized
initial_connection=$($restic -r b2:"${B2_BUCKET}" list snapshots --quiet || echo "fail")
if [[ $initial_connection == "fail" ]]; then
  echo "ERROR: check to see if bucket has been initialized (restic -r b2:${B2_BUCKET} init)"
  exit 1
fi

# redirect STDOUT and STDERR to logfile
mkdir -p "${LOG_DIR}"
logfile="${LOG_DIR}/b2backup-$(date +%Y%m%d-%H%M%S).log"
exec > "$logfile" 2>&1

# prevent simultanious script runs
lock

start_time=$(date +%s)
echo "Starting time: ${start_time}"

# Verify each dir in directory list
for source_dir in "${!SOURCE_DIRS_EXCLUDE[@]}"; do
  if [ ! -d "${source_dir}" ]; then
    echo "ERROR: SOURCE DIRECTORY, ${source_dir}, IS NOT A DIRECTORY - EXITING"
    exit 1
  fi
done

# Iterate backup of each directory in SOURCE_DIRS_EXCLUDE
for source_dir in "${!SOURCE_DIRS_EXCLUDE[@]}"; do
  error=false
  command_line=(
    $restic
    --repo b2:${B2_BUCKET}
    backup
  )

  # Generate --exclude flags
  for exclude_value in ${SOURCE_DIRS_EXCLUDE[$source_dir]}; do
    command_line+=( --exclude="${exclude_value}" )
  done

  # Add one-file-system option
  command_line+=( --one-file-system )

  # Remove trailing slash if exists
  source_dir=$([ "${source_dir}" == "/" ] && echo "/" || echo "${source_dir%/}")
  command_line+=( $source_dir )

  echo "------ BACKING UP: ${source_dir}"
  # Ex: restic --repo b2:bucketname backup --exclude='/var/cache' --exclude='/var/lock' --one-file-system /var
  command_output=$("${command_line[@]}" 2>&1) || error=true

  if [[ $error == "true" ]]; then
    echo "!!!! ERROR ENCOUNTERED !!!!"
  fi
  echo "$command_output"
done

total_time=$(($(date +%s)-start_time))
echo "Total time: ${total_time} seconds"
