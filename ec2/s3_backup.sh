#!/bin/bash -e

# s3_backup.sh - will backup / to s3
#
# usage: s3_backup.sh s3://bucket/dir

# redirect STDOUT and STDERR to logfile
logfile=/var/log/s3backup-`date +%Y%m%d-%H%M%S`.log
exec > $logfile 2>&1

# check for lock file and if backup already running
lockfile=/var/run/s3_backup.lock
if [ -e ${lockfile} ]; then
  echo "Lock file exists - ${lockfile} - verifying pid"
  old_pid=`cat ${lockfile}`
  pid_check=`ps -h -${old_pid} || echo 'fail'`
  if [[ "${pid_check}" == 'fail' ]]; then
    echo "Lock file does not contain active pid (${old_pid}) - continuing"
  else
    echo "Backup already running - $pid_check - exiting"
    exit 1
  fi
fi
echo "Creating lock file"
echo "$$" > ${lockfile}

# verify s3cmd is installed
s3cmd --version > /dev/null 2>&1 || (echo "s3cmd not installed" && exit 1)

# verify argument is an s3 location
dest=$1
if [[ "$dest" == "" ]]; then
  echo "ERROR: first arg should be S3 location"
  exit 1
fi
if ! [[ $dest =~ ^[sS]3:// ]]; then
  echo "ERROR: invalid destination syntax not matching s3://: $dest"
  exit 1
fi

# Add trailing slash to dest making sure it's a directory
if ! [[ $dest =~ \/$ ]]; then
  echo "adding trailing slash"
  dest="$dest/"
fi

verify_dest=`s3cmd ls $dest | wc -l`

if [[ $verify_dest -gt 0 ]]; then
  echo "Sending backup to $dest"
else
  echo "ERROR: $dest does not exist or cannot access"
  exit 1
fi

s3cmd sync \
--verbose \
--rexclude "^(proc|dev|tmp|media|mnt|sys|run|var\/run|var\/lock|var\/cache\/apt\/archives)/|^swapfile|^var\/lib\/php5\/sess_" \
--cache-file=/var/run/s3cmd_cache \
--delete-removed / $dest
