#!/bin/bash
#
# b2_backup.sh - backup directories to backblaze b2 cloud storage
# using using b2 sync command. See:
#   * https://www.backblaze.com/b2/docs/quick_command_line.html
#
# b2 binary can be downloaded from:
#   https://github.com/Backblaze/B2_Command_Line_Tool/releases/latest/download/b2-linux
#
# usage: b2_backup.sh /path/to/config/file
#
# config file example - order does not matter:
#   # REQUIRED:
#   B2_APPLICATION_KEY_ID=000xxxxxxxxx1111111222222
#   B2_APPLICATION_KEY=abcdefgabcdeggsjklcz255tyt20acr
#   BUCKET=mybucket
#   LOG_DIR=/var/log/b2backup
#
#   # source hash with dir as key and space delimited
#   # list of directories in directory to exclude
#   SOURCE_DIRS_REXCLUDE["/home"]='tmp'
#   SOURCE_DIRS_REXCLUDE["/var"]='cache lock run tmp'
#   SOURCE_DIRS_REXCLUDE["/etc"]=''
#
#   # OPTIONAL:
#   DRY_RUN=true
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

# set constants
B2_BINARY=/usr/local/bin/b2
B2_VERSION=2.4.0

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

# Check b2 binary is installed
if [[ ! -x ${B2_BINARY} ]]; then
  echo "ERROR: ${B2_BINARY} not installed"
  exit 1
fi

# Check b2 version
b2_version_check=$(${B2_BINARY} version | grep ${B2_VERSION} || echo "FAIL")
if [[ ${b2_version_check} == "FAIL" ]]; then
  echo "ERROR: b2 version ${B2_VERSION} not installed"
  exit 1
fi

# Initialize associative array (aka hash) before reading config
declare -A SOURCE_DIRS_EXCLUDE

# -a: Each variable or function that is created or modified is
# given the export attribute and marked for export to  the
# environment of subsequent commands.
set -a
source "${config_file}"
set +a


# Verify all required vars
REQUIRED_VARS=(
  B2_APPLICATION_KEY_ID
  B2_APPLICATION_KEY
  BUCKET
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

# Check if we can authenticate, and check bucket
bucket_info=$(${B2_BINARY} get-bucket --showSize "${BUCKET}" || echo "fail")
if [[ $bucket_info == "fail" ]]; then
  echo "ERROR: issues authenticating and getting bucket info (${B2_BINARY} get-bucket --showSize ${BUCKET})"
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
  command_line=( "$B2_BINARY" sync )

  # Delete files on destination NOT IN SOURCE
  command_line+=( --delete )

  # Generate exclude flags
  for exclude_value in ${SOURCE_DIRS_EXCLUDE[$source_dir]}; do
    # make sure no trailing slash is at end of directory and close with $
    command_line+=( --excludeDirRegex "^${exclude_value%/}$" )
  done

  if [[ $DRY_RUN == "true" ]]; then
    command_line+=( --dryRun )
  fi

  # Remove trailing slash if exists
  source_dir=$([ "${source_dir}" == "/" ] && echo "/" || echo "${source_dir%/}")
  command_line+=( "$source_dir" )

  # Destination to B2 bucket
  dest_dir=$([ "${source_dir}" == "/" ] && echo "" || echo "${source_dir}/")
  command_line+=( "b2://${BUCKET}/${dest_dir}" )

  echo "------ BACKING UP: ${source_dir}"
  # Ex: b2 --delete --excludeDirRegex ^tmp$ --excludeDirRegex ^archive/tmp$ /home b2://backup_bucket/home/
  echo "COMMAND LINE:"
  echo "${command_line[@]}"
  command_output=$("${command_line[@]}" 2>&1) || error=true

  if [[ $error == "true" ]]; then
    echo "!!!! ERROR ENCOUNTERED !!!!"
  fi
  echo "${command_output[@]}"
done

total_time=$(($(date +%s)-start_time))
echo "Total time: ${total_time} seconds"
