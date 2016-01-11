#!/bin/bash -e

s3cmd --version > /dev/null 2>&1 || (echo "s3cmd not installed" && exit 1)

dest=$1
if [[ "$dest" == "" ]]; then
  echo "ERROR: first arg should be S3 location"
  exit 1
fi

# Add trailing slash to dest making sure it's a directory
if ! [[ $dest =~ \/$ ]]; then
  echo "adding trailing slash"
  dest="$dest/"
fi

verify_dest=`s3cmd ls $dest | wc -l`

if [[ $verify_dest -gt 0 ]]; then
  echo "Dest exists"
else
  echo "ERROR: $dest does not exist or cannot access"
  exit 1
fi

s3cmd sync \
--verbose \
--rexclude "^(proc|dev|tmp|media|mnt|sys|run|var\/run|var\/lock|var\/cache\/apt\/archives)/|^swapfile|^var\/lib\/php5\/sess_" \
--cache-file=/var/run/s3cmd_cache \
--delete-removed / $dest
