#!/bin/bash
# ----------------------------------------------------------------------
# snapshot.sh
# ----------------------------------------------------------------------
# Creates a rotating snapshot of the contents of $INCLUDES whenever 
# called (minus the contents of the .exlude files). Snapshots are 
# written to a specified sparse disk image hosted file system (via 
# loopback) for portability. If the filesystem on the disk image 
# supports it, space is preserved via hardlinks.
# ----------------------------------------------------------------------
# Copyright (C) 2010  Jonathan Edwards
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE
# ----------------------------------------------------------------------


# ----------------------------------------------------------------------
# ------------- COMMANDS --------------------
# Include external commands here for portability
# ----------------------------------------------------------------------
BTRFS=/sbin/btrfs
CHMOD=/bin/chmod

#-----------------------------------------------------------------------
# pruneWeeklySnapshots()
#    Deletes the $SPARSE_IMAGE_MOUNT/weekly.$WEEKLY_SNAP_LIMIT+1.
#    For btrfs, use btrfs subvolume delete $BTRFS_VOL/$BTRFS_SUBVOL 
#-----------------------------------------------------------------------
pruneWeeklySnapshots() {
  # step 1: delete the oldest weekly snapshot, if it exists:
  if [ -d $SPARSE_IMAGE_MOUNT/weekly.$(($WEEKLY_SNAP_LIMIT+1)) ] ; then
    logDebug "pruneWeeklySnapshots(): Removing weekly.$(($WEEKLY_SNAP_LIMIT+1))...";
    logTrace "pruneWeeklySnapshots(): \
      $BTRFS subvolume delete $SPARSE_IMAGE_MOUNT/weekly.$(($WEEKLY_SNAP_LIMIT+1)) >> $LOG_FILE 2>&1;";
    $BTRFS subvolume delete $SPARSE_IMAGE_MOUNT/weekly.$(($WEEKLY_SNAP_LIMIT+1)) >> $LOG_FILE 2>&1;
    if [ $? -ne 0 ] ; then
      logFatal "pruneWeeklySnapshots(): Unable to remove $SPARSE_IMAGE_MOUNT/weekly.$(($WEEKLY_SNAP_LIMIT+1)); exiting.";
    fi;
    logDebug "pruneWeeklySnapshots(): Removal complete.";
  fi ;
}

#-----------------------------------------------------------------------
# pruneDailySnapshots()
#    Deletes the $SPARSE_IMAGE_MOUNT/daily.$DAILY_SNAP_LIMIT+1.
#    For btrfs, use btrfs subvolume delete $BTRFS_VOL/$BTRFS_SUBVOL
#-----------------------------------------------------------------------
pruneDailySnapshots() {
  # step 2: delete the oldest daily snapshot, if it exists:
  if [ -d $SPARSE_IMAGE_MOUNT/daily.$(($DAILY_SNAP_LIMIT+1)) ] ; then
    logDebug "pruneDailySnapshots(): Removing daily.$(($DAILY_SNAP_LIMIT+1))...";
    logTrace "pruneDailySnapshots(): \
      $BTRFS subvolume delete $SPARSE_IMAGE_MOUNT/daily.$(($DAILY_SNAP_LIMIT+1)) >> $LOG_FILE 2>&1;";
    $BTRFS subvolume delete $SPARSE_IMAGE_MOUNT/daily.$(($DAILY_SNAP_LIMIT+1)) >> $LOG_FILE 2>&1;
    if [ $? -ne 0 ] ; then
      logFatal "pruneDailySnapshots(): Unable to remove $SPARSE_IMAGE_MOUNT/daily.$(($DAILY_SNAP_LIMIT+1)); exiting.";
    fi;
    logDebug "pruneDailySnapshots(): Removal complete.";
  fi ;
}

#-----------------------------------------------------------------------
# pruneHourlySnapshots()
#    Deletes the $SPARSE_IMAGE_MOUNT/hourly.$HOURLY_SNAP_LIMIT+1.
#    For btrfs, use btrfs subvolume delete $BTRFS_VOL/$BTRFS_SUBVOL
#-----------------------------------------------------------------------
pruneHourlySnapshots() {
  # step #2.5: 
  if [ -d $SPARSE_IMAGE_MOUNT/.hourly.tmp ]; then
    logDebug "pruneHourlySnapshots(): Removing stale instance .hourly.tmp ...";
    logTrace "pruneHourlySnapshots(): \
      $BTRFS subvolume delete $SPARSE_IMAGE_MOUNT/.hourly.tmp >> $LOG_FILE 2>&1";
    $BTRFS subvolume delete $SPARSE_IMAGE_MOUNT/.hourly.tmp >> $LOG_FILE 2>&1;
    if [ $? -ne 0 ] ; then
      logError "pruneHourlySnapshots(): remove encountered an error; exiting.";
    fi;
  fi;

  # step 3: delete the oldest hourly snapshot, if it exists:
  if [ -d $SPARSE_IMAGE_MOUNT/hourly.$(($HOURLY_SNAP_LIMIT+1)) ] ; then
    logDebug "pruneHourlySnapshots(): Removing hourly.$(($HOURLY_SNAP_LIMIT+1))...";
    logTrace "pruneHourlySnapshots(): \
      $BTRFS subvolume delete $SPARSE_IMAGE_MOUNT/hourly.$(($HOURLY_SNAP_LIMIT+1))";
    $BTRFS subvolume delete $SPARSE_IMAGE_MOUNT/hourly.$(($HOURLY_SNAP_LIMIT+1)) ;
    if [ $? -ne 0 ] ; then
      logFatal "pruneHourlySnapshots(): Unable to remove $SPARSE_IMAGE_MOUNT/hourly.$(($HOURLY_SNAP_LIMIT+1)); exiting.";
    fi;
    logDebug "pruneHourlySnapshots(): Removal of oldest hourly complete complete.";
  fi ;
}

#-----------------------------------------------------------------------
# makeHourlySnapshot()
#   rsync $SOURCE into $SPARSE_IMAGE_MOUNT/hourly.0 updating and 
#   deleting changed files. Notice that rsync behaves like 
#   `cp --remove-destination` by default, so the destinationis unlinked
#   first.  If it were not so, this would copy over the other snapshot(s)
#   too! Also note the `--exclude-from` argument: rsync will ignore
#   files/dirs in $EXCLUDES/$SOURCE.exclude; so each entry within 
#   $INCLUDE should have a corresponsing .exclude (replacing '/' with 
#   '.')file.
#
#   !!! $SOURCE must be setup by calling function. !!!
#-----------------------------------------------------------------------
makeHourlySnapshot() {
  logInfo "makeHourlySnapshot(): Beginning makeHourlySnapshot...";

  RSYNC_OPTS="--archive --sparse --partial --delete --delete-excluded";

  if [ $LOG_LEVEL -ge $LOG_INFO ] ; then
    RSYNC_OPTS="--stats $RSYNC_OPTS";
  fi;

  if [ $LOG_LEVEL -ge $LOG_DEBUG ] ; then
    RSYNC_OPTS="--verbose $RSYNC_OPTS";
  fi;

  if [ $LOG_LEVEL -ge $LOG_TRACE ] ; then
    RSYNC_OPTS="--progress $RSYNC_OPTS";
  fi;

  # step #0.5.a: btrfs subvolume snapshot $SPARSE_IMAGE_MOUNT/hourly.0 to $SPARSE_IMAGE_MOUNT/hourly.tmp
  if [ -d $SPARSE_IMAGE_MOUNT/hourly.0 ]; then
    logDebug "makeHourlySnapshot(): Performing copy of $SPARSE_IMAGE_MOUNT/hourly.0/$SOURCE to  $SPARSE_IMAGE_MOUNT/.hourly.tmp/ ...";
    logTrace "makeHourlySnapshot(): \
      $BTRFS subvolume snapshot $SPARSE_IMAGE_MOUNT/hourly.0 $SPARSE_IMAGE_MOUNT/.hourly.tmp >> $LOG_FILE 2>&1";
    $BTRFS subvolume snapshot $SPARSE_IMAGE_MOUNT/hourly.0 $SPARSE_IMAGE_MOUNT/.hourly.tmp >>  $LOG_FILE 2>&1;
    if [ $? -ne 0 ] ; then
      logError "makeHourlySnapshot(): copy encountered an error; exiting.";
    fi;
    logDebug "makeHourlySnapshot(): copy complete.";
  # step #0.5.b: btrfs subvolume create $SPARSE_IMAGE_MOUNT/hourly.tmp
  else
    logDebug "makeHourlySnapshot(): $SPARSE_IMAGE_MOUNT/.hourly.tmp/$SOURCE does not exist; creating ...";
    logTrace "makeHourlySnapshot(): \ 
      $BTRFS subvolume create $SPARSE_IMAGE_MOUNT/.hourly.tmp >> $LOG_FILE 2>&1;";
    $BTRFS subvolume create $SPARSE_IMAGE_MOUNT/.hourly.tmp >> $LOG_FILE 2>&1;
    if [ $? -ne 0 ] ; then
      logError "makeHourlySnapshot(): Unable to create $SPARSE_IMAGE_MOUNT/.hourly.tmp; exiting.";
    fi;
  fi;

  $CHMOD 755 $SPARSE_IMAGE_MOUNT/.hourly.tmp;

  # Perform all $SOURCE based logic in this block
  exec 3<&0;
  exec 0<"$INCLUDES";
  while read -r SOURCE;
  do
    logInfo "makeHourlySnapshot(): Taking snapshot of /$SOURCE...";

    # step 1: extrapolate the exclude filename from $SOURCE
    EXCLUDE_FILE=`$ECHO "$SOURCE" | $SED "s/\//./g"`
    EXCLUDE_FILE=$EXCLUDE_FILE.exclude
    
    # step 2: define rsync options
    RSYNC_OPTS="$RSYNC_OPTS --exclude-from=$EXCLUDE_DIR/$EXCLUDE_FILE";

    # step #3: perform the rsync
    logDebug "makeHourlySnapshot(): Performing rsync...";
    logTrace "makeHourlySnapshot(): \
      $RSYNC $RSYNC_OPTS /$SOURCE/ $SPARSE_IMAGE_MOUNT/.hourly.tmp/$SOURCE/ >> $LOG_FILE 2>&1";
    $RSYNC $RSYNC_OPTS /$SOURCE/ $SPARSE_IMAGE_MOUNT/.hourly.tmp/$SOURCE/ >>  $LOG_FILE 2>&1;
    if [ $? -ne 0 ] ; then
      logWarn "makeHourlySnapshot(): rsync encountered an error; continuing ...";
    fi;
    logDebug "makeHourlySnapshot(): rsync complete.";

    logInfo "makeHourlySnapshot(): Completed snapshot of /$SOURCE.";
  done;
  exec 0<&3;




  # step 4: update the mtime of hourly.0 to reflect the snapshot time
  logTrace "makeHourlySnapshot(): $TOUCH $SPARSE_IMAGE_MOUNT/.hourly.tmp";
  $TOUCH $SPARSE_IMAGE_MOUNT/.hourly.tmp;
  
  # step 5: update the hourly timestamp with current time
  $TOUCH $HOURLY_LAST;
  $ECHO "`$DATE -u +%s`" > $HOURLY_LAST;

  logInfo "makeHourlySnapshot(): Done.";
}
