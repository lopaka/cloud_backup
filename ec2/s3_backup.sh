#!/bin/bash -e

# s3_backup.sh - backup directory to S3 using 's3cmd sync'
#
# usage: s3_backup.sh /path/to/config/file
#
# config file example (all variables required - order does not matter):
#   ACCESS_KEY_ID=ABCDEFGHIJKLMNOP1234
#   SECRET_ACCESS_KEY=AbCdEfGhIjKlMnOpQrStUvWxYz78934+24jsldiu
#   BUCKET_OBJECT=s3://bucket/object/
#   SOURCE_DIR=/
#   STORAGE_CLASS=STANDARD_IA
#   REXCLUDE='^(proc|dev|tmp|media|mnt|sys|run|var\/run|var\/lock|var\/cache\/apt\/archives)/|^swapfile|^var\/lib\/php5\/sess_' \
#   LOG_DIR=/var/log

# verify s3cmd is installed
s3cmd --version > /dev/null 2>&1 || (echo "s3cmd not installed" && exit 1)

# Read in required config file
if [[ $# -ne 1 ]]; then
  echo "CONFIG FILE ARG REQUIRED"
  exit 1
fi
if [[ ! -e $1 ]]; then
  echo "'$1' DOES NOT EXIST"
  exit 1
fi
source "$1"

# Verify all required vars
REQUIRED_VARS="ACCESS_KEY_ID \
  SECRET_ACCESS_KEY \
  BUCKET_OBJECT \
  SOURCE_DIR \
  STORAGE_CLASS \
  REXCLUDE \
  LOG_DIR"
for check_var in ${REQUIRED_VARS}; do
  if [[ -z ${!check_var+x} ]]; then
    echo "$check_var does not exist - exiting"
    exit 1
  fi
done

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
if ! [[ $BUCKET_OBJECT =~ /$ ]]; then
  echo "adding trailing slash"
  BUCKET_OBJECT="${BUCKET_OBJECT}/"
fi

# Verify existance and access to BUCKET_OBJECT
bucket_info=$(s3cmd info --access_key="$ACCESS_KEY_ID" --secret_key="$SECRET_ACCESS_KEY" --quiet "$BUCKET_OBJECT" || echo 'fail')
if [[ "${bucket_info}" == 'fail' ]]; then
  echo "ERROR: $BUCKET_OBJECT does not exist or cannot access"
  exit 1
else
  echo "Sending backup to $BUCKET_OBJECT"
fi

# Verify source is a directory that exists
if [ ! -d "${SOURCE_DIR}" ]; then
  echo "ERROR: SOURCE_DIR (${SOURCE_DIR}) IS NOT A DIRECTORY"
  exit 1
fi

# return true in the event s3cmd fails in order to continue to end of script
# remember, STDOUT and STDERR are sent to logfile
s3cmd sync \
--access_key=$ACCESS_KEY_ID \
--secret_key=$SECRET_ACCESS_KEY \
--verbose \
--storage-class=$STORAGE_CLASS \
--rexclude $REXCLUDE \
--cache-file=/var/cache/s3cmd_cache \
--delete-removed $SOURCE_DIR $BUCKET_OBJECT || true

total_time=$(($(date +%s)-start_time))
echo "Total time: ${total_time}"
