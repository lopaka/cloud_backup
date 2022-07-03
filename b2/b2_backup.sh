#!/bin/bash
#
# b2_backup.sh - backup directories using b2 CLI to backup to backblaze B2 cloud storage
#
# Download b2 cli from:
# https://github.com/Backblaze/B2_Command_Line_Tool/releases/latest/download/b2-linux
#
# usage: b2_backup.sh /path/to/config/file
#
# config file example - order does not matter:
#   # REQUIRED:
#   B2_APPLICATION_KEY_ID=0987654321abc0987654321ab
#   B2_APPLICATION_KEY=A00000000000000000000000000000B
#   B2_BUCKET=mybucket
#   LOG_DIR=/var/log/b2backup
#
#   # source hash with dir to backup as key and space delimited
#   # list of directories via regex to exclude
#   SOURCE_DIRS_EXCLUDE["/home"]='^office_share/\.recycle$ ^machine_backups$ ^machine_backups_BACK$'
#   SOURCE_DIRS_EXCLUDE["/var"]='^cache$ ^lock$ ^run$ ^tmp$ ^spool/postfix$ ^lib/samba/private/msg.sock$ ^lib/lxd$'
#   SOURCE_DIRS_EXCLUDE["/etc"]=''
#   SOURCE_DIRS_EXCLUDE["/root"]=''
#   SOURCE_DIRS_EXCLUDE["/usr/local"]=''
#
#   # OPTIONAL:
#   B2_CLI_PATH=/usr/local/bin/b2
#   # if EMAIL_FROM, *and* EMAIL_TO are not set, inform email will be skipped and just logged
#   EMAIL_FROM='admin@address'
#   EMAIL_TO='recipient@address'
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

# inform alerts or updates
#
# $1: subject
# $2: message
#
inform() {
  subject=$1
  message=$2
  if [[ -n ${EMAIL_FROM} ]] && [[ -n ${EMAIL_TO} ]]; then
    mail_installed=$(mail --version > /dev/null 2>&1 && echo "true" || echo "false")
    if [[ $mail_installed == "true" ]]; then
      # sending email
      echo "${message}" | mail -s "${subject}" -a "From: ${EMAIL_FROM}" "${EMAIL_TO}"
    else
      echo "mail not installed - not sending email"
    fi
  fi
  echo "${subject} : ${message}"
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
# shellcheck source=/dev/null
source "$1"
set +a

# Verify all required vars
REQUIRED_VARS=(
  B2_APPLICATION_KEY_ID
  B2_APPLICATION_KEY
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

# verify b2 cli is installed
if [[ -z ${B2_CLI_PATH+x} ]]; then
  b2_cli=$(command -v b2 || echo '/bin/false')
else
  b2_cli=$B2_CLI_PATH
fi
$b2_cli version > /dev/null 2>&1 || (echo "b2 CLI not found" && exit 1)

# Check if we can connect, if we can authenticate, and if bucket has been initialized
initial_connection=$($b2_cli get-bucket "${B2_BUCKET}" || echo "fail")
if [[ $initial_connection == "fail" ]]; then
  echo "ERROR: check to see if bucket has been initialized"
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
  command_line=( ${b2_cli} sync --noProgress --replaceNewer --excludeAllSymlinks )

  # Generate --exclude flags
  regex_string=""
  for exclude_value in ${SOURCE_DIRS_EXCLUDE[$source_dir]}; do
    regex_string+="${exclude_value}|"
  done
  if [[ $regex_string != "" ]]; then
    command_line+=( --excludeDirRegex ${regex_string%|} )
  fi

  # Remove trailing slash if exists
  source_dir=$([ "${source_dir}" == "/" ] && echo "/" || echo "${source_dir%/}")
  command_line+=( $source_dir b2://${B2_BUCKET}${source_dir} )

  echo "------ BACKING UP: ${source_dir}"
  # Ex: b2 sync --excludeDirRegex '\.recycle' /home/office_share b2://${B2_BUCKET}/home/office_share
  echo "${command_line[@]}"
  ( "${command_line[@]}" 2>&1 ) || error=true

  if [[ $error == "true" ]]; then
    inform "ERROR ENCOUNTERED BACKING UP ${HOSTNAME}:${source_dir}" "SEE ${HOSTNAME}:${logfile}"
  fi
done

total_time=$(($(date +%s)-start_time))
echo "Total time: ${total_time} seconds"
