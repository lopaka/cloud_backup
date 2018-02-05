#!/bin/bash -e

# s3_backup.sh - backup directory to S3 using 's3cmd sync'
#
# usage: s3_backup.sh /path/to/config/file
#
# config file example - order does not matter:
#   # REQUIRED:
#   ACCESS_KEY_ID=ABCDEFGHIJKLMNOP1234
#   SECRET_ACCESS_KEY=AbCdEfGhIjKlMnOpQrStUvWxYz78934+24jsldiu
#   BUCKET_OBJECT=s3://bucket/object/
#   STORAGE_CLASS=STANDARD_IA
#   # source hash with dir as key and rexclude string as value
#   SOURCE_DIRS_REXCLUDE["/home"]='^tmp\/'
#   SOURCE_DIRS_REXCLUDE["/var"]="^(cache|lock|run|tmp)\/"
#   SOURCE_DIRS_REXCLUDE["/etc"]=''
#   LOG_DIR=/var/log
#   # OPTIONAL:
#   S3CMD_PATH=/usr/local/bin/s3cmd
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
declare -A SOURCE_DIRS_REXCLUDE
source "$1"

# Verify all required vars
REQUIRED_VARS="ACCESS_KEY_ID \
  SECRET_ACCESS_KEY \
  BUCKET_OBJECT \
  STORAGE_CLASS \
  LOG_DIR"
for check_var in ${REQUIRED_VARS}; do
  if [[ -z ${!check_var+x} ]]; then
    echo "$check_var does not exist - exiting"
    exit 1
  fi
done

# Verify source dirs provided
if [[ ${#SOURCE_DIRS_REXCLUDE[@]} -eq 0 ]]; then
  echo "SOURCE_DIRS_REXCLUDE not used to set source directories - exiting"
  exit 1
fi

# verify s3cmd is installed
if [ -z ${S3CMD_PATH+x} ]; then
  s3cmd=$(which s3cmd || echo '/bin/false')
else
  s3cmd=$S3CMD_PATH
fi
$s3cmd --version > /dev/null 2>&1 || (echo "s3cmd not installed" && exit 1)

# redirect STDOUT and STDERR to logfile
logfile="${LOG_DIR}/s3backup-$(date +%Y%m%d-%H%M%S).log"
exec > "$logfile" 2>&1

start_time=$(date +%s)
echo "Starting time: ${start_time}"

# check for lock file and if backup already running
lockfile=/var/run/s3_backup.lock
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

# Verify BUCKET_OBJECT is an s3 location
if ! [[ $BUCKET_OBJECT =~ ^[sS]3:// ]]; then
  echo "ERROR: invalid destination syntax not matching s3://: $BUCKET_OBJECT"
  exit 1
fi

# Add trailing slash to dest making sure it's a directory
BUCKET_OBJECT="${BUCKET_OBJECT%/}/"

# Verify existance and access to BUCKET_OBJECT
bucket_info=$($s3cmd info --access_key="$ACCESS_KEY_ID" --secret_key="$SECRET_ACCESS_KEY" --quiet "$BUCKET_OBJECT" || echo 'fail')
if [[ "${bucket_info}" == 'fail' ]]; then
  echo "ERROR: $BUCKET_OBJECT does not exist or cannot access"
  exit 1
else
  echo "Sending backup to $BUCKET_OBJECT"
fi

# Verify each dir in directory list
for source_dir in ${!SOURCE_DIRS_REXCLUDE[@]}; do
  if [ ! -d "${source_dir}" ]; then
    echo "ERROR: SOURCE DIRECTORY, ${source_dir}, IS NOT A DIRECTORY - EXITING"
    exit 1
  fi
done

# Make sure cache dir exists
mkdir -p /var/cache/s3cmd

# Iterate backup of each directory in SOURCE_DIRS_REXCLUDE
for source_dir in ${!SOURCE_DIRS_REXCLUDE[@]}; do
  # Remove trailing slash if exists
  source_dir=$([ "${source_dir}" == "/" ] && echo "/" || echo "${source_dir%/}")

  # Create S3 URI which must end with '/'
  s3_uri=$([ "${source_dir}" == "/" ] && echo "${BUCKET_OBJECT%/}/" || echo "${BUCKET_OBJECT%/}/${source_dir#/}/")

  # Generate --rexclude flag
  rexclude_flag=$([ "${SOURCE_DIRS_REXCLUDE[$source_dir]}" == "" ] && echo "" || echo "--rexclude '${SOURCE_DIRS_REXCLUDE[$source_dir]}'")

  echo "------ BACKING UP: ${source_dir}"
  # Return true in the event s3cmd fails in order to continue with other backups.
  # Remember, STDOUT and STDERR are sent to logfile
  eval $s3cmd sync \
  --access_key=$ACCESS_KEY_ID \
  --secret_key=$SECRET_ACCESS_KEY \
  --verbose \
  --storage-class=$STORAGE_CLASS \
  $rexclude_flag \
  --cache-file=/var/cache/s3cmd/sync_cache${source_dir//\//_} \
  --delete-removed ${source_dir}/ ${s3_uri} || true
done

total_time=$(($(date +%s)-start_time))
echo "Total time: ${total_time} seconds"
