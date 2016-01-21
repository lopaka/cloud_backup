#!/usr/bin/perl

# format of config file
# ---
# region: us-west-2
# OwnerID: ownerid
# AWSAccessKeyId: key
# SecretAccessKey: secret
# volumes:
#   vol-11111111: description1
#   vol-22222222: description2
# num_of_snapshots_to_keep: 45
# rotate_dry_run: false
#

$| = 1;

use strict;
use Net::Amazon::EC2;
use YAML::XS qw/LoadFile/;
use POSIX qw/strftime/;

my $action = $ARGV[0];

die "ERROR: first arg must be action word\n" unless ($action);

my $config_file = $ARGV[1];
die "ERROR: Second arg must be config file\n" unless ($config_file);

my $date = strftime "%Y%m%d", localtime;
my $snapshot_id;
my $description;
my $snapshots;
my $snapshot;
my @sorted_snapshots;
my $config = LoadFile($config_file);
my %volumes = %{$config->{volumes}};
my $volume_id;

my $ownerid = $config->{OwnerID};
my $ec2 = Net::Amazon::EC2->new(
  region => $config->{region},
  AWSAccessKeyId => $config->{AWSAccessKeyId},
  SecretAccessKey => $config->{SecretAccessKey}
);

# Create snapshots
if ($action eq "create")
{
  foreach $volume_id (keys(%volumes)) {
    $description = $volumes{$volume_id};
    $snapshot = $ec2->create_snapshot(
      VolumeId => $volume_id,
      Description => "${description}-${date}"
    );
    $ec2->create_tags(
      ResourceId => $snapshot->{snapshot_id},
      Tags => {
        Name => "${description}-${date}"
      }
    );
  }
}

# Rotate snapshots
elsif ($action eq "rotate")
{
  my $keep_counter;
  my $num_of_snapshots_to_keep = $config->{num_of_snapshots_to_keep};
  my $rotate_dry_run = $config->{rotate_dry_run};
  my %snapshot_volume_ids;
  my $snapshot_volume_id;
  my $snapshot_date;
  my $delete_snapshot;

  die "NEED TO PROVIDE NUMBER OF SNAPSHOTS TO KEEP >=2" unless $num_of_snapshots_to_keep >= 2;

  $snapshots = $ec2->describe_snapshots(Owner => $ownerid);
  # Place each snapshot into array which is in hash with volume_id as key - hash of arrays.
  # Each entry is start time<tab>snapshot_id to easily sort via time.
  foreach $snapshot (@$snapshots) {
    push(@{$snapshot_volume_ids{$snapshot->volume_id}}, $snapshot->start_time . "\t" . $snapshot->snapshot_id);
  }

  foreach $snapshot_volume_id (keys(%volumes)) {
    # reset counter per volume to check snapshots for
    $keep_counter = $num_of_snapshots_to_keep;

    print $snapshot_volume_id . " " . $volumes{$snapshot_volume_id} . "\n";

    # Sort snapshots by date taken (start_time) most recent on top
    @sorted_snapshots = sort {$b cmp $a} (@{$snapshot_volume_ids{$snapshot_volume_id}});

    foreach $snapshot (@sorted_snapshots) {
      ($snapshot_date, $snapshot_id) = split(/\t/,$snapshot);

      if ($keep_counter > 0) {
        print "KEEPING $keep_counter/$num_of_snapshots_to_keep $snapshot\n";
        $keep_counter--;
      } else {
        if ($rotate_dry_run) {
          print "DRY RUN delete snapshot of $volumes{$snapshot_volume_id} - $snapshot_date ID=$snapshot_id\n";
        } else {
          print "DELETING snapshot of $volumes{$snapshot_volume_id} - $snapshot_date ID=$snapshot_id - ";
          $delete_snapshot = $ec2->delete_snapshot(SnapshotId => $snapshot_id);
          if ($delete_snapshot)
          {
            print "DONE\n"
          }
          else
          {
            die "FAILED DELETION";
          }
        }
      }
    }
  }
}

# List snapshots
elsif ($action eq "list")
{
  my %snapshot_volume_ids;
  my $snapshot_volume_id;
  my $snapshot_date;

  $snapshots = $ec2->describe_snapshots(Owner => $ownerid);

  # Place each snapshot object into array which is in hash with volume_id as key - hash of arrays.
  foreach $snapshot (@$snapshots) {
    push(@{$snapshot_volume_ids{$snapshot->volume_id}}, $snapshot);
  }

  foreach $snapshot_volume_id (keys(%snapshot_volume_ids)) {

    # Sort snapshots by date taken (start_time) most recent on top
    @sorted_snapshots = sort {$b->start_time cmp $a->start_time} (@{$snapshot_volume_ids{$snapshot_volume_id}});
    print $snapshot_volume_id . " " . $sorted_snapshots[0]->description . "\n";

    foreach $snapshot (@sorted_snapshots) {
      print "  Snapshot info:  ";
      print $snapshot->start_time . " ";
      print $snapshot->description . " ";
      print $snapshot->snapshot_id . "\n";

    }
    print "\n";
  }
}
else
{
  die "unknown action $action";
}
